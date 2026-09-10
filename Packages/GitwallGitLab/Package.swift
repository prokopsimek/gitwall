// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitwallGitLab",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GitwallGitLab", targets: ["GitwallGitLab"]),
    ],
    dependencies: [
        .package(path: "../GitwallCore"),
    ],
    targets: [
        .target(
            name: "GitwallGitLab",
            dependencies: [.product(name: "GitwallCore", package: "GitwallCore")]
        ),
        .testTarget(
            name: "GitwallGitLabTests",
            dependencies: ["GitwallGitLab"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
