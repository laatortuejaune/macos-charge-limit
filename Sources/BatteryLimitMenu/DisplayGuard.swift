import Foundation
import IOKit
import IOKit.pwr_mgt

// Empêcher l'écran de s'éteindre.
//
// POURQUOI CE N'EST PAS LE MÊME BOUTON QUE LA VEILLE. `SleepGuard` pose
// `PreventUserIdleSystemSleep`, qui empêche la machine de dormir mais AUTORISE
// explicitement l'écran à s'éteindre : c'est même son intérêt, un serveur qui
// tourne écran noir. D'où le symptôme qui a motivé ce fichier — un Mac qui ne
// dort jamais mais dont l'écran s'éteint quand même au bout du délai des
// Réglages. Le seul type qui tient l'écran allumé est
// `PreventUserIdleDisplaySleep`, et il faut le demander séparément.
//
// L'INCLUSION VA DANS UN SEUL SENS. Tenir l'écran allumé empêche de fait la
// veille par inactivité — un écran allumé n'est pas une machine endormie. La
// réciproque est fausse. Les deux boutons ne sont donc pas redondants : celui-ci
// implique l'autre, l'autre n'implique pas celui-ci. C'est ce que disent les
// infobulles, plutôt que de laisser deviner.
//
// AUCUN DROIT REQUIS, et rien qui survive à l'app. Contrairement au capot fermé
// de `SleepGuard`, qui passe par `pmset -a disablesleep` et reste posé après la
// mort du processus, une assertion meurt avec lui : au pire plantage, le système
// la relâche seul. Il n'y a donc pas de garde-fou à prévoir ici.

enum DisplayGuard {

    /// Motif affiché par `pmset -g assertions`. En anglais et non localisé, comme
    /// celui de `SleepGuard` : c'est une chaîne de diagnostic lue au terminal,
    /// et c'est elle qui rend l'état vérifiable sans croire la teinte du menu.
    private static let reason = "BatteryLimitMenu: display sleep prevented from the menu bar"

    private static let type = kIOPMAssertionTypePreventUserIdleDisplaySleep

    private static var held: IOPMAssertionID?

    static var isActive: Bool { held != nil }

    /// Bascule, en rendant compte de l'échec plutôt qu'en le taisant : une
    /// assertion refusée laisserait une icône allumée devant un écran qui
    /// s'éteint. `false` seulement si la prise a échoué.
    @discardableResult
    static func toggle() -> Bool {
        if held != nil {
            release()
            return true
        }
        var id = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString,
                                                 &id)
        guard status == kIOReturnSuccess else { return false }
        held = id
        return true
    }

    static func release() {
        guard let id = held else { return }
        IOPMAssertionRelease(id)
        held = nil
    }

    /// `true` si l'écran est tenu allumé par *quelqu'un d'autre* que cette app :
    /// une vidéo en lecture, une présentation, un `caffeinate -d` oublié.
    ///
    /// Même raison que dans `SleepGuard` : sans cette lecture, une icône éteinte
    /// affirmerait « l'écran va s'éteindre » devant un écran qui restera allumé.
    /// `nil` si le décompte est illisible — mieux vaut se taire qu'affirmer.
    static func heldElsewhere() -> Bool? {
        var counts: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&counts) == kIOReturnSuccess,
              let status = counts?.takeRetainedValue() as? [String: Any]
        else { return nil }
        let total = (status[type] as? NSNumber)?.intValue ?? 0
        return total - (held == nil ? 0 : 1) > 0
    }
}
