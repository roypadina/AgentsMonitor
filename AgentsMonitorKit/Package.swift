// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentsMonitorKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "AgentsMonitorKit",
            targets: ["AgentsMonitorKit"]
        ),
    ],
    targets: [
        .target(name: "AgentsMonitorKit"),
        .testTarget(
            name: "AgentsMonitorKitTests",
            dependencies: ["AgentsMonitorKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
