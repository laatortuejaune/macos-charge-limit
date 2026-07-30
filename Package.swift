// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BatteryLimitMenu",
    // Cible de compilation volontairement basse : le code n'utilise aucune API
    // apparue après macOS 13, et la garder ainsi permet au projet de compiler sur
    // n'importe quel runner CI. La vraie exigence — macOS 26.4, première version
    // où la limite de charge est réglable — est portée par LSMinimumSystemVersion
    // dans Info.plist, qui est ce que macOS applique au lancement.
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "BatteryLimitMenu", path: "Sources/BatteryLimitMenu")
    ]
)
