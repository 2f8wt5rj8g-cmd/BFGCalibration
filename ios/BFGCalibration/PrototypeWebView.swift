import Foundation
import SwiftUI
// WebKit has not yet been fully annotated for Swift concurrency, so importing
// it without this produces a Sendable-related warning on every build.
@preconcurrency import WebKit
import BFGCore

/// Hosts `bfg-calibration-flow.html` in a WKWebView.
///
/// The page is the presentation layer. Android injected a Java object named
/// `BfgNative` with `addJavascriptInterface`; WKWebView has no equivalent, so a
/// `WKUserScript` installs a shim with the same shape at document start. The
/// page keeps calling `window.BfgNative.action(action, value)` unchanged.
///
/// The page has been adapted for iOS: features that only existed to drive the
/// Android root / virtual-container credential path were removed rather than
/// left as dead buttons.
struct PrototypeWebView: UIViewRepresentable {
    let coordinator: PrototypeCoordinator

    func makeCoordinator() -> PrototypeCoordinator { coordinator }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(PrototypeCoordinator.bridgeShim)
        config.userContentController.add(coordinator, name: "BfgNative")
        // The page is fully self-contained: no network, no external assets,
        // no localStorage. Nothing needs to be enabled beyond JavaScript.
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.isOpaque = false
        webView.scrollView.bounces = false
        coordinator.attach(webView)

        if let url = Bundle.main.url(forResource: "bfg-calibration-flow", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) { }

    /// Declaring the size explicitly stops SwiftUI from sizing the representable
    /// to the web view's intrinsic content size, which can show the page in a
    /// band rather than filling the window.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width,
               height: proposal.height ?? uiView.bounds.height)
    }
}

/// Receives `BfgNative.action(...)` calls, drives the BLE client, and pushes
/// state back with `bfgNativeUpdate` / `bfgNativeGo`.
final class PrototypeCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    /// Installed before any page script runs so the page never sees a missing
    /// `BfgNative`. Argument coercion matches Android's `String(value)`.
    static let bridgeShim = WKUserScript(
        source: """
        window.BfgNative = {
            action: function (action, value) {
                window.webkit.messageHandlers.BfgNative.postMessage({
                    action: String(action),
                    value: value === undefined || value === null ? '' : String(value)
                });
            }
        };
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true)

    /// A write the user has chosen but not yet confirmed through the risk gate.
    private struct PendingWrite {
        let isDashboard: Bool
        let voltage: Int
        let capacityMah: Int
        /// Meter target profile byte, or -1 for a dashboard write.
        let profile: Int
        /// Wording used by the gate and the result screen.
        let restoreLabel: String?
        /// The dashboard config the user based this choice on, so a value that
        /// moved underneath them aborts instead of being overwritten.
        let expectedDisConfigRaw: Int
        /// Set once the user accepted an unvalidated dashboard voltage encoding.
        var allowUnverifiedDis: Bool = false
        /// Gate stage: a dashboard write passes two gates, the meter one.
        var stage: Int = 0
    }

    /// The risk gate is timed by this side. The page renders it and counts down
    /// for the user, but `TimedRiskGate` decides whether the confirmation is
    /// accepted, so the wait cannot be skipped on a stale or replayed tap.
    private struct RiskGate {
        let nonce: Int
        let readyAtMillis: Int64
        let seconds: Int
    }

    private let backupStore = BackupStore()

    private weak var webView: WKWebView?
    private var client: BfgBleClient?
    private var pageReady = false
    /// The operation the live client is running, so its result can be routed.
    private var activeOperation: BfgBleClient.Operation = .readOnly
    /// Retained for the diagnostic export; the page only ever shows the last line.
    private var diagnosticLog: [String] = []

    /// Result of the last completed read, which every write is derived from.
    private var lastRead: BfgBleClient.Result?
    private var pendingWrite: PendingWrite?
    /// A dashboard write parked on the unvalidated-encoding warning.
    private var pendingUnverified: PendingWrite?
    private var gate: RiskGate?
    private var gateNonce = 0
    /// Meter gates accepted in this session, keyed by serial and target profile,
    /// so a repeated write to the same target does not re-ask. Never persisted.
    private var approvedMeterGates = Set<String>()

    /// State mirrored into the page. Keys match the field names the HTML reads.
    private var state: [String: Any] = [
        "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        "connected": false,
        "vehicles": [],
        "readOnlyVehicle": false,
        "firstBackupValid": false,
        "recentBackupValid": false,
        "backupAlternativesDiffer": false,
        "firstBackup": "尚未建立",
        "recentBackup": "尚无写入前快照",
        "lastConfirmedTarget": "尚无已确认的写入",
        "scanReplies": 0,
        "scanTimeouts": 0,
        // Dark is the primary look. Send `false` to use the light theme, or
        // derive it from traitCollection.userInterfaceStyle to follow the
        // system instead.
        "dark": true
    ]

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Native -> JS

    private func pushState() {
        guard pageReady, let webView else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: state),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.bfgNativeUpdate && window.bfgNativeUpdate(\(json));")
    }

    private func goTo(_ screen: String) {
        guard pageReady, let webView else { return }
        webView.evaluateJavaScript("window.bfgNativeGo && window.bfgNativeGo('\(screen)');")
    }

    // MARK: - JS -> Native

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        let value = body["value"] as? String ?? ""
        handle(action: action, value: value)
    }

    private func handle(action: String, value: String) {
        switch action {
        case "pair-scan", "refresh-vehicles":
            startDiscovery()

        case "begin-pair":
            pair()

        case "begin-connect", "refresh-read", "post-write-reread":
            refreshRead()

        case "start-repair":
            pair()

        case "pair-select":
            // The page mirrors the tapped serial into `vehicleSn`, so the index
            // itself carries no information the native side needs.
            break

        case "scan-dis", "scan-bfg":
            scan(module: action == "scan-dis" ? RegisterReadPlan.dashboard
                                              : RegisterReadPlan.meter)

        case "do-write", "retry-write":
            requestWrite(value: value)

        case "confirm-unverified-dis":
            confirmUnverifiedDashboardWrite()

        case "restore-first":
            requestRestore(first: true)

        case "restore-prewrite":
            requestRestore(first: false)

        case "write-gate-confirm":
            confirmGate(value: value)

        case "write-gate-cancel":
            pendingWrite = nil
            gate = nil

        case "cancel":
            client?.cancel()
            client = nil
            pendingWrite = nil
            gate = nil
            state["busyMessage"] = NSNull()
            pushState()

        case "show-license":
            state["modal"] = "license"
            state["licenseText"] = Self.licenseText() ?? "未找到使用声明文件。"
            pushState()

        case "export-diag":
            exportDiagnostics()

        case "clear-data":
            clearLocalData()

        case "screen", "modal-state", "select-vehicle", "open-bluetooth-settings":
            // Purely presentational; the page already handled it locally.
            break

        default:
            // Actions that only existed for the Android root / credential path
            // are no longer reachable from the page, and are ignored if a stale
            // call still arrives.
            break
        }
    }

    // MARK: - Vehicle discovery

    private func startDiscovery() {
        state["vehicles"] = []
        state["pairScanning"] = true
        pushState()
        startClient(record: placeholderRecord(serial: ""), operation: .discoverVehicles)
    }

    // MARK: - BLE operations

    private var serial: String { state["vehicleSn"] as? String ?? "" }

    private func pair() {
        goTo("pair-progress")
        // An empty serial lets the client take the first vehicle that advertises
        // a valid name; a set one pins the scan to the row the user tapped.
        startClient(record: placeholderRecord(serial: serial), operation: .pairAndRead)
    }

    private func scan(module: Int) {
        startClient(record: placeholderRecord(serial: serial),
                    operation: .registerScan, targetProfile: module)
    }

    private func refreshRead() {
        startClient(record: placeholderRecord(serial: serial), operation: .readOnly)
    }

    /// Turns the picker's `(voltage, capacity)` choice into a concrete target and
    /// then re-reads the vehicle, because a write may not proceed without a
    /// fresh pre-write snapshot.
    private func requestWrite(value: String) {
        guard let lastRead else {
            writeFailure("车辆数据尚未读取完成，请重新连接后再试。")
            return
        }
        guard let request = Self.parseWriteRequest(value) else {
            writeFailure("目标参数无效，请重新选择电压和容量。")
            return
        }

        let isDashboard = request.type == "dashboard"
        var profile = -1

        if isDashboard {
            guard lastRead.dashboardNominalVoltage > 0, lastRead.disConfigRaw >= 0 else {
                writeFailure("仪表电压配置没有读取到，请重新连接车辆。")
                return
            }
            do {
                let target = try DisVoltageConfig.target(currentRaw: lastRead.disConfigRaw,
                                                         voltage: request.voltage)
                guard target != lastRead.disConfigRaw else {
                    writeFailure("仪表已经是所选电压档位，本次没有发送写入。")
                    return
                }
                if DisVoltageConfig.requiresExtraWarning(currentRaw: lastRead.disConfigRaw,
                                                         targetRaw: target) {
                    // This encoding family has no in-vehicle validation; the user
                    // must accept that explicitly before any frame is sent.
                    pendingUnverified = PendingWrite(isDashboard: true,
                                                     voltage: request.voltage,
                                                     capacityMah: request.capacityMah,
                                                     profile: -1,
                                                     restoreLabel: nil,
                                                     expectedDisConfigRaw: lastRead.disConfigRaw)
                    state["errorMessage"] = "这组仪表配置尚无实车验证，请确认可以恢复原参数后继续。"
                    state["modal"] = "unverified-dis"
                    pushState()
                    return
                }
            } catch {
                writeFailure(error.localizedDescription)
                return
            }
        } else {
            let voltageCode = BfgProfileCatalog.voltageCode(forVoltage: request.voltage)
            let currentIndex = lastRead.profileRaw < 0 ? -1 : (lastRead.profileRaw >> 4) & 0xF
            profile = BfgProfileCatalog.profileIndex(requestedMilliAh: request.capacityMah,
                                                    voltageCode: voltageCode,
                                                    preferring: currentIndex)
            guard profile >= 0 else {
                writeFailure("所选容量未适配，请重新选择电压和容量。")
                return
            }
            guard lastRead.writeSupported else {
                writeFailure("当前仪表与计量模块组合尚未通过写入验证；"
                    + "本次没有发送写入。请先导出诊断数据用于适配。")
                return
            }
            guard backupStore.firstBackup(serial: serial).valid else {
                writeFailure("所选容量未适配或原参数备份未完成，请重新读取车辆数据。")
                return
            }
        }

        pendingWrite = PendingWrite(isDashboard: isDashboard,
                                    voltage: request.voltage,
                                    capacityMah: request.capacityMah,
                                    profile: profile,
                                    restoreLabel: nil,
                                    expectedDisConfigRaw: lastRead.disConfigRaw)
        beginPreWriteRead()
    }

    /// The page's "still try" answer to the unvalidated-encoding warning.
    private func confirmUnverifiedDashboardWrite() {
        guard var pending = pendingUnverified else { return }
        pendingUnverified = nil
        pending.allowUnverifiedDis = true
        pendingWrite = pending
        beginPreWriteRead()
    }

    /// A write may not proceed without a fresh pre-write snapshot, so the read
    /// happens first and the gate opens only once it has been stored.
    private func beginPreWriteRead() {
        state["modal"] = NSNull()
        state["writeStage"] = "precheck"
        pushState()
        startClient(record: placeholderRecord(serial: serial), operation: .compareRead)
    }

    private func requestRestore(first: Bool) {
        let backup = first ? backupStore.firstBackup(serial: serial)
                           : backupStore.prewriteBackup(serial: serial)
        guard backup.valid else {
            state["errorMessage"] = "当前车辆没有可用备份，或该车仅允许读取。请核对车辆后重试。"
            pushState()
            return
        }
        guard !WriteAccessPolicy.isReadOnlySerial(serial) else {
            state["errorMessage"] = "该序列号以 N 开头，仅允许读取，不发送任何写入指令。"
            pushState()
            return
        }
        pendingWrite = PendingWrite(isDashboard: false,
                                    voltage: BfgProfileCatalog.nominalVoltage(backup.profile),
                                    capacityMah: backup.capacity,
                                    profile: backup.profile,
                                    restoreLabel: first ? "首次原参数" : "最近写入前参数",
                                    expectedDisConfigRaw: lastRead?.disConfigRaw ?? -1)
        beginPreWriteRead()
    }

    private func startClient(record: DeviceRecord, operation: BfgBleClient.Operation,
                             targetProfile: Int = -1,
                             expectedDisConfigRaw: Int = -1,
                             allowUnverifiedDis: Bool = false) {
        client?.cancel()
        activeOperation = operation
        let newClient = BfgBleClient(record: record, operation: operation,
                                     targetProfile: targetProfile,
                                     expectedDisConfigRaw: expectedDisConfigRaw,
                                     allowUnverifiedDis: allowUnverifiedDis,
                                     transport: CoreBluetoothTransport(),
                                     credentialStore: KeychainCredentialStore.shared,
                                     listener: self)
        client = newClient
        newClient.start()
    }

    private func placeholderRecord(serial: String) -> DeviceRecord {
        // On iOS the serial is the identity; there is no MAC and no password to
        // import, so the record carries only what the scan can learn.
        DeviceRecord(id: -1, mac: "", sn: serial, name: serial, deviceType: "",
                     password16: [UInt8](repeating: 0, count: 16), source: "ios_pairing")
    }

    // MARK: - Risk gate

    /// Opens the next confirmation gate for the pending write.
    private func openGate() {
        guard let pending = pendingWrite else { return }
        if !pending.isDashboard,
           approvedMeterGates.contains("\(serial):\(pending.profile)") {
            // This vehicle and target were already accepted in this session; the
            // meter warning is asked once per target, not once per write.
            startWrite(pending)
            return
        }
        let seconds: Int
        if pending.isDashboard {
            seconds = pending.stage == 0 ? TimedRiskGate.dashboardSeconds : 0
        } else {
            seconds = TimedRiskGate.meterSeconds
        }

        gateNonce += 1
        let readyAt = Self.uptimeMillis() + Int64(seconds) * 1000
        gate = RiskGate(nonce: gateNonce, readyAtMillis: readyAt, seconds: seconds)

        let content = Self.gateContent(pending: pending, seconds: seconds, nonce: gateNonce)
        state["writeGate"] = content
        pushState()
    }

    private func confirmGate(value: String) {
        guard let pending = pendingWrite, let gate else { return }
        guard let confirmation = Self.parseGateConfirmation(value),
              confirmation.nonce == gate.nonce else {
            return
        }
        guard TimedRiskGate.canProceed(elapsedRealtime: Self.uptimeMillis(),
                                       readyAt: gate.readyAtMillis,
                                       checked: confirmation.checked) else {
            return
        }

        if pending.isDashboard && pending.stage == 0 {
            // The dashboard write passes two gates in a row, as on Android.
            pendingWrite?.stage = 1
            self.gate = nil
            openGate()
            return
        }

        if !pending.isDashboard {
            approvedMeterGates.insert("\(serial):\(pending.profile)")
        }
        self.gate = nil
        state["writeGate"] = NSNull()
        startWrite(pending)
    }

    private func startWrite(_ pending: PendingWrite) {
        state["writeStage"] = "writing"
        pushState()
        let record = placeholderRecord(serial: serial)
        if pending.isDashboard {
            startClient(record: record, operation: .writeDisVoltage,
                        targetProfile: pending.voltage,
                        expectedDisConfigRaw: pending.expectedDisConfigRaw,
                        allowUnverifiedDis: pending.allowUnverifiedDis)
        } else {
            startClient(record: record, operation: .writeProfile,
                        targetProfile: pending.profile)
        }
    }

    private func writeFailure(_ message: String) {
        state["result"] = "failure"
        state["errorMessage"] = message
        state["screen"] = "review"
        state["modal"] = "write-failure"
        state["busyMessage"] = NSNull()
        pendingWrite = nil
        gate = nil
        pushState()
    }

    // MARK: - Diagnostics

    private func exportDiagnostics() {
        // Android wrote a file and shared it through FileProvider. iOS writes to
        // the app's Documents directory, which the Files app can reach.
        let url = Self.documentsDirectory().appendingPathComponent("bfg-diagnostic.txt")
        let text = diagnosticReport()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            state["errorMessage"] = "\(url.lastPathComponent) · \(text.count) 字节，"
                + "可在「文件」App 的本应用目录中找到。"
        } catch {
            state["errorMessage"] = "诊断导出失败：\(error.localizedDescription)"
        }
        state["modal"] = "diagnostic-exported"
        pushState()
    }

    /// Everything the log had, plus the state a driver-side problem needs:
    /// which vehicle, what was last read, and which build produced it.
    private func diagnosticReport() -> String {
        var lines = [
            "BFG iOS diagnostic",
            "time      \(Self.timestamp())",
            "app       \(state["appVersion"] ?? "?")",
            "vehicle   \(serial.isEmpty ? "(未连接)" : serial)",
            "mode      \(state["writeType"] ?? "-")",
            "supported write=\(state["writeSupported"] ?? "-") "
                + "dashboard=\(state["dashboardWriteSupported"] ?? "-")",
            "read      soc=\(state["soc"] ?? "-") voltage=\(state["batteryVoltage"] ?? "-") "
                + "meter=\(state["meterVoltage"] ?? "-") capacity=\(state["meterCapacity"] ?? "-")",
            "firmware  meter=\(state["meterFirmware"] ?? "-") dashboard=\(state["dashboardFirmware"] ?? "-") "
                + "color=\(state["colorDisplayFirmware"] ?? "-") centre=\(state["centreFirmware"] ?? "-")",
            "scan      replies=\(state["scanReplies"] ?? "-") timeouts=\(state["scanTimeouts"] ?? "-")",
            "",
            "--- log (\(diagnosticLog.count) lines) ---"
        ]
        lines.append(contentsOf: diagnosticLog)
        return lines.joined(separator: "\n") + "\n"
    }

    private func clearLocalData() {
        KeychainCredentialStore.shared.deleteAll()
        backupStore.clear(serial: serial)
        lastRead = nil
        pendingWrite = nil
        pendingUnverified = nil
        state["vehicles"] = []
        state["connected"] = false
        state["errorMessage"] = "已清除本机保存的配对凭据与备份。再次使用需要重新配对。"
        state["modal"] = "data-cleared"
        refreshBackupState(serial: serial)
        pushState()
    }

    private static func licenseText() -> String? {
        guard let url = Bundle.main.url(forResource: "license", withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Mirrors `BfgProfileCatalog` into the picker's shape. The page holds no
    /// table of its own, so the options have to come from the same source the
    /// write itself resolves against — otherwise the user could pick a capacity
    /// the write path would then reject.
    private static func capacityOptions() -> (all: [Double], byVoltage: [String: [Double]]) {
        var byVoltage: [String: [Double]] = [:]
        var all: [Double] = []
        for voltage in [48, 60, 72] {
            let code = BfgProfileCatalog.voltageCode(forVoltage: voltage)
            var options: [Double] = []
            for index in 0...0xF {
                let milliAmpHours = BfgProfileCatalog.expectedCore((index << 4) | code)
                guard milliAmpHours > 0 else { continue }
                let ampHours = Double(milliAmpHours) / 1000
                if !options.contains(ampHours) { options.append(ampHours) }
            }
            options.sort()
            byVoltage[String(voltage)] = options
            for value in options where !all.contains(value) { all.append(value) }
        }
        all.sort()
        return (all, byVoltage)
    }

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    // MARK: - Payload parsing

    private struct WriteRequest {
        let type: String
        let voltage: Int
        let capacityMah: Int
    }

    private static func parseWriteRequest(_ value: String) -> WriteRequest? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let voltage = object["voltage"] as? Int else { return nil }
        // The page sends amp-hours as a decimal; the table is in milliamp-hours.
        let capacityAh = (object["capacity"] as? Double) ?? Double(object["capacity"] as? Int ?? 0)
        return WriteRequest(type: type, voltage: voltage,
                            capacityMah: Int((capacityAh * 1000).rounded()))
    }

    private static func parseGateConfirmation(_ value: String) -> (nonce: Int, checked: Bool)? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = object["nonce"] as? Int else { return nil }
        return (nonce, (object["checked"] as? Bool) ?? false)
    }

    /// Wording ported from the Android dialogs, including the two-stage
    /// dashboard warning.
    private static func gateContent(pending: PendingWrite, seconds: Int,
                                    nonce: Int) -> [String: Any] {
        var content: [String: Any] = ["nonce": nonce, "seconds": seconds]
        if pending.isDashboard {
            if pending.stage == 0 {
                content["title"] = "仪表盘永久写入 · 高风险"
                content["intro"] = "本次将写入仪表盘的持久配置，目标为 \(pending.voltage)V。"
                    + "已读取到指定的四项固件版本，但版本匹配不代表这次写入安全。"
                    + "请停车并核对车辆、电池和备份后再决定。"
                content["critical"] = "已知在老车型上，写入仪表盘配置后曾发生计量模块损坏。"
                    + "不同车辆的寄存器位置和含义可能不同，无法保证写入结果。"
                    + "写入可能使车辆无法启动、仪表显示异常或计量模块损坏。"
                    + "即使备份了原参数，也可能无法恢复。"
                    + "更换原装计量模块后，仪表盘仍可能再次下发配置，使新模块再次受损。"
                content["acknowledgement"] = "我已阅读并理解上述已知损坏案例和不可逆风险"
                content["action"] = "继续查看最后提醒"
            } else {
                content["title"] = "再次劝告：仍可能造成损坏"
                content["intro"] = "若不确定车辆配置，请取消并保持只读。"
                    + "备份和回读都不能保证断电后的安全性或恢复成功。"
                content["critical"] = "请勿把写入当作维修或官方校准。"
                    + "本人确认仍要继续，并愿意承担因本人选择错误参数或操作不当造成的损失；"
                    + "本确认不排除依法享有的权利。"
                content["acknowledgement"] = "我仍决定写入，并理解上述风险"
                content["action"] = "我执意写入"
            }
        } else {
            let verb = pending.restoreLabel == nil ? "写入" : "恢复"
            content["title"] = pending.restoreLabel == nil ? "临时写入计量模块"
                                                           : "确认恢复\(pending.restoreLabel!)"
            content["intro"] = "目标 \(pending.voltage)V · "
                + BackupStore.Backup.formatCapacity(pending.capacityMah)
            content["critical"] = verb == "写入"
                ? "断电后可能恢复原参数。写入可能失败或造成数据显示异常，备份不保证恢复。"
                : "恢复会把车辆参数写回所选备份。写入可能失败或造成数据显示异常，备份不保证恢复。"
            content["acknowledgement"] = "我已核对车辆与目标参数，并了解上述风险"
            content["action"] = "继续写入"
        }
        return content
    }

    /// Monotonic milliseconds, matching Android's `SystemClock.elapsedRealtime`
    /// so a wall-clock adjustment cannot shorten the wait.
    private static func uptimeMillis() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded())
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        // The picker has to be usable before the first read, so the options are
        // seeded from the profile table rather than waiting for a connection.
        let options = Self.capacityOptions()
        state["availableCapacities"] = options.all
        state["capacityByVoltage"] = options.byVoltage
        pushState()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Matches the Android client, which refused every in-page navigation.
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

// MARK: - BLE listener

extension PrototypeCoordinator: BfgBleClient.Listener {
    func bleClient(didUpdateStatus status: String) {
        state["busyMessage"] = status
        pushState()
    }

    func bleClient(didLog line: String) {
        // Surfaced through the page's log area when present.
        state["logLine"] = line
        // Bounded so a long session cannot grow without limit; the tail is the
        // part that matters when something went wrong.
        diagnosticLog.append(line)
        if diagnosticLog.count > 500 {
            diagnosticLog.removeFirst(diagnosticLog.count - 500)
        }
    }

    func bleClient(didFinish result: BfgBleClient.Result) {
        state["pairScanning"] = false

        if activeOperation == .discoverVehicles {
            state["vehicles"] = result.discoveredVehicles.map {
                ["sn": $0.serial, "detail": "点击选择这台车"]
            }
            state["busyMessage"] = NSNull()
            pushState()
            goTo("pair-list")
            return
        }

        lastRead = result
        state["connected"] = true
        state["vehicleSn"] = result.serial
        // The page prints these verbatim, so they are formatted the same way the
        // Android client formatted them rather than passed through as raw values.
        state["soc"] = DisplayFormatter.soc(result.displaySoc)
        state["batteryVoltage"] = DisplayFormatter.batteryVoltage(result.disVrlaVoltage)
        state["meterVoltage"] = DisplayFormatter.voltageName(result.profileRaw)
        state["dashboardVoltage"] = DisplayFormatter.nominalVoltage(result.dashboardNominalVoltage)
        state["meterCapacity"] = DisplayFormatter.capacityShort(result.displayBeforeCapacity)
        state["dashboardCapacity"] = DisplayFormatter.capacityShort(result.disRemainingCapacity)
        state["remainingCapacity"] = DisplayFormatter.capacityShort(result.disRemainingCapacity)
        state["meterFirmware"] = DisplayFormatter.firmwareVersion(result.meterFirmware)
        state["dashboardFirmware"] = DisplayFormatter.firmwareVersion(result.dashboardFirmware)
        state["colorDisplayFirmware"] = DisplayFormatter.firmwareVersion(result.colorDisplayVersion)
        state["centreFirmware"] = DisplayFormatter.firmwareVersion(result.centreControllerVersion)

        // A read-only serial is refused by the client as well; mirroring it here
        // keeps the page from offering a write that would only fail later.
        let readOnly = WriteAccessPolicy.isReadOnlySerial(result.serial)
        state["readOnlyVehicle"] = readOnly
        state["writeSupported"] = result.writeSupported && !readOnly
        state["dashboardWriteSupported"] = !readOnly
            && DashboardWritePolicy.allows(dashboard: result.dashboardFirmware,
                                           colorDisplay: result.colorDisplayVersion,
                                           centre: result.centreControllerVersion,
                                           meter: result.meterFirmware)
            && DisVoltageConfig.nominalVoltage(result.disConfigRaw) > 0

        // The capacity picker has no table of its own on the page; the options
        // come from the same profile table the write resolves against.
        let options = Self.capacityOptions()
        state["availableCapacities"] = options.all
        state["capacityByVoltage"] = options.byVoltage
        if result.profileRaw >= 0 {
            state["voltage"] = BfgProfileCatalog.nominalVoltage(result.profileRaw)
            state["capacity"] = Double(BfgProfileCatalog.expectedCore(result.profileRaw)) / 1000
        }

        state["scanReplies"] = result.registerScanReplies
        state["scanTimeouts"] = result.registerScanTimeouts
        state["busyMessage"] = NSNull()
        refreshBackupState(serial: result.serial)

        if result.profileReadbackVerified || result.disConfigReadbackVerified {
            backupStore.saveLastConfirmed(serial: result.serial, profile: result.afterProfile)
        }

        // A completed write ends the flow; a read that ran only to produce the
        // pre-write snapshot hands over to the risk gate instead.
        if pendingWrite != nil, !result.writeCommandSent {
            guard backupStore.savePrewriteSnapshot(serial: result.serial,
                                                   profile: result.profileRaw,
                                                   capacity: result.displayBeforeCapacity,
                                                   disConfigRaw: result.disConfigRaw) else {
                writeFailure("写入前未能完整读取并保存原参数，本次没有发送写入指令。"
                    + "请保持车辆开机后重试。")
                return
            }
            refreshBackupState(serial: result.serial)
            pushState()
            openGate()
            return
        }

        pendingWrite = nil
        pushState()
        if result.writeCommandSent {
            goTo("post-write-check")
        } else {
            goTo("home")
        }
    }

    func bleClient(didFailWith message: String) {
        state["errorMessage"] = message
        state["busyMessage"] = NSNull()
        pendingWrite = nil
        gate = nil
        pushState()
    }

    private func refreshBackupState(serial: String) {
        let first = backupStore.firstBackup(serial: serial)
        let recent = backupStore.prewriteBackup(serial: serial)
        state["firstBackupValid"] = first.valid
        state["recentBackupValid"] = recent.valid
        state["backupAlternativesDiffer"] = backupStore.alternativesDiffer(serial: serial)
        state["firstBackup"] = first.description
        state["recentBackup"] = recent.description
        state["readOnlyVehicle"] = WriteAccessPolicy.isReadOnlySerial(serial)
        let confirmed = backupStore.lastConfirmedProfile(serial: serial)
        state["lastConfirmedTarget"] = confirmed < 0
            ? "尚无已确认的写入"
            : "\(BfgProfileCatalog.nominalVoltage(confirmed))V · "
                + BackupStore.Backup.formatCapacity(BfgProfileCatalog.expectedCore(confirmed))
    }
}
