import Foundation

/// Port of the display helpers in `MainActivity`.
///
/// The page renders these strings verbatim, so a raw milliapm-hour count would
/// show up as `26000` where the user expects `26Ah`. Keeping the formatting here
/// puts it under the same tests as the rest of the ported logic.
public enum DisplayFormatter {

    /// Indexed by the profile's low nibble; matches Android's `VOLTAGE_NAMES`.
    private static let voltageNames = ["72V", "60V", "48V"]
    private static let posix = Locale(identifier: "en_US_POSIX")

    public static func voltageName(_ profile: Int) -> String {
        let code = profile & 0x0F
        guard code <= 2 else { return "Unknown" }
        return voltageNames[code]
    }

    public static func capacityShort(_ milliAmpHours: Int) -> String {
        guard milliAmpHours >= 0 else { return "未知" }
        let ampHours = Double(milliAmpHours) / 1000
        return milliAmpHours % 1000 == 0
            ? String(format: "%.0fAh", locale: posix, ampHours)
            : String(format: "%.1fAh", locale: posix, ampHours)
    }

    /// The dashboard's VRLA voltage arrives in hundredths of a volt, and the
    /// original trims trailing zeroes rather than always showing two decimals.
    public static func batteryVoltage(_ raw: Int) -> String {
        guard raw >= 0 else { return "--V" }
        let volts = Double(raw) / 100
        if raw % 100 == 0 { return String(format: "%.0fV", locale: posix, volts) }
        if raw % 10 == 0 { return String(format: "%.1fV", locale: posix, volts) }
        return String(format: "%.2fV", locale: posix, volts)
    }

    public static func nominalVoltage(_ value: Int) -> String {
        value > 0 ? "\(value)V" : "--V"
    }

    public static func soc(_ value: Int) -> String {
        value < 0 ? "--" : String(value)
    }

    /// Firmware is packed as three nibbles. The dashboard compatibility screen
    /// compares these strings against the allowlist, so the shape matters.
    public static func firmwareVersion(_ raw: Int) -> String {
        guard raw >= 0 else { return "未读取到" }
        let major = (raw >> 8) & 0x0F
        let minor = (raw >> 4) & 0x0F
        let patch = raw & 0x0F
        return "\(major).\(minor).\(patch)"
    }
}
