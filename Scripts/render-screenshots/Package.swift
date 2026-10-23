// swift-tools-version: 5.9
import PackageDescription

// Dev-only: renders the README screenshots offscreen with FAKE data. Not part of the app or CI.
//   swift run --package-path Scripts/render-screenshots render docs/screenshots
let package = Package(
    name: "render-screenshots",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../AgentsMonitorKit")],
    targets: [
        .executableTarget(
            name: "render",
            dependencies: [.product(name: "AgentsMonitorKit", package: "AgentsMonitorKit")]
        )
    ]
)
