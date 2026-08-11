// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClaudeMonitorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "ClaudeMonitorKit",
            targets: ["ClaudeMonitorKit"]
        ),
    ],
    targets: [
        .target(name: "ClaudeMonitorKit"),
        .testTarget(
            name: "ClaudeMonitorKitTests",
            dependencies: ["ClaudeMonitorKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
