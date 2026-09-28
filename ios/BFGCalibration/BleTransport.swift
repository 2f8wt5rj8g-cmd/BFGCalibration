import Foundation
import CoreBluetooth

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
final class BleTransport: NSObject {
    static let serviceUUID = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    static let txUUID = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    static let rxUUID = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")

    weak var delegate: BleTransportDelegate?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
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

    func connect(_ peripheral: CBPeripheral) {
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

protocol BleTransportDelegate: AnyObject {
    func bleTransportDidUpdateState(poweredOn: Bool)
    func bleTransport(didDiscover peripheral: CBPeripheral, name: String)
    func bleTransport(didConnect peripheral: CBPeripheral)
    func bleTransport(didDisconnect error: Error?)
    func bleTransport(didDiscoverServices error: Error?)
    func bleTransport(didUpdateNotificationState error: Error?)
    func bleTransport(didReceive data: Data)
    func bleTransport(didWrite error: Error?)
}

extension BleTransport: CBCentralManagerDelegate {
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
        delegate?.bleTransport(didDiscover: peripheral, name: name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        delegate?.bleTransport(didConnect: peripheral)
        peripheral.discoverServices([BleTransport.serviceUUID])
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

extension BleTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            delegate?.bleTransport(didDiscoverServices: error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BleTransport.serviceUUID })
        else {
            delegate?.bleTransport(didDiscoverServices: BleError.serviceNotFound)
            return
        }
        peripheral.discoverCharacteristics([BleTransport.txUUID, BleTransport.rxUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            delegate?.bleTransport(didDiscoverServices: error)
            return
        }
        guard let tx = service.characteristics?.first(where: { $0.uuid == BleTransport.txUUID }),
              let rx = service.characteristics?.first(where: { $0.uuid == BleTransport.rxUUID })
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

enum BleError: Error, LocalizedError {
    case serviceNotFound
    case characteristicNotFound
    case bluetoothOff
    case txNotReady
    case deviceNotFound
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .serviceNotFound: return "没有找到九号 Legacy UART Service"
        case .characteristicNotFound: return "缺少 0002/0003 特征"
        case .bluetoothOff: return "系统蓝牙未开启"
        case .txNotReady: return "GATT TX未就绪"
        case .deviceNotFound: return "未扫描到该车辆"
        case .timeout(let what): return "\(what)"
        }
    }
}
