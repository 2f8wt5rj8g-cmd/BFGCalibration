// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BFGCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "BFGCore", targets: ["BFGCore"])
    ],
    targets: [
        .target(name: "BFGCore"),
        .testTarget(name: "BFGCoreTests", dependencies: ["BFGCore"])
    ]
)
