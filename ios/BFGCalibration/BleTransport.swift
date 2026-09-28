import Foundation
import CoreBluetooth
import BFGCore

/// Thin CoreBluetooth wrapper for the Ninebot Legacy UART service.
///
/// Differences from the Android transport this replaces, all forced by the
/// platform rather than chosen:
///
///   * **No MAC address.** CoreBluetooth never exposes one. Devices are
///     identified by `CBPeripheral.identifier` (stable per app install) and by
///     the 14-character serial broadcast in the advertised name.
///   * **No MTU negotiation.** `requestMtu(512)` has no iOS equivalent; the OS
///     negotiates. Callers must respect `maximumWriteValueLength(for:)`.
///   * **No raw advertisement bytes.** Matching is done on the advertised
///     local name instead of searching the raw scan record for the serial.
///   * **No CCCD descriptor write.** `setNotifyValue` performs it implicitly.
///   * Scanning is unfiltered because the vehicle does not advertise the UART
///     service UUID. The OS throttles scans in the background, so pairing is
///     expected to happen in the foreground.
/// CoreBluetooth conformer to `BFGCore.BleTransport`, so the state machine
/// can be driven by a simulated vehicle in tests.
final class CoreBluetoothTransport: NSObject, BFGCore.BleTransport {
    static let serviceUUID = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    static let txUUID = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    static let rxUUID = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")

    weak var delegate: BleTransportDelegate?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Scan results are keyed by identifier: the client only ever knows the
    /// opaque identity string, never the CBPeripheral itself.
    private var scanned: [String: CBPeripheral] = [:]
    private var txCharacteristic: CBCharacteristic?

    private let queue = DispatchQueue(label: "com.bfgtools.calibration.ble")

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    var isPoweredOn: Bool { central.state == .poweredOn }

    var maximumWriteLength: Int {
        // Without a connected peripheral, fall back to the guaranteed minimum
        // packet size rather than guessing at a negotiated value.
        guard let peripheral else { return 20 }
        return peripheral.maximumWriteValueLength(for: .withResponse)
    }

    func startScan() {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(identifier: String) {
        guard let peripheral = scanned[identifier] else { return }
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        txCharacteristic = nil
    }

    /// Writes in chunks bounded by the negotiated limit. The Ninebot frames in
    /// use are well under the iOS minimum of 20 bytes, but the guard keeps a
    /// future larger frame from being silently truncated by CoreBluetooth.
    func write(_ data: Data) {
        guard let peripheral, let txCharacteristic else { return }
        let limit = maximumWriteLength
        var offset = 0
        while offset < data.count {
            let end = min(offset + limit, data.count)
            let chunk = data.subdata(in: offset..<end)
            peripheral.writeValue(chunk, for: txCharacteristic, type: .withResponse)
            offset = end
        }
    }
}

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        delegate?.bleTransportDidUpdateState(poweredOn: central.state == .poweredOn)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""
        scanned[peripheral.identifier.uuidString] = peripheral
        delegate?.bleTransport(didDiscover: peripheral.identifier.uuidString, name: name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        delegate?.bleTransportDidConnect()
        peripheral.discoverServices([CoreBluetoothTransport.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        delegate?.bleTransport(didDisconnect: error)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        txCharacteristic = nil
        delegate?.bleTransport(didDisconnect: error)
    }
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            delegate?.bleTransport(didDiscoverServices: error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == CoreBluetoothTransport.serviceUUID })
        else {
            delegate?.bleTransport(didDiscoverServices: BleError.serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics([CoreBluetoothTransport.txUUID, CoreBluetoothTransport.rxUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            delegate?.bleTransport(didDiscoverServices: error)
            return
        }
        guard let tx = service.characteristics?.first(where: { $0.uuid == CoreBluetoothTransport.txUUID }),
              let rx = service.characteristics?.first(where: { $0.uuid == CoreBluetoothTransport.rxUUID })
        else {
            delegate?.bleTransport(didDiscoverServices: BleError.characteristicNotFound)
            return
        }
        txCharacteristic = tx
        // Android wrote the CCCD descriptor by hand; iOS does it here.
        peripheral.setNotifyValue(true, for: rx)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        delegate?.bleTransport(didUpdateNotificationState: error)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        delegate?.bleTransport(didReceive: data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        delegate?.bleTransport(didWrite: error)
    }
}

