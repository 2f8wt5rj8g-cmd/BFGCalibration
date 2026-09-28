/// Port of `com.bfgtools.calibration.core.PostWriteCheckPolicy`.
/// Decides whether a delayed vehicle update needs another read, never another write.
public enum PostWriteCheckPolicy {
    public static let maxReads = 3

    public static func targetMatches(actualProfile: Int, expectedProfile: Int,
                                     actualDisRaw: Int, expectedDisRaw: Int) -> Bool {
        if expectedProfile >= 0 { return actualProfile == expectedProfile }
        if expectedDisRaw >= 0 { return actualDisRaw == expectedDisRaw }
        return false
    }

    public static func capacityPending(soc: Int, remainingCapacityRaw: Int) -> Bool {
        soc > 0 && remainingCapacityRaw == 0
    }

    public static func shouldRetry(readsCompleted: Int, targetMatches: Bool,
                                   capacityPending: Bool) -> Bool {
        readsCompleted < maxReads && (!targetMatches || capacityPending)
    }
}
