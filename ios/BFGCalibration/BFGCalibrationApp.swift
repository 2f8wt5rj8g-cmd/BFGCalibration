import SwiftUI

@main
struct BFGCalibrationApp: App {
    @StateObject private var coordinatorHost = CoordinatorHost()

    var body: some Scene {
        WindowGroup {
            PrototypeWebView(coordinator: coordinatorHost.coordinator)
                .ignoresSafeArea(.container, edges: .bottom)
        }
    }
}

/// `PrototypeCoordinator` must outlive the view and is not an `ObservableObject`,
/// so it is owned here rather than created inside `makeUIView` — recreating it
/// would drop the live BLE session on every SwiftUI update.
final class CoordinatorHost: ObservableObject {
    let coordinator = PrototypeCoordinator()
}
