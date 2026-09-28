// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BFGCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "BFGCore", targets: ["BFGCore"]),
        // The vehicle-side simulator. It exists so the client's state machine
        // can be exercised without a vehicle: the original project is a client
        // only, so this is built from what that client sends and accepts.
        .library(name: "BFGSimulator", targets: ["BFGSimulator"]),
        .executable(name: "bfgdemo", targets: ["bfgdemo"])
    ],
    targets: [
        .target(name: "BFGCore"),
        .target(name: "BFGSimulator", dependencies: ["BFGCore"]),
        .executableTarget(name: "bfgdemo", dependencies: ["BFGCore", "BFGSimulator"]),
        .testTarget(name: "BFGCoreTests", dependencies: ["BFGCore", "BFGSimulator"])
    ]
)
