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

    public static func request(module: Int, index: Int) throws -> [UInt8] {
        let size = try length(module: module, index: index)
        return [0x5A, 0xA5, 0x01, 0x3E, UInt8(module), 0x01, UInt8(index), UInt8(size)]
    }
}
