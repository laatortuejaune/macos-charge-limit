import Foundation
import SMC

// Suspension de la charge, à n'importe quel niveau.
//
// CE QUE ÇA AJOUTE À LA LIMITE. La limite de charge ne descend pas sous 80 % :
// le système ne propose que 80, 85, 90, 95, 100. Au-dessus de 80 on peut donc
// déjà empêcher la charge en abaissant la limite — c'est ce que fait le reste de
// l'app, sans aucun privilège. En dessous, il n'y avait rien. C'est ce trou que
// ce fichier comble.
//
// TOUT LE RESTE A ÉTÉ ÉCARTÉ PAR LA MESURE, pas par principe :
//
//   PowerUI            54 classes, 1 853 méthodes balayées. Tout son vocabulaire
//                      va dans l'autre sens — `temporarilyEnableCharging`,
//                      `disableMCL` — soit charger PLUS. Rien pour bloquer.
//   Assertions IOKit   `ChargeInhibit` et `DisableInflow` sont acceptées sans
//                      root, et sans le moindre effet : la charge a continué à
//                      6,1 A pendant 90 s d'inhibition. Types hérités qu'macOS
//                      enregistre par compatibilité et ignore.
//   SMC `CH0B`/`BCLM`  les clés que citent les outils du genre AlDente
//                      n'existent pas sur cette machine.
//
// Reste `CHIE`, trouvée en énumérant les 2 494 clés du SMC. Sens contre-intuitif :
// 01 inhibe, 00 laisse charger.
//
// L'ÉCRITURE EXIGE ROOT, la lecture non. D'où la même forme que la veille capot
// fermé : l'app lit l'état pour rien, et délègue l'écriture à un helper minuscule
// installé une fois par `Tools/install-helper.sh`. Sans la règle, la lecture et
// l'affichage marchent quand même — seule la bascule est indisponible, et le
// menu le dit.
//
// CE RÉGLAGE SURVIT À L'APP, comme `disablesleep`. Laissé derrière soi, il donne
// un Mac branché qui ne charge plus, sans rien à l'écran pour l'expliquer — et
// cette fois la batterie se vide. D'où trois garde-fous : la reprise en main au
// lancement, la remise à zéro en quittant, et un plancher de charge appliqué
// aussi bien ici que dans le helper.

enum ChargeInhibit {

    /// Chemin absolu et hors du dépôt. Une règle sudoers désigne un chemin : si
    /// le binaire qui s'y trouve est modifiable par l'utilisateur, la règle
    /// devient une élévation de privilège. Il appartient donc à root.
    private static let helper = "/usr/local/libexec/batterylimitmenu-smc"

    /// Sous ce niveau, on refuse d'inhiber et on relâche ce qui l'était.
    /// Branché sans charger, la machine vit sur l'adaptateur mais la batterie
    /// se vide lentement — et à zéro le Mac s'éteint.
    static let floor = 15

    /// La machine expose-t-elle la clé ? Lue une fois : le SMC ne se réorganise
    /// pas en cours de session.
    static let isSupported: Bool = {
        guard let connection = SMC.Connection() else { return false }
        defer { connection.close() }
        // `#KEY` d'abord : sans lui, un `nil` sur CHIE ne distinguerait pas une
        // machine sans la clé d'un dialogue rompu.
        guard SMC.keyCount(connection) != nil else { return false }
        return SMC.read(connection, "CHIE")?.count == 1
    }()

    /// État réel, relu et non déduit — il survit à l'app, donc il peut venir
    /// d'un lancement précédent ou d'un appel au helper à la main.
    static func isActive() -> Bool? {
        guard let connection = SMC.Connection() else { return nil }
        defer { connection.close() }
        return SMC.read(connection, "CHIE")?.first.map { $0 != 0 }
    }

    /// La règle sudoers est-elle en place ? On lit la liste NOPASSWD et on y
    /// cherche le chemin du helper, plutôt que d'interroger `sudo -l` sur une
    /// commande précise : pour un administrateur, cette forme répond oui même
    /// sans règle, et la bascule échouerait ensuite au clic.
    static func canToggle() -> Bool {
        guard let output = run("/usr/bin/sudo", ["-n", "-l"])?.output else { return false }
        return output.split(separator: "\n").contains {
            $0.contains("NOPASSWD") && $0.contains(helper)
        }
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        if on, let level = BatteryTime.gauge()?.level, level < floor { return false }
        return run("/usr/bin/sudo", ["-n", helper, on ? "on" : "off"])?.status == 0
    }

    /// À appeler au lancement et à chaque rafraîchissement : si la batterie est
    /// tombée sous le plancher alors que la charge était suspendue, on relâche.
    /// Sans ça, une inhibition oubliée viderait la batterie jusqu'à l'extinction.
    static func enforceFloor() {
        guard isSupported, isActive() == true,
              let level = BatteryTime.gauge()?.level, level < floor
        else { return }
        set(false)
    }

    /// À appeler en quittant. Le réglage est le seul de l'app à survivre au
    /// processus, et sa conséquence — une batterie qui ne se recharge plus — est
    /// pire qu'un Mac qui ne dort pas.
    static func releaseAll() {
        guard isSupported, isActive() == true else { return }
        set(false)
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        // Jeté : `sudo -n` écrit son refus sur stderr, ce qui polluerait la
        // console à chaque vérification alors que le code de sortie suffit.
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
