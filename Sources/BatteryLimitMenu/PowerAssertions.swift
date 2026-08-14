import Foundation
import IOKit
import IOKit.pwr_mgt

// « Est-ce que QUELQU'UN D'AUTRE tient la machine éveillée ? »
//
// Cette question a l'air d'appeler `IOPMCopyAssertionsStatus`, qui rend un
// dictionnaire type → nombre. Le piège est que ce nombre n'est PAS un compte
// d'assertions mais un NIVEAU 0/1. Mesuré :
//
//     aucune assertion         -> 0
//     une assertion (la nôtre) -> 1
//     deux assertions (nôtres) -> 1     <-- et non 2
//
// Retrancher le nombre d'assertions qu'on tient soi-même — le réflexe naturel —
// donne donc toujours 1 - 1 = 0 dès qu'on en tient une : l'app conclut « personne
// d'autre » précisément dans le cas où elle a besoin de savoir. L'infobulle qui
// existe pour prévenir « un lecteur vidéo garde aussi l'écran allumé » se tait
// exactement quand elle serait utile.
//
// `IOPMCopyAssertionsByProcess` rend la liste réelle, ventilée par processus. On
// écarte le nôtre par son pid plutôt que par soustraction, ce qui règle du même
// coup le cas où l'app en tient plusieurs.

enum PowerAssertions {

    /// Un tiers tient-il l'un de ces types ? `nil` si le décompte est illisible —
    /// mieux vaut se taire qu'affirmer.
    static func heldByOthers(_ types: [String]) -> Bool? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
        else { return nil }

        let mine = ProcessInfo.processInfo.processIdentifier
        for (pid, assertions) in byProcess where pid.int32Value != mine {
            for assertion in assertions where types.contains(where: { assertion.declares($0) }) {
                return true
            }
        }
        return false
    }
}

private extension Dictionary where Key == String, Value == Any {
    /// Les deux clés sont à lire. Une assertion créée sous un nom hérité — par
    /// exemple `NoDisplaySleepAssertion` — se déclare sous ce nom-là dans la
    /// première, et ne révèle le type moderne que dans la seconde. N'en lire
    /// qu'une laisserait passer les processus qui utilisent l'autre.
    ///
    /// La seconde est écrite en clair faute de constante exposée à Swift ; les
    /// deux noms ont été relevés sur le dictionnaire réel, pas supposés. À noter
    /// que `kIOPMAssertionTypeKey` vaut `AssertType` et non `AssertionType` :
    /// lire la clé qu'on croit deviner rend un dictionnaire toujours vide.
    func declares(_ type: String) -> Bool {
        [kIOPMAssertionTypeKey as String, "AssertionTrueType"]
            .contains { (self[$0] as? String) == type }
    }
}
