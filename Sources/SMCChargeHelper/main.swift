import Foundation
import IOKit
import SMC

// Helper privilégié — la seule partie du projet qui tourne en root.
//
// SA SURFACE EST VOLONTAIREMENT MINUSCULE. Il n'accepte que deux mots, `on` et
// `off`, et n'écrit qu'une clé, `CHIE`. Une règle sudoers autorisant l'écriture
// SMC arbitraire donnerait à quiconque peut lancer ce binaire le pouvoir de
// reprogrammer le contrôleur d'alimentation ; celle-ci ne donne que le droit de
// suspendre la charge.
//
// POURQUOI IL DOIT APPARTENIR À ROOT. La règle sudoers désigne un chemin. Si le
// binaire à ce chemin est modifiable par l'utilisateur, la règle devient une
// élévation de privilège : il suffit de le remplacer pour faire exécuter
// n'importe quoi en root sans mot de passe. `Tools/install-helper.sh` l'installe
// donc hors du dépôt, en root:wheel et 755 — jamais depuis un dossier que
// l'utilisateur peut réécrire.
//
// CHIE — mesurée, pas devinée. Les clés que citent les outils du genre AlDente,
// `CH0B` et `BCLM`, n'existent pas sur cette machine : l'énumération des 2 494
// clés du SMC a permis de trouver celle-ci. Vérifiée sur une charge en cours :
//
//     CHIE = 01  ->  courant 5668 mA -> 0 mA en 3 secondes
//     CHIE = 00  ->  remontée à 5653 mA
//
// Sens contre-intuitif : 01 inhibe, 00 laisse charger.

let key = "CHIE"

/// Plancher de sécurité, appliqué ici et pas seulement dans l'app.
///
/// Inhiber la charge branché fait vivre la machine sur l'adaptateur, mais la
/// batterie continue de se vider lentement — et à zéro le Mac s'éteint. Ce
/// garde-fou tient même si l'app se trompe, plante, ou si quelqu'un appelle le
/// helper à la main. Couper l'inhibition reste évidemment toujours permis.
let floor = 15

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func batteryPercentage() -> Int? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties,
                                            kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let dictionary = properties?.takeRetainedValue() as? [String: Any]
    else { return nil }
    return (dictionary["CurrentCapacity"] as? NSNumber)?.intValue
}

let arguments = CommandLine.arguments
guard arguments.count == 2, ["on", "off", "status"].contains(arguments[1]) else {
    fail("usage: \(arguments[0]) on|off|status")
}
let command = arguments[1]

guard let connection = SMC.Connection() else { fail("AppleSMC inaccessible") }
defer { connection.close() }

// Si `#KEY` ne répond pas, le dialogue avec le pilote est cassé : mieux vaut
// s'arrêter que d'écrire à l'aveugle dans un contrôleur d'alimentation.
guard SMC.keyCount(connection) != nil else { fail("dialogue SMC rompu — rien n'a été écrit") }

guard let current = SMC.read(connection, key), current.count == 1 else {
    fail("\(key) illisible sur cette machine — l'inhibition de charge n'y est pas disponible")
}

if command == "status" {
    print(current[0] == 0 ? "off" : "on")
    exit(0)
}

guard getuid() == 0 else { fail("cette commande exige root") }

if command == "on", let level = batteryPercentage(), level < floor {
    fail("batterie à \(level) %, sous le plancher de \(floor) % — inhibition refusée")
}

let target: UInt8 = command == "on" ? 1 : 0
guard SMC.write(connection, key, [target]) else { fail("écriture \(key) refusée par le SMC") }

// On relit plutôt que de faire confiance au code de retour : c'est l'état réel
// qui compte. Mais la clé NE REND PAS CE QU'ON Y ÉCRIT — c'est ce qui a coûté
// deux diagnostics faux avant d'être vu :
//
//     on écrit 1  ->  la clé relit 8, et la charge s'arrête
//     on écrit 0  ->  la clé relit 0, et la charge repart
//
// 1 est donc une commande, 8 un état. Exiger l'égalité stricte faisait échouer
// une commande qui avait parfaitement fonctionné — et comme le helper sortait en
// erreur, un `helper on && helper off` s'arrêtait au milieu et laissait la charge
// suspendue. On vérifie donc l'effet — inhibé ou non — et pas la valeur.
//
// Une latence subsiste : la relecture immédiate voit encore l'ancien état, d'où
// les réessais. Elle est réelle, contrairement à la piste « une seule connexion
// par processus » que le diagnostic a écartée — deux connexions simultanées
// s'ouvrent sans problème.
let wantInhibited = target != 0
var settled = false
for _ in 0..<20 {
    usleep(50_000)
    guard let value = SMC.read(connection, key)?.first else { continue }
    if (value != 0) == wantInhibited { settled = true; break }
}
guard settled else {
    fail("\(key) n'a pas pris l'état demandé — état réel inconnu, redémarrer remet le SMC à plat")
}
print(command)
