import Foundation
import BFGCore

/// Connects a `VirtualVehicle` to a `BfgBleClient` in place of CoreBluetooth.
///
/// Every interaction the client expects from a real central is reproduced:
/// discovery, connect, service discovery, notification subscription, and a
/// write that produces replies. Latency is simulated so the client's own
/// timeouts and read-back delays are exercised rather than short-circuited.
public final class VirtualLink: BleTransport {

    public weak var delegate: BleTransportDelegate?
    public private(set) var isPoweredOn: Bool

    /// Frames the client wrote, in order.
    public private(set) var writes: [[UInt8]] = []
    public private(set) var connectCalls = 0
    public private(set) var scanStarts = 0

    private let vehicle: VirtualVehicle
    private let queue = DispatchQueue(label: "com.bfgtools.simulator.link")
    private let latency: TimeInterval
    private var connected = false

    /// - Parameter latency: round-trip delay applied to every exchange. Small
    ///   enough to keep tests quick, large enough that a reply never lands
    ///   inside the write call itself.
    public init(vehicle: VirtualVehicle, poweredOn: Bool = true,
                latency: TimeInterval = 0.003) {
        self.vehicle = vehicle
        self.isPoweredOn = poweredOn
        self.latency = latency
    }

    // MARK: - BleTransport

    public func startScan() {
        scanStarts += 1
        guard isPoweredOn else { return }
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self, !self.connected else { return }
            self.delegate?.bleTransport(didDiscover: self.vehicle.advertisedName,
                                        name: self.vehicle.advertisedName)
        }
    }

    public func stopScan() { }

    public func connect(identifier: String) {
        connectCalls += 1
        guard identifier == vehicle.advertisedName else {
            queue.asyncAfter(deadline: .now() + latency) { [weak self] in
                self?.delegate?.bleTransport(didDisconnect: BleError.deviceNotFound)
            }
            return
        }
        // The vehicle mints a fresh challenge for this connection, exactly as
        // the PRE_COMM reply carries a new one each time.
        vehicle.connectionOpened()
        connected = true
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self else { return }
            self.delegate?.bleTransportDidConnect()
            self.delegate?.bleTransport(didDiscoverServices: nil)
            self.delegate?.bleTransport(didUpdateNotificationState: nil)
        }
    }

    public func disconnect() {
        guard connected else { return }
        connected = false
        vehicle.connectionClosed()
    }

    public func write(_ data: Data) {
        let line = [UInt8](data)
        writes.append(line)
        queue.asyncAfter(deadline: .now() + latency) { [weak self] in
            guard let self, self.connected else { return }
            for reply in self.vehicle.receive(line) {
                self.delegate?.bleTransport(didReceive: Data(reply))
            }
            self.delegate?.bleTransport(didWrite: nil)
            if self.vehicle.wantsDisconnect {
                self.connected = false
                self.delegate?.bleTransport(didDisconnect: nil)
            }
        }
    }
}

/// Credential storage that lives in memory, mirroring Android's
/// `PairingCredentialStore`. The device build substitutes the Keychain.
public final class InMemoryCredentialStore: CredentialStore {

    private var passwords: [String: [UInt8]] = [:]

    public init() { }

    public var storedSerials: [String] { Array(passwords.keys).sorted() }

    public func load(serial: String) -> [UInt8]? { passwords[serial] }

    /// Mirrors the original's guard: the serial must look like a Ninebot
    /// serial and the password must be the full 32 bytes, otherwise pairing is
    /// reported as failed rather than half-saved.
    @discardableResult
    public func save(serial: String, password32: [UInt8]) -> Bool {
        guard password32.count == 32,
              serial.range(of: "^[A-Z0-9]{14}$", options: .regularExpression) != nil else {
            return false
        }
        passwords[serial] = password32
        return true
    }
}
