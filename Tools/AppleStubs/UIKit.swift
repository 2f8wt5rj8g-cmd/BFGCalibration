// Type-checking stub for UIKit. See Tools/typecheck-ios.sh for why these exist.
//
// CGRect is deliberately not declared here: Foundation on Linux already
// provides the real one, and redefining it would shadow it.
import Foundation

open class UIView {
    public init(frame: CGRect) {}
    public init() {}
    open var isOpaque: Bool = true
    open var bounds: CGRect = .zero
    open var frame: CGRect = .zero
}

open class UIScrollView: UIView {
    open var bounces: Bool = true
}

open class UIApplication {
    public static let shared = UIApplication()
    public static let openSettingsURLString = "app-settings:"
    open func open(_ url: URL) {}
}
