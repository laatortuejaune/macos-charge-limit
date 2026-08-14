import Foundation
import IOKit
import IOKit.pwr_mgt

// Empêcher la veille, sur deux mécanismes distincts.
//
// 1. LES ASSERTIONS (sans aucun droit). `caffeinate` n'est pas un mécanisme à
//    part : il pose des assertions d'alimentation via
//    `IOPMAssertionCreateWithName`, puis attend. L'API est publique et ne demande
//    rien, ce qui la met dans la même famille que le reste de l'app. On en pose
//    deux, parce qu'elles ne couvrent pas le même cas :
//
//      PreventUserIdleSystemSleep   le minuteur d'inactivité des Réglages
//      PreventSystemSleep           la veille système tant que le secteur est là
//
// 2. LE CAPOT FERMÉ (root, en option). Fermer l'écran déclenche une veille
//    « clamshell » qui court-circuite les assertions. Le seul levier est
//    `pmset -a disablesleep`, qui exige root. Plutôt qu'un helper privilégié,
//    l'app s'appuie sur une règle sudoers posée une fois à la main par
//    `Tools/install-helper.sh`, limitée à ces deux commandes exactes.
//    Sans cette règle, l'app fonctionne — elle couvre tout sauf le capot, et le
//    dit.
//
// LA DIFFÉRENCE QUI COMPTE ENTRE LES DEUX. Une assertion meurt avec le processus
// qui la porte : si l'app quitte ou plante, le système la relâche seul.
// `disablesleep` est un réglage système : il SURVIT à la mort de l'app et au
// redémarrage. Laissé derrière soi, il donne un Mac qui ne dort plus jamais,
// sans rien à l'écran pour l'expliquer — un portable qui cuit dans un sac fermé.
// D'où les deux garde-fous : `adoptSystemState()` au lancement et
// `releaseAll()` à l'extinction.

enum SleepGuard {

    /// Ce que l'app couvre à l'instant t.
    enum Coverage {
        /// Rien : la machine dort normalement.
        case off
        /// Inactivité couverte, capot NON couvert (règle sudoers absente ou refus).
        case idleOnly
        /// Inactivité et capot fermé couverts.
        case full
    }

    /// Ce qu'une bascule a réellement produit, pour que l'UI dise vrai.
    enum Outcome {
        case turnedOff
        case turnedOn(Coverage)
        /// Même les assertions ont été refusées : rien n'est posé.
        case refused
    }

    // MARK: - Assertions

    private static let types = [
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventSystemSleep,
    ]

    /// Motif affiché par `pmset -g assertions`. Volontairement en anglais et non
    /// localisé : c'est une chaîne de diagnostic lue dans un terminal, et c'est
    /// elle qui rend l'état vérifiable sans avoir à croire la coche du menu.
    private static let reason = "BatteryLimitMenu: sleep prevented from the menu bar"

    private static var held: [IOPMAssertionID] = []

    private static var holdsAssertions: Bool { !held.isEmpty }

    @discardableResult
    private static func takeAssertions() -> Bool {
        guard held.isEmpty else { return true }
        for type in types {
            var id = IOPMAssertionID(0)
            let status = IOPMAssertionCreateWithName(type as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason as CFString,
                                                     &id)
            guard status == kIOReturnSuccess else {
                // Un refus en cours de route laisserait l'app à moitié active :
                // le minuteur d'inactivité bloqué mais pas la veille système, ou
                // l'inverse. Aucune coche ne sait représenter ça honnêtement.
                dropAssertions()
                return false
            }
            held.append(id)
        }
        return true
    }

    private static func dropAssertions() {
        for id in held { IOPMAssertionRelease(id) }
        held.removeAll()
    }

    /// `true` si le Mac est tenu éveillé par *quelqu'un d'autre* que cette app.
    ///
    /// `IOPMCopyAssertionsStatus` compte pour tout le système, cette app comprise,
    /// d'où la soustraction. Sans cette lecture, une case décochée affirmerait
    /// « la veille n'est pas empêchée » à côté d'une machine qui ne dormira pas —
    /// un `caffeinate` oublié dans un terminal, une visioconférence.
    /// `nil` si le décompte est illisible : mieux vaut se taire qu'affirmer.
    static func heldElsewhere() -> Bool? {
        var counts: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&counts) == kIOReturnSuccess,
              let status = counts?.takeRetainedValue() as? [String: Any]
        else { return nil }
        let total = types.reduce(0) { $0 + ((status[$1] as? NSNumber)?.intValue ?? 0) }
        return total - held.count > 0
    }

    // MARK: - Capot fermé

    /// Chemin absolu : une règle sudoers compare la commande au chemin résolu,
    /// donc un `pmset` trouvé via $PATH ne correspondrait à aucune règle.
    private static let pmset = "/usr/bin/pmset"

    /// État réel du réglage système, lu et non déduit. `nil` si illisible.
    ///
    /// C'est la source de vérité, pas ce que l'app croit avoir fait : le réglage
    /// survit à l'app, donc il peut très bien avoir été posé par un lancement
    /// précédent, ou à la main dans un terminal.
    static func lidSleepDisabled() -> Bool? {
        guard let output = run(pmset, ["-g"])?.output else { return nil }
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            return fields[1] == "1"
        }
        return nil
    }

    /// La règle sudoers est-elle en place ? `sudo -l <commande complète>` répond
    /// sans rien exécuter, et `-n` lui interdit de demander un mot de passe —
    /// sans quoi une app sans terminal resterait bloquée sur une invite invisible.
    static func canCoverLid() -> Bool {
        run("/usr/bin/sudo", ["-n", "-l", pmset, "-a", "disablesleep", "1"])?.status == 0
    }

    @discardableResult
    private static func setLidSleepDisabled(_ disabled: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", pmset, "-a", "disablesleep", disabled ? "1" : "0"])?
            .status == 0
    }

    // MARK: - État et bascule

    static func coverage() -> Coverage {
        guard holdsAssertions else { return .off }
        return lidSleepDisabled() == true ? .full : .idleOnly
    }

    static var isActive: Bool { holdsAssertions }

    @discardableResult
    static func toggle() -> Outcome {
        if holdsAssertions {
            releaseAll()
            return .turnedOff
        }
        guard takeAssertions() else { return .refused }
        // Le capot en second : il n'a de sens qu'au-dessus des assertions, et
        // s'il échoue on garde quand même ce qui a marché plutôt que tout perdre.
        if canCoverLid(), setLidSleepDisabled(true) {
            return .turnedOn(.full)
        }
        return .turnedOn(.idleOnly)
    }

    /// Tout relâcher. Le capot d'abord : c'est le seul des deux qui survivrait.
    static func releaseAll() {
        if lidSleepDisabled() == true { setLidSleepDisabled(false) }
        dropAssertions()
    }

    /// À appeler au lancement.
    ///
    /// Si `disablesleep` est déjà posé — lancement précédent qui a planté, ou
    /// terminal — l'app l'ADOPTE au lieu de l'ignorer : elle prend les assertions
    /// et s'affiche active. Sans ça le menu montrerait une case décochée devant un
    /// Mac qui ne dort plus, et l'app serait le seul endroit d'où le réglage
    /// pourrait être retiré tout en prétendant ne rien en savoir.
    static func adoptSystemState() {
        guard lidSleepDisabled() == true, !holdsAssertions else { return }
        takeAssertions()
    }

    // MARK: - Exécution

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Jeté : `sudo -n` écrit son refus sur stderr, ce qui polluerait la
        // console de l'app à chaque vérification alors que le code de sortie dit
        // déjà tout ce qu'on veut savoir.
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        // Lu AVANT d'attendre : sur une sortie qui remplirait le tuyau, attendre
        // d'abord bloquerait les deux processus l'un sur l'autre.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
