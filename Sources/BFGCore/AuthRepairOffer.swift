import Foundation

/// Port of `com.bfgtools.calibration.core.AuthRepairOffer`.
/// Keeps an authentication timeout separate from ordinary Bluetooth failures.
public enum AuthRepairOffer {
    public static func isAuthTimeout(_ error: String?) -> Bool {
        guard let error else { return false }
        return error.contains("AUTH无回复")
    }

    public static func hasExactVehicleIdentity(mac: String?, serial: String?) -> Bool {
        guard let mac, let serial else { return false }
        return matches(mac, pattern: "^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$")
            && matches(serial, pattern: "^[A-Za-z0-9]{14}$")
    }

    /// NSRegularExpression rather than `String.range(of:options:.regularExpression)`
    /// so that the anchors behave identically to Java's `Matcher.matches`, which
    /// requires the whole input to match.
    private static func matches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range) != nil
    }
}
