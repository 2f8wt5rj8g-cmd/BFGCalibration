/// Port of `com.bfgtools.calibration.core.BfgProfileCatalog`.
/// Shared, statically audited BFG Profile table.
public enum BfgProfileCatalog {
    private static let coreByIndex: [Int] = [
        20000, 10500, 18000, 36000,
        10500, 26000, 14000, 38000,
        13000, 22000, 39000, 45000,
        46000, 55000, 52000, 18000
    ]

    public static func expectedCore(_ profile: Int) -> Int {
        let value = profile & 0xFF
        let voltageCode = value & 0x0F
        let index = (value >> 4) & 0x0F
        if voltageCode < 0 || voltageCode > 2 { return -1 }

        // Confirmed voltage-specific exception in the BFG Profile table.
        if index == 5 && voltageCode == 2 { return 24500 }
        return coreByIndex[index]
    }

    public static func nominalVoltage(_ profile: Int) -> Int {
        switch profile & 0x0F {
        case 0: return 72
        case 1: return 60
        case 2: return 48
        default: return -1
        }
    }
}
