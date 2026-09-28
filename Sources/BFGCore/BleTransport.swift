import Foundation

/// The transport surface `BfgBleClient` needs.
///
/// The state machine used to own a CoreBluetooth central directly, which meant
/// the only way to exercise it was on a phone next to a vehicle. Routing it
/// through this protocol lets the same code run against a real central on
/// device and against a simulated vehicle under `swift test`.
public protocol BleTransportDelegate: AnyObject {
    func bleTransportDidUpdateState(poweredOn: Bool)
    /// `identifier` is the platform's handle for the peripheral. iOS uses
    /// `CBPeripheral.identifier`, which is stable per install but is not a MAC
    /// address; the vehicle's identity comes from the advertised `name`.
    func bleTransport(didDiscover identifier: String, name: String)
    func bleTransportDidConnect()
    func bleTransport(didDisconnect error: Error?)
    func bleTransport(didDiscoverServices error: Error?)
    func bleTransport(didUpdateNotificationState error: Error?)
    func bleTransport(didReceive data: Data)
    func bleTransport(didWrite error: Error?)
}

public protocol BleTransport: AnyObject {
    var delegate: BleTransportDelegate? { get set }
    /// A central starts in an unknown state and reports powered-on asynchronously.
    /// Reading this lets the client avoid failing its very first launch.
    var isPoweredOn: Bool { get }
    func startScan()
    func stopScan()
    func connect(identifier: String)
    func disconnect()
    func write(_ data: Data)
}

/// Where the paired credential is kept between runs.
///
/// The device build uses the Keychain. Android kept it in process memory only,
/// so a cold start forced a re-pair; storing it durably is a deliberate
/// improvement, not an oversight.
public protocol CredentialStore: AnyObject {
    func load(serial: String) -> [UInt8]?
    @discardableResult
    func save(serial: String, password32: [UInt8]) -> Bool
}

/// Cryptographically secure randomness for the pairing password.
///
/// Android used `SecureRandom`. `SystemRandomNumberGenerator` is documented as
/// backed by the platform CSPRNG on Apple platforms, and it keeps this file
/// portable to Linux for the simulator tests.
public enum SecureRandom {
    public static func bytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }
}

/// Transport-level failures. Declared here rather than in the platform layer
/// because the state machine raises them and the simulator must be able to
/// produce the same ones.
public enum BleError: Error, LocalizedError, Equatable {
    case serviceNotFound
    case characteristicNotFound
    case bluetoothOff
    case txNotReady
    case deviceNotFound
    case timeout(String)

    public var errorDescription: String? {
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
