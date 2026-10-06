// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SnapShelf",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SnapShelf", targets: ["SnapShelf"])],
    targets: [
        .target(name: "SnapCore"),
        .executableTarget(name: "SnapShelf", dependencies: ["SnapCore"]),
        // Runs with Apple's Command Line Tools alone; XCTest requires full Xcode.
        .executableTarget(name: "SnapCoreChecks", dependencies: ["SnapCore"], path: "Tests/SnapCoreTests")
    ]
)
