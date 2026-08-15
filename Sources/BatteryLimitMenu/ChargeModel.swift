import Foundation

// Modèle de charge calibré : le courant n'est PAS constant.
//
// Mesuré sur cette machine (nuit du 15/08/2026, chargeur 35 W, adaptateur seul,
// machine au repos) : la charge procède par PALIERS de courant — ~4,5 A jusqu'à
// ~83 %, ~3,15 A jusqu'à ~91 %, puis décroissance franche — et non selon la
// décroissance exponentielle continue qu'on prête aux charges CC/CV. La formule
// « manquant / courant » de l'app supposait le courant constant : elle annonçait
// 24 min pour un 81 → 100 qui en prend plus du double.
//
// LE MODÈLE. Pour chaque pourcent s entre le niveau et la limite :
//
//     I_prédit(s) = min(I_mesuré_maintenant, table(s))
//
// puis temps = Σ mAh_du_pas / I_prédit. Le min encode la physique : en dessous
// du coude le courant est fixé par le chargeur (donc suivre la MESURE, qui
// s'adapte à un chargeur plus faible ou à une machine chargée) ; au-dessus il
// est fixé par la batterie (donc suivre la TABLE, identique quel que soit le
// chargeur). Le coude n'est pas un paramètre : c'est le point de croisement.
//
// DOMAINE DE VALIDITÉ. La table vient du chargeur 35 W de la machine. Sous
// `tableFloor` le courant est étagé aussi (6,35 A puis 4,5 A vers 69 % sur une
// calibration antérieure) mais PAS tabulé : on y suit le courant mesuré, qui
// re-converge à chaque rafraîchissement — c'est l'approximation qu'on avait déjà
// et elle vaut 3 min d'erreur médiane sur un 20 → 80. Un chargeur plus puissant
// que celui de calibration rendrait la table légèrement pessimiste au-dessus du
// coude (la phase CV est surtout bornée par la batterie, elle bouge peu) : on
// l'assume, l'alternative — extrapoler un courant constant qu'on sait faux —
// s'est mesurée à 40 % d'erreur.
enum ChargeModel {

    /// Courant de charge moyen observé (mA) pour traverser chaque pourcent, du
    /// premier palier contraint jusqu'à 99 → 100. En dessous de `tableFloor` la
    /// table ne contraint rien : le courant mesuré gouverne seul.
    ///
    /// Calibration du 15/08/2026, charge continue 83 → 100 échantillonnée toutes
    /// les 20 s : palier à ~3,14 A de 83 à ~94 % (le capteur sous-lit d'environ
    /// 1 % : la jauge donne 3184 mA de moyenne vraie), puis chute franche —
    /// 2748, 2464, 2026, 1583, 1171, 767 mA aux frontières de 95 à 100 %.
    /// Contrôle sur les temps réels : la table prédit 39,1 min pour le 83 → 100
    /// mesuré à 39,0, et 19,5 min depuis 94 % pour 19,7 mesurées.
    static let tableFloor = 83
    static let table: [Double] = [
        3180, 3180, 3180, 3180, 3180, 3180,    // 83-88 : second palier CC
        3180, 3180, 3180, 3180, 3180,          // 89-93
        2930, 2606, 2245, 1805, 1377, 969,     // 94-99 : taper CV a 4,44 V
    ]

    /// En dessous de ce courant, un pas de la somme cesse d'être crédible : la
    /// jauge elle-même s'arrête vers 100-250 mA en fin de charge. Le plancher
    /// évite qu'un zéro de table ou de capteur ne produise une division par rien
    /// — `Int(Double.infinity)` piège à l'exécution en Swift, ce ne serait pas
    /// une mauvaise estimation mais un plantage.
    static let currentFloor = 100.0

    /// Minutes pour aller de `level` (affiné par `trueRemaining` si disponible)
    /// jusqu'à `limit`, au courant mesuré `current` (mA, > 0).
    /// `capacity` est la référence pleine échelle en mAh (NominalChargeCapacity).
    /// `nil` si l'entrée ne permet aucune estimation honnête.
    static func minutes(level: Int, limit: Int, current: Double,
                        capacity: Double, trueRemaining: Double?) -> Int? {
        guard current > 0, capacity > 0, level < limit, limit <= 100 else { return nil }

        let stepCapacity = capacity / 100
        var totalHours = 0.0
        for step in level..<limit {
            // Premier pas au prorata : TRC est fin en charge (pas de 7-8 mAh),
            // autant ne compter que ce qui manque vraiment dans ce pourcent.
            // Borné à [0, pas] : TRC peut déjà déborder le pourcent affiché,
            // l'affichage du niveau étant quantifié et en retard.
            var stepmAh = stepCapacity
            if step == level, let trc = trueRemaining {
                stepmAh = min(max(Double(level + 1) / 100 * capacity - trc, 0), stepCapacity)
            }
            totalHours += stepmAh / max(predicted(step, measured: current), currentFloor)
        }

        let minutes = Int((totalHours * 60).rounded())
        // Plafond : au-delà de 24 h même un chargeur 5 W légitime a mieux à
        // afficher que des jours ; en dessous de 5 min l'arrondi à 5 garde un
        // affichage stable. La borne se juge sur la valeur ARRONDIE, celle qui
        // s'affiche — sinon 1439 min passerait la garde puis s'arrondirait à
        // 1440 et « 24 h » sortirait malgré elle.
        let rounded = max(5, (minutes + 2) / 5 * 5)
        guard rounded < 24 * 60 else { return nil }
        return rounded
    }

    /// Courant prédit au pourcent `step`, en mA.
    private static func predicted(_ step: Int, measured: Double) -> Double {
        let index = step - tableFloor
        guard index >= 0, index < table.count else { return measured }
        return min(measured, table[index])
    }
}
