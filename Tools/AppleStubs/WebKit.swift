// Type-checking stub for WebKit. See Tools/typecheck-ios.sh.
import Foundation
import UIKit

open class WKNavigation: NSObject {}

public enum WKUserScriptInjectionTime: Int, Sendable {
    case atDocumentStart, atDocumentEnd
}

open class WKUserScript: NSObject {
    public init(source: String, injectionTime: WKUserScriptInjectionTime,
                forMainFrameOnly: Bool) {}
}

open class WKUserContentController: NSObject {
    open func addUserScript(_ userScript: WKUserScript) {}
    open func add(_ scriptMessageHandler: WKScriptMessageHandler, name: String) {}
    open func removeScriptMessageHandler(forName name: String) {}
}

open class WKScriptMessage: NSObject {
    open var body: Any = ""
    open var name: String = ""
}

public protocol WKScriptMessageHandler: AnyObject {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage)
}

open class WKWebpagePreferences: NSObject {
    open var allowsContentJavaScript: Bool = true
}

open class WKWebViewConfiguration: NSObject {
    open var userContentController = WKUserContentController()
    open var defaultWebpagePreferences = WKWebpagePreferences()
}

open class WKWebView: UIView {
    open var navigationDelegate: WKNavigationDelegate?
    open var scrollView = UIScrollView()

    public init(frame: CGRect, configuration: WKWebViewConfiguration) { super.init() }

    @discardableResult
    open func loadFileURL(_ URL: URL,
                          allowingReadAccessTo readAccessURL: URL) -> WKNavigation? { nil }

    open func evaluateJavaScript(_ javaScriptString: String,
                                 completionHandler: ((Any?, Error?) -> Void)? = nil) {}
}

public enum WKNavigationActionPolicy: Int, Sendable {
    case cancel, allow
}

public enum WKNavigationType: Int, Sendable {
    case linkActivated, formSubmitted, backForward, reload, formResubmitted, other
}

open class WKNavigationAction: NSObject {
    open var navigationType: WKNavigationType = .other
}

public protocol WKNavigationDelegate: AnyObject {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void)
}
