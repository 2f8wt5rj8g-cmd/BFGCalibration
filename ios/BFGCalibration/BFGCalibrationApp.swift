import SwiftUI

@main
struct BFGCalibrationApp: App {
    @StateObject private var coordinatorHost = CoordinatorHost()

    var body: some Scene {
        WindowGroup {
            // All edges are ignored so the page reaches the physical screen;
            // the HTML insets itself with env(safe-area-inset-*) against the
            // notch and the home indicator.
            PrototypeWebView(coordinator: coordinatorHost.coordinator)
                .ignoresSafeArea()
        }
    }
}

/// `PrototypeCoordinator` must outlive the view and is not an `ObservableObject`,
/// so it is owned here rather than created inside `makeUIView` — recreating it
/// would drop the live BLE session on every SwiftUI update.
final class CoordinatorHost: ObservableObject {
    let coordinator = PrototypeCoordinator()
}
