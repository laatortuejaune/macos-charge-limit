import Foundation
import IOKit
import IOKit.pwr_mgt

// Empêcher la veille — et où ça s'arrête.
//
// `caffeinate` n'est pas un mécanisme à part : il pose des assertions
// d'alimentation via `IOPMAssertionCreateWithName`, puis attend. L'API est
// publique et ne demande aucun droit particulier, ce qui la met exactement dans
// la même famille que le reste de l'app — on demande au système, on ne contourne
// rien. Pas de helper privilégié, pas de root.
//
// Deux assertions sont posées ensemble parce qu'elles ne couvrent pas le même
// cas, et que poser la première seule laisse un trou :
//
//   PreventUserIdleSystemSleep   le minuteur d'inactivité des Réglages Batterie
//   PreventSystemSleep           la veille système tant que l'alimentation est là
//
// CE QUE ÇA NE COUVRE PAS : le capot fermé. Fermer l'écran déclenche une veille
// « clamshell » qui court-circuite les assertions posées. Le seul levier connu
// est `pmset -a disablesleep 1`, qui exige root. C'est un arrêt délibéré et non
// un oubli — voir le README.

enum SleepGuard {

    /// Les deux assertions à tenir. L'ordre n'a pas d'importance ; ce qui compte
    /// est qu'on les tienne toutes ou aucune, cf. `enable()`.
    private static let types = [
        kIOPMAssertionTypePreventUserIdleSystemSleep,
        kIOPMAssertionTypePreventSystemSleep,
    ]

    /// Motif affiché par `pmset -g assertions`. Volontairement en anglais et non
    /// localisé : c'est une chaîne de diagnostic, lue dans un terminal, et c'est
    /// elle qui rend l'état vérifiable sans avoir à croire la coche du menu.
    private static let reason = "BatteryLimitMenu: sleep prevented from the menu bar"

    /// Identifiants des assertions détenues. Vide = inactif.
    ///
    /// Une assertion ne survit pas au processus qui la porte : si l'app quitte ou
    /// meurt, le système les relâche seul. C'est le bon comportement — aucun Mac
    /// laissé éveillé par un processus qui n'existe plus — mais ça implique aussi
    /// que l'état ne se reporte pas d'un lancement au suivant.
    private static var held: [IOPMAssertionID] = []

    /// Ce que *cette* app tient. À distinguer de `heldElsewhere()`.
    static var isActive: Bool { !held.isEmpty }

    /// Pose les assertions. `false` si le système en refuse une.
    @discardableResult
    static func enable() -> Bool {
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
                // l'inverse. Aucune coche de menu ne sait représenter ça
                // honnêtement, donc on défait tout et on annonce l'échec.
                disable()
                return false
            }
            held.append(id)
        }
        return true
    }

    static func disable() {
        for id in held { IOPMAssertionRelease(id) }
        held.removeAll()
    }

    /// Bascule. `false` si l'activation a échoué ; désactiver ne peut pas échouer.
    @discardableResult
    static func toggle() -> Bool {
        if isActive {
            disable()
            return true
        }
        return enable()
    }

    /// `true` si le Mac est tenu éveillé par *quelqu'un d'autre* que cette app.
    ///
    /// `IOPMCopyAssertionsStatus` donne le décompte de tout le système, cette app
    /// comprise. Sans cette lecture, la case décochée du menu affirmerait « la
    /// veille n'est pas empêchée » à côté d'une machine qui ne dormira pas —
    /// caffeinate laissé tourner dans un terminal, une visioconférence, un
    /// Amphetamine. Ce qu'on affiche est alors l'état réel, pas notre nombril.
    ///
    /// `nil` si le décompte est illisible : on préfère ne rien dire à affirmer.
    static func heldElsewhere() -> Bool? {
        var counts: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsStatus(&counts) == kIOReturnSuccess,
              let status = counts?.takeRetainedValue() as? [String: Any]
        else { return nil }

        let total = types.reduce(0) { $0 + ((status[$1] as? NSNumber)?.intValue ?? 0) }
        // Nos propres assertions comptent dans le total : on les retranche pour
        // ne garder que ce qui vient d'ailleurs.
        return total - held.count > 0
    }
}
