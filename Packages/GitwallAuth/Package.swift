// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitwallAuth",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitwallAuth", targets: ["GitwallAuth"]),
    ],
    dependencies: [
        .package(path: "../GitwallCore"),
    ],
    targets: [
        .target(
            name: "GitwallAuth",
            dependencies: [
                .product(name: "GitwallCore", package: "GitwallCore"),
            ]
        ),
        .testTarget(
            name: "GitwallAuthTests",
            dependencies: ["GitwallAuth"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
