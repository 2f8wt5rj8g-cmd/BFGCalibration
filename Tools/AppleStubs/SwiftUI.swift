// Type-checking stub for SwiftUI. See Tools/typecheck-ios.sh.
import Foundation
import UIKit

public protocol View {}

public protocol ObservableObject: AnyObject {}

@propertyWrapper
public struct StateObject<ObjectType: ObservableObject> {
    public init(wrappedValue: @autoclosure @escaping () -> ObjectType) {}
    public var wrappedValue: ObjectType { fatalError("stub") }
}

public struct SafeAreaRegions: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let all = SafeAreaRegions(rawValue: 1)
    public static let container = SafeAreaRegions(rawValue: 2)
    public static let keyboard = SafeAreaRegions(rawValue: 4)
}

public struct Edge {
    public struct Set: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let all = Set(rawValue: 1)
        public static let bottom = Set(rawValue: 2)
    }
}

extension View {
    public func ignoresSafeArea(_ regions: SafeAreaRegions = .all,
                                edges: Edge.Set = .all) -> some View { self }
}

public struct UIViewRepresentableContext<Representable> {}

public struct ProposedViewSize {
    public var width: CGFloat?
    public var height: CGFloat?
    public init(width: CGFloat? = nil, height: CGFloat? = nil) {
        self.width = width
        self.height = height
    }
}

public protocol UIViewRepresentable: View {
    associatedtype UIViewType: UIView
    associatedtype Coordinator

    func makeCoordinator() -> Coordinator
    func makeUIView(context: Context) -> UIViewType
    func updateUIView(_ uiView: UIViewType, context: Context)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIViewType,
                      context: Context) -> CGSize?
}

extension UIViewRepresentable {
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIViewType,
                             context: Context) -> CGSize? { nil }
}

extension UIViewRepresentable {
    public typealias Context = UIViewRepresentableContext<Self>
}

@resultBuilder
public struct ViewBuilder {
    public static func buildBlock<Content: View>(_ content: Content) -> Content { content }
}

@resultBuilder
public struct SceneBuilder {
    public static func buildBlock<Content: Scene>(_ content: Content) -> Content { content }
}

public protocol Scene {}

public struct WindowGroup<Content: View>: Scene {
    public init(@ViewBuilder content: @escaping () -> Content) {}
}

public protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Self.Body { get }
    init()
}

extension App {
    public static func main() {}
}
