import Foundation

// Bascule du mode économie d'énergie.
//
// La lecture passe par l'API privée `_PMLowPowerMode` (voir BatteryTime), qui
// répond en process et sans aucun droit. L'écriture, elle, est verrouillée :
// `setPowerMode:fromSource:` ne fait rien depuis une app tierce — le démon
// vérifie l'entitlement de l'appelant, testé aussi depuis un bundle signé.
//
// Le seul chemin d'écriture est `pmset -a lowpowermode`, qui exige root, comme
// `disablesleep` pour la veille. On s'appuie donc sur la même règle sudoers
// posée une fois par Tools/install-helper.sh — étendue à ces deux commandes.
// Sans la règle, la bascule est indisponible et l'app se rabat sur l'ouverture
// des Réglages, exactement comme la couverture du capot fermé.
//
// `-a` : le réglage vaut pour secteur ET batterie, ce qui correspond à la
// bascule rapide « activé / désactivé » plutôt qu'à un choix par source.

enum LowPower {

    /// Chemin absolu : une règle sudoers compare la commande au chemin résolu,
    /// donc un `pmset` trouvé via $PATH ne correspondrait à aucune règle.
    private static let pmset = "/usr/bin/pmset"

    /// La règle sudoers autorise-t-elle la bascule *sans mot de passe* ?
    ///
    /// `sudo -n -l <commande>` ne convient pas : sur un compte admin il répond
    /// « oui » dès que la commande est autorisée, même si elle exige un mot de
    /// passe — un faux positif qui ferait promettre au bouton une bascule qui
    /// échouerait ensuite. On liste donc les règles et on cherche une entrée
    /// NOPASSWD qui mentionne précisément lowpowermode. `-n` fait échouer la
    /// liste (donc renvoyer false) si elle-même demandait un mot de passe.
    static func canToggle() -> Bool {
        guard let output = run("/usr/bin/sudo", ["-n", "-l"])?.output else { return false }
        return output.split(separator: "\n").contains {
            $0.contains("NOPASSWD") && $0.contains("lowpowermode")
        }
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        run("/usr/bin/sudo", ["-n", pmset, "-a", "lowpowermode", on ? "1" : "0"])?
            .status == 0
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
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
