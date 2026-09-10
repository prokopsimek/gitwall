// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitwallGitHub",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitwallGitHub", targets: ["GitwallGitHub"]),
    ],
    dependencies: [
        .package(path: "../GitwallCore"),
    ],
    targets: [
        .target(
            name: "GitwallGitHub",
            dependencies: [.product(name: "GitwallCore", package: "GitwallCore")]
        ),
        .testTarget(
            name: "GitwallGitHubTests",
            dependencies: ["GitwallGitHub"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
