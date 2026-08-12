import Foundation
import IOKit

// Temps restant, batterie et charge.
//
// Deux constats mesurés sur macOS 27 dictent tout ce fichier.
//
// 1. Aucun compteur système ne vise la limite de charge. `AvgTimeToFull` compte
//    toujours jusqu'à 100 %, quelle que soit la valeur du MCL : en basculant la
//    limite de 80 à 100 puis retour pendant une charge, la valeur n'a pas bougé
//    d'une seule minute. Le temps jusqu'à la limite doit donc être calculé ici.
//
// 2. `IOPSGetPowerSourceDescription`, l'API publique, renvoie -1 en permanence
//    sur cette machine — à la charge comme sur batterie, et `pmset` affiche
//    « no estimate » de la même façon. D'où la lecture directe d'AppleSmartBattery
//    dans l'IORegistry : l'accès est public, les noms de clés ne le sont pas.

enum BatteryTime {

    /// Ligne d'état à afficher, ou `nil` si la machine n'a pas de batterie lisible.
    ///
    /// Tout est déduit d'un **unique instantané** : si l'utilisateur débranche
    /// pendant la lecture, l'affichage reste cohérent avec lui-même et c'est le
    /// rafraîchissement suivant qui montrera le changement.
    /// `snapshot` n'est fourni que par les tests : il permet de rejouer les états
    /// qu'on ne peut pas provoquer à volonté (limite atteinte, charge suspendue,
    /// batterie au-dessus de la limite) sans attendre le bon moment.
    static func summary(limit: Int?, snapshot: [String: Any]? = nil) -> String? {
        guard let snapshot = snapshot ?? batterySnapshot(),
              flag(snapshot, "BatteryInstalled")
        else { return nil }

        let level = integer(snapshot, "CurrentCapacity") ?? 0

        guard flag(snapshot, "ExternalConnected") else {
            guard let remaining = duration(snapshot, "TimeRemaining")
                    ?? duration(snapshot, "AvgTimeToEmpty")
            else { return L("battery.computing") }
            return L("battery.remaining", format(remaining))
        }

        if flag(snapshot, "FullyCharged") { return L("battery.charged") }

        guard flag(snapshot, "IsCharging") else {
            // Branché sans charger : soit la limite est atteinte, soit la charge
            // est suspendue (chaleur, charge optimisée…). Pas de compte à rebours.
            if let limit, level >= limit { return L("battery.limitReached", limit) }
            return L("battery.paused")
        }

        // Sans limite, le compteur d'Apple vise déjà exactement ce qu'on veut :
        // on l'affiche tel quel, sans tilde, c'est son estimation non retouchée.
        guard let limit, limit < 100 else {
            guard let toFull = duration(snapshot, "AvgTimeToFull")
            else { return L("battery.computing") }
            return L("battery.untilFull", format(toFull))
        }

        guard level < limit else { return L("battery.limitReached", limit) }
        guard let toLimit = minutesToLimit(snapshot, level: level, limit: limit)
        else { return L("battery.computing") }
        return L("battery.untilLimit", format(toLimit), limit)
    }

    // MARK: - Estimation jusqu'à la limite

    /// `AvgTimeToFull` ne sert à rien ici : c'est une moyenne sur toute la courbe
    /// jusqu'à 100 %, or la charge sous ~80 % va bien plus vite que cette moyenne
    /// — mesuré à peu près deux fois plus vite sur une charge réelle. La mettre à
    /// l'échelle du pourcentage restant surestimerait donc d'autant.
    ///
    /// On extrapole plutôt sur le courant de charge, ce qui est valide tant qu'on
    /// est sous le palier où la charge commence à ralentir. C'est précisément le
    /// cas qui nous intéresse, puisque la limite la plus basse est 80 %.
    /// Reste une estimation : le courant dépend de la charge machine et de ce que
    /// l'adaptateur alimente par ailleurs, d'où l'arrondi et le tilde à l'affichage.
    private static func minutesToLimit(_ snapshot: [String: Any],
                                       level: Int, limit: Int) -> Int? {
        guard let current = amperage(snapshot), current > 0,
              let battery = snapshot["BatteryData"] as? [String: Any],
              let capacity = (battery["DesignCapacity"] as? NSNumber)?.doubleValue,
              capacity > 0
        else { return nil }

        let missing = Double(limit - level) / 100 * capacity
        let estimate = Int((missing / Double(current) * 60).rounded())

        // Une valeur absurde vaut mieux tue : le courant vient d'un capteur qui
        // ne se rafraîchit qu'à la minute et peut être pris en pleine transition.
        guard estimate > 0, estimate < 12 * 60 else { return nil }
        return max(5, (estimate + 2) / 5 * 5)
    }

    // MARK: - Lecture brute

    private static func batterySnapshot() -> [String: Any]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties,
                                                kCFAllocatorDefault, 0) == KERN_SUCCESS
        else { return nil }
        return properties?.takeRetainedValue() as? [String: Any]
    }

    private static func integer(_ snapshot: [String: Any], _ key: String) -> Int? {
        (snapshot[key] as? NSNumber)?.intValue
    }

    /// Ces clés sont des entiers 0/1 dans l'IORegistry, pas des booléens
    /// CoreFoundation — `as? Bool` marcherait par accident et masquerait le reste.
    private static func flag(_ snapshot: [String: Any], _ key: String) -> Bool {
        (integer(snapshot, key) ?? 0) != 0
    }

    /// `Amperage` est stocké non signé : négatif une fois réinterprété = décharge.
    private static func amperage(_ snapshot: [String: Any]) -> Int? {
        guard let raw = (snapshot["Amperage"] as? NSNumber)?.uint64Value else { return nil }
        return Int(Int64(bitPattern: raw))
    }

    /// Les compteurs valent -1 tant que l'estimation n'est pas stabilisée, et
    /// 65535 (0xFFFF) quand elle est sans objet.
    private static func duration(_ snapshot: [String: Any], _ key: String) -> Int? {
        guard let value = integer(snapshot, key), value > 0, value != 65535 else { return nil }
        return value
    }

    private static func format(_ minutes: Int) -> String {
        guard minutes >= 60 else { return L("time.minutes", minutes) }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? L("time.hours", hours) : L("time.hoursMinutes", hours, rest)
    }
}
