/// Port of `com.bfgtools.calibration.core.TimedRiskGate`.
/// Monotonic-time gate shared by every parameter-write risk confirmation.
public enum TimedRiskGate {
    public static let dashboardSeconds = 30
    public static let meterSeconds = 3

    public static func canProceed(elapsedRealtime: Int64, readyAt: Int64, checked: Bool) -> Bool {
        checked && elapsedRealtime >= readyAt
    }
}
