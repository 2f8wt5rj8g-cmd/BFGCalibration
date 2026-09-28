import Foundation
import SwiftUI
// WebKit has not yet been fully annotated for Swift concurrency, so importing
// it without this produces a Sendable-related warning on every build.
@preconcurrency import WebKit
import BFGCore

/// Hosts the existing `bfg-calibration-flow.html` in a WKWebView.
///
/// The HTML is reused verbatim. Android injected a Java object named
/// `BfgNative` with `addJavascriptInterface`; WKWebView has no equivalent, so a
/// `WKUserScript` installs a shim with the same shape at document start. The
/// page keeps calling `window.BfgNative.action(action, value)` unchanged.
///
/// The reverse direction already matched: `evaluateJavaScript` and Android's
/// `evaluateJavascript` are the same call.
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

    private weak var webView: WKWebView?
    private var client: BfgBleClient?
    private var pageReady = false

    /// State mirrored into the page. Keys match the field names the HTML reads.
    private var state: [String: Any] = [
        "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        "connected": false,
        "vehicles": [],
        "rootMode": false,
        "rootFallback": false,
        "readOnlyVehicle": false
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
        case "vehicles", "refresh-vehicles":
            // iOS has no database to import from: vehicles become known after a
            // successful pairing, which is stored in the Keychain.
            state["vehicles"] = []
            pushState()

        case "refresh-root", "set-root", "set-fallback", "import-root", "launch-ninebot":
            // These exist only to drive the Android root / virtual-container
            // credential path. iOS has no equivalent and reports that plainly
            // instead of appearing to accept them.
            notifyUnsupported(action)

        case "scan-dis", "scan-bfg":
            scan(operation: .registerScan, value: value)

        case "pair-scan":
            goTo("pair-progress")
            pair(value: value)

        case "begin-connect", "do-write", "restore-first", "restore-prewrite",
             "retry-write", "post-write-reread":
            beginOperation(action: action, value: value)

        case "cancel":
            client?.cancel()
            client = nil
            state["busyMessage"] = NSNull()
            pushState()

        case "show-license":
            state["modal"] = ["kind": "license"]
            pushState()

        case "export-diag":
            exportDiagnostics()

        case "screen", "modal-state", "select-vehicle", "open-bluetooth-settings":
            // Purely presentational; the page already handled it locally.
            break

        default:
            break
        }
    }

    private func notifyUnsupported(_ action: String) {
        state["errorMessage"] = "此功能依赖 Android 的 root 或虚拟运行环境，iOS 版本不提供。"
            + "请在 iOS 版本中使用「配对」流程：配对后凭据保存在系统钥匙串，可免按键重连。"
        pushState()
    }

    // MARK: - BLE operations

    private func pair(value: String) {
        guard let serial = value.split(separator: "|").first.map(String.init), !serial.isEmpty else {
            // With no serial supplied, scan lets the client pick the first
            // vehicle that advertises a valid 14-character name.
            startClient(record: placeholderRecord(serial: ""), operation: .pairAndRead)
            return
        }
        startClient(record: placeholderRecord(serial: serial), operation: .pairAndRead)
    }

    private func scan(operation: BfgBleClient.Operation, value: String) {
        startClient(record: placeholderRecord(serial: state["vehicleSn"] as? String ?? ""),
                    operation: operation)
    }

    private func beginOperation(action: String, value: String) {
        let serial = state["vehicleSn"] as? String ?? ""
        let operation: BfgBleClient.Operation = action == "do-write" ? .writeProfile : .readOnly
        let profile = Self.parseInt(value)
        startClient(record: placeholderRecord(serial: serial), operation: operation,
                    targetProfile: profile)
    }

    private func placeholderRecord(serial: String) -> DeviceRecord {
        // On iOS the serial is the identity; there is no MAC and no password to
        // import, so the record carries only what the scan can learn.
        DeviceRecord(id: -1, mac: "", sn: serial, name: serial, deviceType: "",
                     password16: [UInt8](repeating: 0, count: 16), source: "ios_pairing")
    }

    private func startClient(record: DeviceRecord, operation: BfgBleClient.Operation,
                             targetProfile: Int = -1) {
        client?.cancel()
        let newClient = BfgBleClient(record: record, operation: operation,
                                     targetProfile: targetProfile, listener: self)
        client = newClient
        newClient.start()
    }

    private func exportDiagnostics() {
        // Android wrote a file and shared it through FileProvider. iOS writes to
        // the container; sharing is left to the system share sheet.
        let text = "BFG iOS diagnostic\nversion \(state["appVersion"] ?? "")\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bfg_diagnostic.txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        state["errorMessage"] = "诊断已导出到 \(url.lastPathComponent)"
        pushState()
    }

    private static func parseInt(_ value: String) -> Int {
        if let direct = Int(value) { return direct }
        if let data = value.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object["profile"] as? Int ?? -1
        }
        return -1
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
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
    }

    func bleClient(didFinish result: BfgBleClient.Result) {
        state["connected"] = true
        state["vehicleSn"] = result.serial
        state["soc"] = result.dashboardNominalVoltage > 0 ? result.disBatterySoc : result.bfgSoc
        state["batteryVoltage"] = result.dashboardNominalVoltage
        state["meterVoltage"] = result.meterNominalVoltage
        state["dashboardVoltage"] = result.dashboardNominalVoltage
        state["meterCapacity"] = result.bfgCapacity
        state["dashboardCapacity"] = result.disRemainingCapacity
        state["meterFirmware"] = result.meterFirmware
        state["dashboardFirmware"] = result.dashboardFirmware
        state["colorDisplayFirmware"] = result.colorDisplayVersion
        state["centreFirmware"] = result.centreControllerVersion
        state["writeSupported"] = result.writeSupported
        state["writeType"] = CommunicationModeResolver.label(result.mode)
        state["busyMessage"] = NSNull()
        pushState()
        goTo("home")
    }

    func bleClient(didFailWith message: String) {
        state["errorMessage"] = message
        state["busyMessage"] = NSNull()
        pushState()
    }
}
