// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitwallUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitwallUI", targets: ["GitwallUI"]),
    ],
    dependencies: [
        .package(path: "../GitwallCore"),
    ],
    targets: [
        .target(name: "GitwallUI", dependencies: ["GitwallCore"]),
        .testTarget(name: "GitwallUITests", dependencies: ["GitwallUI"]),
    ],
    swiftLanguageModes: [.v6]
)
