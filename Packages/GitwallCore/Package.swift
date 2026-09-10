// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitwallCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitwallCore", targets: ["GitwallCore"]),
    ],
    targets: [
        .target(name: "GitwallCore"),
        .testTarget(
            name: "GitwallCoreTests",
            dependencies: ["GitwallCore"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
