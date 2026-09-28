/// Port of `com.bfgtools.calibration.core.RegisterReadPlan`.
/// Bounded diagnostic reads for the dashboard and the BFG metering module.
public enum RegisterReadPlan {
    public static let dashboard = 0x01
    public static let meter = 0x10
    public static let first = 0x00
    public static let last = 0xFF

    public enum Failure: Swift.Error, Equatable {
        case unsupportedScanTarget
    }

    public static func supports(_ module: Int) -> Bool {
        module == dashboard || module == meter
    }

    public static func length(module: Int, index: Int) throws -> Int {
        guard supports(module), index >= first, index <= last else {
            throw Failure.unsupportedScanTarget
        }
        return module == meter && (index == 0x00 || index == 0x02) ? 1 : 2
    }

    /// Length to assume when probing a module the original never scanned
    /// (the BLE board and the centre controller share the bus). Most of the
    /// register space answers with a 16-bit word, so that is the assumption;
    /// the two known single-byte meter addresses keep their known length.
    public static func probeLength(module: Int, index: Int) -> Int {
        (try? length(module: module, index: index)) ?? 2
    }

    /// Frame for a dump probe. Unlike `request`, this does not require the
    /// module to be one the original ever scanned — probing the rest of the bus
    /// is the entire point of taking a dump.
    public static func probeRequest(module: Int, index: Int) -> [UInt8] {
        [0x5A, 0xA5, 0x01, 0x3E, UInt8(module & 0xFF), 0x01,
         UInt8(index & 0xFF), UInt8(probeLength(module: module, index: index))]
    }

    public static func request(module: Int, index: Int) throws -> [UInt8] {
        let size = try length(module: module, index: index)
        return [0x5A, 0xA5, 0x01, 0x3E, UInt8(module), 0x01, UInt8(index), UInt8(size)]
    }
}
