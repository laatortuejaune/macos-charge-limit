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
        // Le protocole SMC est partagé : l'app lit sans droits, le helper écrit
        // sous root. Deux copies d'un code où une erreur d'offset ne lève aucune
        // erreur — elle rend juste un dialogue muet — divergeraient trop vite.
        .target(name: "SMC", path: "Sources/SMC"),
        .executableTarget(name: "BatteryLimitMenu", dependencies: ["SMC"],
                          path: "Sources/BatteryLimitMenu"),
        // Seule partie du projet qui tourne en root, et la plus petite possible :
        // deux mots acceptés, une clé écrite.
        .executableTarget(name: "SMCChargeHelper", dependencies: ["SMC"],
                          path: "Sources/SMCChargeHelper"),
    ]
)
