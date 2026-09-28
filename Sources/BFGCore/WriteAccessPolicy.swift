/// Port of `com.bfgtools.calibration.core.WriteAccessPolicy`.
public enum WriteAccessPolicy {
    public static func isReadOnlySerial(_ serial: String?) -> Bool {
        guard let serial else { return false }
        return serial.trimmingCharacters(in: .whitespaces).uppercased().hasPrefix("N")
    }

    /// 2.8.6 and 4.2.9 are the explicitly validated meter versions.
    /// Unknown and other versions remain usable, but require extra acknowledgement.
    public static func needsMeterCompatibilityWarning(_ rawVersion: Int) -> Bool {
        rawVersion != 0x0286 && rawVersion != 0x0429
    }
}
