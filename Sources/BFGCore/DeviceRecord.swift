import Foundation

/// Port of `com.bfgtools.calibration.core.DeviceRecord`.
///
/// Java's `DeviceRecord` handed out defensive copies of the password and
/// offered `wipe()`. Swift arrays are value types, so copies are automatic;
/// `wipe()` is kept because the call sites rely on it to zero the buffer.
public final class DeviceRecord {
    public let id: Int64
    public let mac: String
    public let sn: String
    public let name: String
    public let effectiveSn: String
    public let deviceType: String
    public let source: String
    private var password16: [UInt8]

    public init(id: Int64, mac: String?, sn: String?, name: String?,
                deviceType: String?, password16: [UInt8], source: String?) {
        self.id = id
        self.mac = (mac ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        self.sn = (sn ?? "").trimmingCharacters(in: .whitespaces)
        self.name = (name ?? "").trimmingCharacters(in: .whitespaces)
        self.effectiveSn = DeviceRecord.resolveEffectiveSn(sn: self.sn, name: self.name)
        self.deviceType = (deviceType ?? "").trimmingCharacters(in: .whitespaces)
        self.password16 = password16
        self.source = source ?? "unknown"
    }

    /// Java returned a clone here. Value semantics already guarantee the caller
    /// cannot mutate internal state, so the name is kept for parity at call sites.
    public func passwordCopy() -> [UInt8] { password16 }

    public func wipe() {
        for i in 0..<password16.count { password16[i] = 0 }
    }

    public var displayName: String {
        deviceType.isEmpty ? "测试车辆" : "测试车辆 · 车型 " + deviceType
    }

    private static func resolveEffectiveSn(sn: String, name: String) -> String {
        if !sn.isEmpty { return sn }
        let candidate = name
        let pattern = "^[A-Za-z0-9]{14}$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: candidate,
                                           range: NSRange(candidate.startIndex..<candidate.endIndex,
                                                          in: candidate)),
              match.range == NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
        else { return "" }
        return candidate
    }
}
