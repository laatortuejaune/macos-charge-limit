// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatteryLimitMenu",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "BatteryLimitMenu", path: "Sources/BatteryLimitMenu")
    ]
)
