/// Port of `com.bfgtools.calibration.core.DashboardWritePolicy`.
/// Exact firmware allowlist for DIS 0x92 writes. Unknown values fail closed.
public enum DashboardWritePolicy {
    public static let dashboard = 0x0259
    public static let colorDisplay = 0x0155
    public static let centre = 0x05CA
    public static let meter = 0x0429

    public static func allows(dashboard: Int, colorDisplay: Int, centre: Int, meter: Int) -> Bool {
        dashboard == Self.dashboard
            && colorDisplay == Self.colorDisplay
            && centre == Self.centre
            && meter == Self.meter
    }

    public static let blockedMessage = "当前车辆不满足仪表盘写入条件，本次未发送写入指令。"
        + "请在参数写入页查看四项固件的核对结果；计量模块临时写入有独立条件。"
}
