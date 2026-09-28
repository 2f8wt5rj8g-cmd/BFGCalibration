/// Port of `com.bfgtools.calibration.core.CapacityCompatibilityResolver`.
/// Selects a trustworthy full-capacity value from repeated, read-only BFG probes.
public enum CapacityCompatibilityResolver {
    public static let registers: [Int] = [0x0E, 0x0F, 0x1A, 0x1C, 0x1E]
    public static let repeats = 3

    public struct Result {
        public let stableValues: [Int]
        public let selectedCapacity: Int
        public let selectedRegister: Int
        public let reason: String

        public func value(forRegister register: Int) -> Int {
            for i in 0..<CapacityCompatibilityResolver.registers.count
            where CapacityCompatibilityResolver.registers[i] == register {
                return stableValues[i]
            }
            return -1
        }
    }

    public static func resolve(expectedCapacity: Int, readings: [[Int]]?) -> Result {
        var stable = [Int](repeating: -1, count: registers.count)
        for i in 0..<stable.count {
            if let readings, i < readings.count {
                stable[i] = stableValue(readings[i])
            }
        }

        let cap0e = stable[0]
        let cap0f = stable[1]
        let cap1a = stable[2]
        let cap1c = stable[3]
        let cap1e = stable[4]

        // The abnormal 0Ah vehicle returned the same 26000mAh word from 0x0E/0x0F.
        // Agreement between those two independent reads is the strongest evidence.
        if isPlausible(cap0e) && cap0e == cap0f {
            return selected(stable, cap0e, 0x0E, "0x0E与0x0F稳定一致")
        }

        // A stable candidate matching the current Profile table is safe to prefer.
        if isPlausible(expectedCapacity) {
            if cap0e == expectedCapacity { return selected(stable, cap0e, 0x0E, "0x0E与Profile容量一致") }
            if cap0f == expectedCapacity { return selected(stable, cap0f, 0x0F, "0x0F与Profile容量一致") }
            if cap1c == expectedCapacity { return selected(stable, cap1c, 0x1C, "0x1C与Profile容量一致") }
        }

        // Cross-register agreement is stronger than any single plausible number.
        if isPlausible(cap1c) && (cap1c == cap0e || cap1c == cap0f) {
            return selected(stable, cap1c, 0x1C, "常规容量与兼容候选一致")
        }
        if isPlausible(cap1a) && cap1a == cap1e {
            return selected(stable, cap1a, 0x1A, "0x1A与0x1E稳定一致")
        }

        // 0x0E/0x0F are the confirmed fallback locations. A value must be stable in
        // at least two of three reads before reaching this point.
        if isPlausible(cap0e) { return selected(stable, cap0e, 0x0E, "0x0E连续读取稳定") }
        if isPlausible(cap0f) { return selected(stable, cap0f, 0x0F, "0x0F连续读取稳定") }
        if isPlausible(cap1c) { return selected(stable, cap1c, 0x1C, "0x1C连续读取稳定") }

        return Result(stableValues: stable, selectedCapacity: -1, selectedRegister: -1,
                      reason: "未找到稳定且合理的容量值")
    }

    private static func selected(_ stable: [Int], _ capacity: Int, _ register: Int,
                                 _ reason: String) -> Result {
        Result(stableValues: stable, selectedCapacity: capacity,
               selectedRegister: register, reason: reason)
    }

    /// First value seen at least twice. Reading each candidate against the whole
    /// row (rather than counting adjacent duplicates) is what makes this
    /// order-independent, matching the original.
    private static func stableValue(_ values: [Int]) -> Int {
        guard !values.isEmpty else { return -1 }
        for i in 0..<values.count {
            if values[i] < 0 { continue }
            var matches = 0
            for value in values where value == values[i] { matches += 1 }
            if matches >= 2 { return values[i] }
        }
        return -1
    }

    public static func isPlausible(_ value: Int) -> Bool {
        value >= 5000 && value <= 100000
    }
}
