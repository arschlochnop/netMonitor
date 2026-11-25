// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetMonitor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "NetMonitor", targets: ["NetMonitor"]),
        .library(name: "NetMonitorCore", targets: ["NetMonitorCore"]),
    ],
    targets: [
        .target(name: "NetMonitorCore"),
        .executableTarget(name: "NetMonitor", dependencies: ["NetMonitorCore"]),
        .testTarget(name: "NetMonitorCoreTests", dependencies: ["NetMonitorCore"]),
    ]
)
