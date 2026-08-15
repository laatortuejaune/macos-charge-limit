import Foundation
import IOKit
import IOKit.ps

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
//
// S'y ajoutent trois traits d'instrument, mesurés au banc (nuit du 15/08/2026),
// qui gouvernent la partie décharge :
//
// 3. `PowerTelemetryData` cesse de compter sous charge processeur soutenue —
//    9 relevés identiques sur 10 pendant un calcul à 6 fils. Le temps gelé est
//    précisément le temps cher : moyenner les seuls échantillons comptés rend
//    une autonomie OPTIMISTE après un pic, le pire sens d'erreur pour une jauge.
//    D'où la comparaison de l'avancement du compteur à une horloge murale.
// 4. `TrueRemainingCapacity` est fine en charge (7-8 mAh par relevé) mais
//    grossière en décharge : des sauts de 30 à 90 mAh, trois relevés sur onze.
//    Un delta n'a de sens qu'assez gros pour noyer cette quantification.
// 5. À chaque arrêt de charge, la jauge se RECALE : 57 à 90 mAh disparaissent en
//    30-45 s. Une fenêtre qui enjambe une transition d'alimentation est fausse
//    (mesuré : +52 % sur le débit). D'où la quarantaine autour des transitions.

/// Le seul sélecteur de `_PMLowPowerMode` qu'on utilise. L'écriture existe dans
/// la classe mais reste sans effet sans le droit adéquat, donc on ne la déclare pas.
@objc protocol LowPowerReader {
    func getPowerMode() -> Int
}

enum BatteryTime {

    /// Ligne d'état à afficher, ou `nil` si la machine n'a pas de batterie lisible.
    ///
    /// Tout est déduit d'un **unique instantané** : si l'utilisateur débranche
    /// pendant la lecture, l'affichage reste cohérent avec lui-même et c'est le
    /// rafraîchissement suivant qui montrera le changement.
    /// `snapshot` n'est fourni que par les bancs d'essai : il permet de rejouer
    /// les états qu'on ne peut pas provoquer à volonté (limite atteinte, charge
    /// suspendue, batterie au-dessus de la limite) sans attendre le bon moment.
    static func summary(limit: Int?, snapshot: [String: Any]? = nil) -> String? {
        guard let snapshot = snapshot ?? batterySnapshot(),
              flag(snapshot, "BatteryInstalled")
        else { return nil }

        track(snapshot)
        // Après la lecture, quel que soit le chemin de sortie : les estimateurs
        // ont vu les fenêtres telles qu'elles étaient au moment du relevé.
        defer { refreshAnchors(snapshot) }
        let level = integer(snapshot, "CurrentCapacity") ?? 0

        guard flag(snapshot, "ExternalConnected") else {
            negativeCurrentSince = nil
            // Piège mesuré : charge suspendue (SMC) avec le câble en place, le
            // système se déclare débranché — `ExternalConnected` ET
            // `AppleRawExternalConnected` tombent à zéro — mais l'adaptateur
            // reste énuméré dans `AdapterDetails` et continue de couvrir une
            // partie de la consommation, à raison variable : 1,9 A de drain
            // batterie pour un calcul qui en tire 3,3 sur batterie seule, et un
            // drain qui BAISSE quand le GPU s'y ajoute. La télémétrie mesure la
            // consommation du système : dans cet état elle ne dit plus rien du
            // drain batterie. Seuls la jauge elle-même et le compteur d'Apple
            // (assis sur le courant batterie) restent honnêtes.
            let adapterWatts = ((snapshot["AdapterDetails"] as? [String: Any])?["Watts"]
                as? NSNumber)?.intValue ?? 0

            // Quatre sources, par précision décroissante. La télémétrie (~1 %)
            // s'affiche telle quelle ; la médiane de courant (~15 %) et le
            // delta de jauge (~20 %) portent un tilde et un arrondi assorti —
            // afficher « 3 h 47 » depuis une source à 20 % près serait mentir
            // sur la précision.
            if adapterWatts == 0, let remaining = telemetryMinutesRemaining(snapshot) {
                return L("battery.remaining", format(remaining))
            }
            if let remaining = amperageMinutesRemaining(snapshot) {
                return L("battery.remaining", "~" + format(remaining))
            }
            if let remaining = gaugeMinutesRemaining(snapshot) {
                return L("battery.remaining", "~" + format(remaining))
            }
            guard let remaining = duration(snapshot, "TimeRemaining")
                    ?? duration(snapshot, "AvgTimeToEmpty")
            else { return L("battery.computing") }
            return L("battery.remaining", format(remaining))
        }

        if flag(snapshot, "FullyCharged") {
            // Sans cette remise à zéro, un courant négatif vu pendant une charge
            // précédente ressortirait des heures plus tard, à la reprise, comme
            // une accusation immédiate contre un chargeur sain.
            negativeCurrentSince = nil
            return L("battery.charged")
        }

        guard flag(snapshot, "IsCharging") else {
            negativeCurrentSince = nil
            // Branché sans charger : soit la limite est atteinte, soit la charge
            // est suspendue (chaleur, charge optimisée…). Pas de compte à rebours.
            // Le « −1 » est une hystérésis d'affichage : le maintien à la limite
            // oscille entre N−1 et N au gré des micro-cycles de recharge, et
            // alterner « En pause » / « Limite atteinte » à chaque cycle ferait
            // un menu nerveux pour un état de routine.
            if let limit, limit < 100, level >= limit - 1 {
                return L("battery.limitReached", limit)
            }
            return L("battery.paused")
        }

        // Même hystérésis en charge : la recharge d'entretien qui ramène N−1 à N
        // afficherait « ~5 min » pour un non-événement. La remise à zéro compte
        // aussi ici : un courant négatif vu pendant l'entretien survivrait sinon
        // à un relèvement de limite et accuserait le chargeur à la reprise.
        if let limit, limit < 100, level >= limit - 1 {
            negativeCurrentSince = nil
            return L("battery.limitReached", limit)
        }

        // Branché, annoncé « en charge », mais courant négatif ou nul. Deux cas
        // très différents se ressemblent ici :
        //  - l'adaptateur ne couvre pas la consommation et la batterie se vide
        //    (vu en vrai : chargeur tombé à 8 W, un autre appareil sur le port) ;
        //  - on vient de brancher, et `Amperage` — filtré, rafraîchi à la minute —
        //    traîne encore sous zéro pendant la montée en régime (mesuré sur une
        //    charge réelle : ~1 min entre le branchement et le plateau).
        // Accuser l'adaptateur pendant la montée serait faux et alarmant, donc le
        // verdict n'est rendu qu'après un délai de grâce. Et jamais tout près de
        // la limite : en fin de charge le courant peut légitimement croiser zéro,
        // accuser un chargeur sain à 1 % du but serait absurde.
        if let current = amperage(snapshot), current <= 0 {
            let since = negativeCurrentSince ?? Date()
            negativeCurrentSince = since
            let nearTarget = level >= (limit ?? 100) - 1
            if Date().timeIntervalSince(since) > rampGrace && !nearTarget {
                return L("battery.adapterTooWeak")
            }
            // À 1 % de la fin (donc limite 100 seulement : en dessous,
            // l'hystérésis a déjà répondu), le compteur d'Apple vaut mieux
            // qu'un « Calcul en cours » : c'était le comportement d'origine.
            if nearTarget, let toFull = duration(snapshot, "AvgTimeToFull") {
                return L("battery.untilFull", format(toFull))
            }
            return L("battery.computing")
        }
        negativeCurrentSince = nil

        // Une seule mécanique d'estimation, limite ou pas : le modèle calibré
        // (voir `ChargeModel`). `AvgTimeToFull` d'Apple ne reste qu'en repli du
        // seul cas 100 % — c'est une moyenne sur toute la courbe, mesurée ~40 %
        // trop courte en début de charge et fausse dans l'autre sens en fin.
        let target = min(limit ?? 100, 100)
        if let toTarget = minutesToLimit(snapshot, level: level, limit: target) {
            return target < 100 ? L("battery.untilLimit", format(toTarget), target)
                                : L("battery.untilFull", "~" + format(toTarget))
        }
        if target == 100, let toFull = duration(snapshot, "AvgTimeToFull") {
            return L("battery.untilFull", format(toFull))
        }
        return L("battery.computing")
    }

    /// Premier instant où un courant non positif a été vu pendant une charge.
    /// Non privé pour que le banc de cas puisse simuler un délai déjà écoulé.
    static var negativeCurrentSince: Date?
    /// `Amperage` met ~1 min à refléter la montée en régime après branchement.
    private static let rampGrace: TimeInterval = 90

    /// Le rappel du run loop est une fonction C : il ne capture rien, d'où ce
    /// stockage à part, ainsi que celui de la source qu'il faut garder en vie.
    private static var powerHandler: (() -> Void)?
    private static var powerSource: CFRunLoopSource?

    /// Prévient dès que l'alimentation change : branchement, débranchement,
    /// variation du niveau. Indispensable depuis que la barre affiche l'état de
    /// la batterie et non plus la limite — cette dernière ne bougeait qu'à la
    /// notification du démon, alors que le niveau change tout seul.
    static func observePowerChanges(_ handler: @escaping () -> Void) {
        powerHandler = handler
        guard powerSource == nil,
              let source = IOPSNotificationCreateRunLoopSource({ _ in
                  DispatchQueue.main.async { BatteryTime.powerHandler?() }
              }, nil)?.takeRetainedValue()
        else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private static var lowPowerHandler: (() -> Void)?

    /// Observe les changements de mode économie, d'où qu'ils viennent : le menu,
    /// les Réglages Système, ou une bascule automatique sur batterie faible.
    /// Sans ça la jauge resterait blanche alors que le mode est actif — vérifié.
    static func observeLowPowerChanges(_ handler: @escaping () -> Void) {
        lowPowerHandler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { BatteryTime.lowPowerHandler?() }
            },
            "com.apple.system.lowpowermode" as CFString, nil, .deliverImmediately)
    }

    /// Mode économie d'énergie, `nil` si illisible.
    ///
    /// Lecture seule, et ce n'est pas un oubli : `setPowerMode:fromSource:` ne
    /// fait rien depuis une app tierce — testé aussi depuis un bundle signé,
    /// l'appel n'est jamais rappelé et la valeur ne bouge pas. Réglages Système
    /// dispose d'un droit qu'aucune app tierce ne peut s'accorder, et passer root
    /// n'y change rien puisque c'est la signature de l'appelant qui est vérifiée.
    static func lowPowerMode() -> Bool? {
        guard dlopen("/System/Library/PrivateFrameworks/LowPowerMode.framework/LowPowerMode",
                     RTLD_NOW) != nil,
              let cls = NSClassFromString("_PMLowPowerMode") as? NSObject.Type,
              let object = (cls as AnyObject).perform(Selector(("sharedInstance")))?
                  .takeUnretainedValue() as? NSObject,
              object.responds(to: Selector(("getPowerMode")))
        else { return nil }
        return unsafeBitCast(object, to: LowPowerReader.self).getPowerMode() == 1
    }

    /// Niveau de charge et état, pour dessiner la jauge de la barre de menu.
    /// Nourrit aussi le traqueur : c'est l'appel qui a lieu à chaque variation
    /// de niveau, donc la cadence naturelle des fenêtres de mesure — sans lui,
    /// les ancres ne vivraient qu'aux ouvertures du menu et les fenêtres
    /// dureraient des heures.
    static func gauge() -> (level: Int, charging: Bool, plugged: Bool)? {
        guard let snapshot = batterySnapshot(), flag(snapshot, "BatteryInstalled"),
              let level = integer(snapshot, "CurrentCapacity")
        else { return nil }
        track(snapshot)
        refreshAnchors(snapshot)
        return (min(max(level, 0), 100),
                flag(snapshot, "IsCharging"),
                flag(snapshot, "ExternalConnected"))
    }

    // MARK: - Traqueur d'état

    /// L'état d'alimentation dont tout changement invalide les fenêtres de jauge.
    /// L'inhibition SMC n'y figure pas en propre : sa bascule fait tomber
    /// `IsCharging`, ce qui suffit à la voir d'ici sans dépendre du helper.
    /// L'adaptateur énuméré, si : charge suspendue câble en place, les deux
    /// drapeaux « connecté » mentent déjà (voir summary) — débrancher
    /// physiquement ne les fait pas bouger, alors que le régime de drain change
    /// du tout au tout (1,9 A adaptateur présent, 3,3 A sans). Seul
    /// `AdapterDetails` voit cette transition-là.
    private struct PowerKey: Equatable {
        let plugged: Bool
        let charging: Bool
        let wall: Bool
    }

    private static func powerKey(_ snapshot: [String: Any]) -> PowerKey {
        PowerKey(plugged: flag(snapshot, "ExternalConnected"),
                 charging: flag(snapshot, "IsCharging"),
                 wall: (((snapshot["AdapterDetails"] as? [String: Any])?["Watts"]
                     as? NSNumber)?.intValue ?? 0) > 0)
    }

    /// Horloges appariées. `uptime` (temps éveillé) s'arrête en veille, `wall`
    /// non : leur écart entre deux relevés trahit une veille traversée, qu'aucune
    /// fenêtre de jauge ne doit enjamber — la machine y draine à un régime sans
    /// rapport avec l'usage courant.
    private static func clocks() -> (wall: Date, uptime: TimeInterval) {
        (Date(), ProcessInfo.processInfo.systemUptime)
    }

    private static var lastKey: PowerKey?
    private static var lastSample: (wall: Date, uptime: TimeInterval)?
    /// Instant (éveillé) de la dernière transition d'alimentation, pour la
    /// quarantaine : la jauge se recale pendant 30-45 s après chaque transition,
    /// aucune ancre n'est posée dans la minute qui suit.
    private static var lastTransitionUptime: TimeInterval?
    private static let transitionQuarantine: TimeInterval = 60

    /// Ancre de la moyenne télémétrique. Elle survit aux transitions et à la
    /// veille : le compteur mesure la charge système, pas la batterie, et son
    /// horloge s'arrête en veille en même temps que la nôtre.
    private static var telemetryAnchor: (accumulated: Int64, samples: Int64,
                                         uptime: TimeInterval)?

    /// Ancre du débit par delta de jauge. Fragile, elle : recalages de jauge aux
    /// transitions, drain de veille — d'où la clé d'état embarquée, la
    /// quarantaine à la pose, et l'invalidation à la moindre anomalie.
    private static var gaugeAnchor: (trc: Double, uptime: TimeInterval, key: PowerKey)?

    /// Derniers relevés du capteur de courant, sur batterie. Le capteur se
    /// republie environ une fois par minute ; trois relevés en donnent une
    /// médiane exploitable bien avant que la fenêtre de jauge ait accumulé ses
    /// 450 mAh — mesuré sur une journée réelle : sous charge soutenue, la série
    /// est serrée (±5 %) et s'écarte de la jauge de 9 à 18 %.
    private static var amperageSamples: [(uptime: TimeInterval, mA: Int)] = []

    /// Dernier TRC vu, pour attraper les recalages : sur batterie la jauge ne
    /// peut pas monter, donc toute remontée est un recalage (mesuré : +10 à
    /// +73 mAh au relâchement d'une charge), et la fenêtre qui l'enjambe serait
    /// optimiste d'autant.
    private static var lastTrc: Double?

    /// À appeler au démarrage : pose les ancres pour que la toute première
    /// ouverture du menu dispose déjà d'une fenêtre exploitable, et arme le pas
    /// de relevé.
    ///
    /// LE PAS DE 30 S N'EST PAS UN LUXE. Sans lui, menu fermé, les relevés ne
    /// viennent qu'aux notifications d'alimentation — au pire un par pourcent,
    /// ~93 mAh d'intervalle. Or le détecteur de recalage compare deux relevés
    /// CONSÉCUTIFS : un recalage de +73 mAh noyé dans un intervalle qui en
    /// décharge 93 passe inaperçu, et la fenêtre de jauge reste faussée. À
    /// 30 s d'intervalle, la décharge entre deux relevés vaut au plus ~25 mAh
    /// (à 3 A) : tous les recalages mesurés (+41, +73) ressortent. Le pas
    /// nourrit aussi le ring de courant et recentre les ancres. Coût : une
    /// lecture IORegistry toutes les 30 s, la même que fait déjà chaque
    /// notification — invisible au moniteur d'activité, avec dix secondes de
    /// tolérance pour que le système regroupe les réveils.
    static func primeAverage() {
        guard let snapshot = batterySnapshot() else { return }
        track(snapshot)
        refreshAnchors(snapshot)

        guard sampler == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(10))
        timer.setEventHandler {
            guard let snapshot = batterySnapshot() else { return }
            track(snapshot)
            refreshAnchors(snapshot)
        }
        timer.resume()
        sampler = timer
    }

    private static var sampler: DispatchSourceTimer?

    /// Entretien des ancres, à chaque lecture d'instantané, en deux temps
    /// stricts : `track` invalide AVANT que les estimateurs lisent (une fenêtre
    /// qui enjambe une veille ou une transition ne doit jamais produire de
    /// chiffre), `refreshAnchors` pose et recentre APRÈS (un recentrage qui
    /// précéderait la lecture détruirait la fenêtre à l'instant précis où on
    /// allait s'en servir).
    private static func track(_ snapshot: [String: Any]) {
        let now = clocks()
        let key = powerKey(snapshot)

        // Veille traversée depuis le dernier relevé : le temps mur a couru, pas
        // le temps éveillé. Les fenêtres de jauge sont mortes ; la télémétrique
        // survit (ses échantillons se sont arrêtés avec l'horloge éveillée).
        // La quarantaine s'applique aussi au réveil : une transition de charge a
        // pu se produire pendant la veille, invisible d'ici, recalage compris.
        if let last = lastSample,
           now.wall.timeIntervalSince(last.wall) - (now.uptime - last.uptime) > 60 {
            gaugeAnchor = nil
            // L'horloge éveillée s'est arrêtée avec la machine : l'âge des
            // relevés de courant ne les éliminerait pas, alors qu'ils décrivent
            // le régime d'avant la veille.
            amperageSamples.removeAll()
            lastTransitionUptime = now.uptime
        }
        lastSample = now

        if key != lastKey {
            gaugeAnchor = nil
            // Le capteur de courant traîne environ une minute derrière une
            // transition : des relevés pris avant elle décriraient l'ancien
            // régime avec l'assurance du nouveau.
            amperageSamples.removeAll()
            // Au tout premier relevé aussi : l'app a pu être lancée dans les
            // secondes qui suivent un débranchement, en plein recalage — une
            // transition qui précède le lancement reste une transition.
            lastTransitionUptime = now.uptime
            lastKey = key
        }

        if let trc = trueRemaining(snapshot) {
            // Recalage montant : sur batterie, une jauge qui remonte n'a pas
            // gagné d'énergie, elle s'est recalée (mesuré : +73 mAh au passage
            // de 100 % à 67 % de charge processeur). La fenêtre en cours est
            // fausse ; le capteur de courant, lui, n'est pas concerné.
            if let last = lastTrc, !key.plugged, trc > last + 4 {
                gaugeAnchor = nil
                lastTransitionUptime = now.uptime
            }
            lastTrc = trc
        }

        // Alimentation du capteur de courant : décharge uniquement, hors
        // quarantaine (le capteur traîne ~1 min derrière une transition — une
        // valeur de rampe qui entrerait dans la fenêtre pèserait sur la médiane
        // pendant cinq minutes), et sans doublonner : le capteur se republie
        // environ une fois par minute, donc une valeur IDENTIQUE revue avant
        // 70 s est très probablement la même publication — la reprendre
        // laisserait la cadence d'ouverture du menu pondérer la médiane, et
        // ferait passer un capteur mort pour éternellement frais. Une valeur
        // différente, elle, est forcément une publication neuve.
        if !key.plugged, let current = amperage(snapshot), current < 0,
           lastTransitionUptime.map({ now.uptime - $0 >= sensorSettle }) ?? true {
            if amperageSamples.last.map({ now.uptime - $0.uptime >= 70 || $0.mA != current })
                ?? true {
                amperageSamples.append((now.uptime, current))
            }
            amperageSamples.removeAll { now.uptime - $0.uptime > 6 * 60 }
            if amperageSamples.count > 8 { amperageSamples.removeFirst() }
        }
    }

    /// Traîne du capteur de courant après une transition d'alimentation,
    /// mesurée à ~1 min (c'est la grâce de `rampGrace` côté charge) — plus une
    /// marge : aucun relevé n'entre dans le ring avant ce délai.
    private static let sensorSettle: TimeInterval = 75

    private static func refreshAnchors(_ snapshot: [String: Any]) {
        let now = clocks()

        // Pose de l'ancre télémétrique dès que possible ; recentrage au-delà de
        // vingt minutes. Sans lui, l'ancre vieillirait sans borne pendant les
        // périodes branchées (le recentrage de consultation ne vit que dans la
        // branche débranchée) et le premier chiffre après un débranchement
        // moyennerait des heures d'usage secteur.
        if let telemetry = snapshot["PowerTelemetryData"] as? [String: Any],
           let accumulated = signed(telemetry, "AccumulatedSystemLoad"),
           let samples = signed(telemetry, "SystemLoadAccumulatorCount"),
           telemetryAnchor.map({ now.uptime - $0.uptime >= 20 * 60 }) ?? true {
            telemetryAnchor = (accumulated, samples, now.uptime)
        }

        // Pose de l'ancre de jauge : sur batterie uniquement (c'est l'autonomie
        // qu'elle sert), et jamais en quarantaine — l'ancre posée pendant le
        // recalage embarquerait jusqu'à 90 mAh fantômes dans toutes ses fenêtres.
        // Recentrage au-delà de trente minutes : cette source n'est consultée
        // que quand la télémétrie gèle, c'est-à-dire longtemps après la pose —
        // une fenêtre d'heures mélangerait des usages sans rapport avec la
        // charge en cours.
        if lastKey?.plugged == false,
           lastTransitionUptime.map({ now.uptime - $0 >= transitionQuarantine }) ?? true,
           gaugeAnchor.map({ now.uptime - $0.uptime >= 30 * 60 }) ?? true,
           let trc = trueRemaining(snapshot), let key = lastKey {
            gaugeAnchor = (trc, now.uptime, key)
        }
    }

    // MARK: - Autonomie, source télémétrique

    /// Autonomie calculée sur la consommation *moyenne*, pas instantanée.
    ///
    /// `TimeRemaining` suit la charge de l'instant : mesuré sur une soirée, il a
    /// varié d'un facteur 70 (106 min à 7427 min) avec 83 minutes d'écart moyen
    /// entre deux relevés espacés de 45 s. Inutilisable tel quel — c'est d'ailleurs
    /// pour ça que `pmset` refuse d'afficher une estimation sur cette machine.
    ///
    /// `PowerTelemetryData` expose un accumulateur de consommation et son nombre
    /// d'échantillons, à ~0,96 Hz. La différence entre deux relevés donne donc la
    /// consommation moyenne sur l'intervalle exact qui les sépare, sans rien
    /// échantillonner soi-même : mesuré sur 180 s, 3427 mW contre 3473 mW pour la
    /// vraie moyenne des instantanés, soit 1,3 % d'écart.
    ///
    /// LE PIÈGE : le compteur gèle sous charge soutenue, et les secondes gelées
    /// sont les plus chères. On exige donc que l'avancement du compteur suive le
    /// temps éveillé à 95 % au moins ; sinon la fenêtre est jetée ET l'ancre
    /// reposée — sans quoi le tronçon gelé contaminerait toutes les fenêtres
    /// suivantes, et l'autonomie resterait optimiste longtemps après le pic.
    private static func telemetryMinutesRemaining(_ snapshot: [String: Any]) -> Int? {
        guard let telemetry = snapshot["PowerTelemetryData"] as? [String: Any],
              let accumulated = signed(telemetry, "AccumulatedSystemLoad"),
              let samples = signed(telemetry, "SystemLoadAccumulatorCount"),
              let anchor = telemetryAnchor
        else { return nil }

        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsedSeconds = uptime - anchor.uptime
        let elapsed = samples - anchor.samples
        let consumed = accumulated - anchor.accumulated

        // Compteurs repartis de zéro (redémarrage, batterie réinitialisée) :
        // on repose l'ancre plutôt que de produire un chiffre absurde.
        guard elapsed >= 0, consumed >= 0 else {
            telemetryAnchor = (accumulated, samples, uptime)
            return nil
        }
        // Le compteur tourne à ~0,96 Hz, pas 1 Hz : exiger 60 échantillons
        // reviendrait à exiger 63 secondes, et une ouverture de menu à la minute
        // passerait systématiquement juste en dessous. Trente échantillons — une
        // demi-minute — suffisent déjà à lisser les à-coups d'une seconde.
        // Les 32 secondes disent la même chose sur l'autre horloge (30/0,96) et
        // donnent au test de gel ci-dessous un dénominateur non trivial.
        guard elapsed >= 30, elapsedSeconds >= 32 else { return nil }

        // Détection de gel. Une fenêtre saine avance à 98-100 % du rythme
        // nominal ; gelée sous charge, à ~10 %. Le seuil à 95 % borne le biais
        // résiduel : au pire 5 % de temps caché, soit une poignée de pourcents
        // d'optimisme, contre un facteur 2 sans le test.
        guard Double(elapsed) >= 0.95 * 0.96 * elapsedSeconds else {
            telemetryAnchor = (accumulated, samples, uptime)
            return nil
        }

        let averagePower = Double(consumed) / Double(elapsed)
        guard averagePower > 0, let energy = remainingEnergy(snapshot) else { return nil }

        let minutes = Int((energy / averagePower * 60).rounded())
        guard minutes > 0, minutes < 48 * 60 else { return nil }

        // L'ancre ne se recentre qu'au-delà de dix minutes. La déplacer à chaque
        // usage rendait la fenêtre suivante trop courte pour être exploitable, et
        // l'affichage alternait entre valeur lissée et valeur brute.
        if elapsedSeconds >= 600 { telemetryAnchor = (accumulated, samples, uptime) }
        return minutes
    }

    /// Énergie restante en mWh. `TrueRemainingCapacity` d'abord ; à défaut, le
    /// pourcentage affiché sur l'échelle nominale — grossier mais sain, pour que
    /// l'absence d'une clé ne mure pas toute l'estimation.
    private static func remainingEnergy(_ snapshot: [String: Any]) -> Double? {
        guard let voltage = (snapshot["Voltage"] as? NSNumber)?.doubleValue, voltage > 0
        else { return nil }
        let capacity = trueRemaining(snapshot)
            ?? (integer(snapshot, "CurrentCapacity").flatMap { level in
                fullScale(snapshot).map { Double(level) / 100 * $0 }
            })
        guard let capacity, capacity > 0 else { return nil }
        return capacity * voltage / 1000
    }

    // MARK: - Autonomie, source courant

    /// Étage intermédiaire : la médiane des derniers relevés du capteur de
    /// courant. Moins précise que la télémétrie (~15 % contre ~1 %), mais
    /// disponible une à deux minutes après un changement de régime, là où la
    /// fenêtre de jauge doit d'abord accumuler ses 450 mAh — et elle lit la
    /// batterie elle-même, donc elle reste valide charge suspendue câble en
    /// place, où la télémétrie ne dit rien du drain réel.
    ///
    /// Sous ~300 mA on s'abstient : à vide le capteur saute d'un facteur cinq
    /// d'un relevé à l'autre (mesuré : −9 à −49 mA au repos), et c'est
    /// précisément le régime où la télémétrie, elle, fonctionne.
    private static func amperageMinutesRemaining(_ snapshot: [String: Any]) -> Int? {
        let now = ProcessInfo.processInfo.systemUptime
        let recent = amperageSamples.filter { now - $0.uptime <= 5 * 60 }
        guard recent.count >= 3,
              let first = recent.first, let last = recent.last,
              last.uptime - first.uptime >= 90,
              let trc = trueRemaining(snapshot)
        else { return nil }

        let drains = recent.map { Double(-$0.mA) }.sorted()
        // Médiane vraie : sur un effectif pair, prendre l'élément haut de la
        // paire centrale biaiserait systématiquement vers le drain fort.
        let count = drains.count
        let median = count.isMultiple(of: 2)
            ? (drains[count / 2 - 1] + drains[count / 2]) / 2
            : drains[count / 2]
        guard median >= 300, median <= 8000 else { return nil }

        let minutes = Int((trc / median * 60).rounded())
        guard minutes > 0, minutes < 48 * 60 else { return nil }
        // Arrondi à dix minutes : la précision affichée est celle du capteur.
        // Sauf en toute fin de batterie : plaquer 4 minutes réelles sur
        // « ~10 min » serait optimiste d'un facteur 2,5 au moment précis où ça
        // coûte le plus — sous 8 minutes, le pas descend à 5.
        guard minutes >= 8 else { return max(5, (minutes + 2) / 5 * 5) }
        return max(10, (minutes + 4) / 10 * 10)
    }

    // MARK: - Autonomie, source jauge

    /// Repli quand la télémétrie gèle : le débit tiré du delta de
    /// `TrueRemainingCapacity`. En décharge la jauge saute par 30-90 mAh, donc
    /// l'erreur de quantification vaut jusqu'à un saut à chaque bout de fenêtre :
    /// exiger un delta d'au moins 450 mAh la borne à ~20 %. Le delta seul fait
    /// la précision — une durée minimale ne s'y substitue pas, elle évite juste
    /// qu'une grappe de sauts simule un débit.
    ///
    /// Complémentarité voulue avec la télémétrie : elle gèle sous FORTE charge,
    /// là où le drain est gros et où 450 mAh s'accumulent en huit à dix minutes.
    /// Au repos, où ce delta mettrait des heures, la télémétrie ne gèle pas.
    private static func gaugeMinutesRemaining(_ snapshot: [String: Any]) -> Int? {
        guard let anchor = gaugeAnchor, let trc = trueRemaining(snapshot),
              anchor.key == lastKey
        else { return nil }

        let uptime = ProcessInfo.processInfo.systemUptime
        let elapsedHours = (uptime - anchor.uptime) / 3600
        let delta = anchor.trc - trc
        guard uptime - anchor.uptime >= 8 * 60, delta >= 450 else { return nil }

        let drain = delta / elapsedHours
        // Hors de toute plausibilité physique pour cette machine : fenêtre
        // corrompue (recalage passé inaperçu ?), on repart de zéro.
        guard (200...8000).contains(drain) else {
            gaugeAnchor = nil
            return nil
        }

        let minutes = Int((trc / drain * 60).rounded())
        guard minutes > 0, minutes < 48 * 60 else { return nil }

        // Recentrage au-delà de trente minutes, pour que la fenêtre reste le
        // reflet de l'usage en cours et non de toute la matinée.
        if uptime - anchor.uptime >= 30 * 60 { gaugeAnchor = (trc, uptime, anchor.key) }
        // Arrondi au quart d'heure : la précision affichée doit être celle qu'on a.
        return max(15, (minutes + 7) / 15 * 15)
    }

    // MARK: - Estimation jusqu'à la limite

    /// Le courant mesuré sert de régime de croisière ; la table calibrée de
    /// `ChargeModel` impose le ralentissement au-dessus du coude. Voir ce fichier
    /// pour le modèle et son domaine de validité.
    private static func minutesToLimit(_ snapshot: [String: Any],
                                       level: Int, limit: Int) -> Int? {
        guard let current = amperage(snapshot), current > 0,
              let capacity = fullScale(snapshot)
        else { return nil }
        return ChargeModel.minutes(level: level, limit: limit,
                                   current: Double(current), capacity: capacity,
                                   trueRemaining: trueRemaining(snapshot))
    }

    // MARK: - Lecture brute

    /// Non privé : le journal d'usage (`UsageLog`) lit le même instantané —
    /// dupliquer la lecture IORegistry ferait diverger deux copies du même code.
    static func batterySnapshot() -> [String: Any]? {
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

    /// Pleine échelle réelle de la jauge, en mAh. C'est `NominalChargeCapacity`
    /// que suit `TrueRemainingCapacity` — vérifié : 7460 mAh à 80 %, soit 9325
    /// extrapolé, contre 9313 nominal et 9516 de conception. L'app utilisait
    /// `DesignCapacity` : ~2 % d'écart aujourd'hui, et l'écart ne fait que
    /// croître avec l'usure puisque la conception, elle, ne vieillit pas.
    private static func fullScale(_ snapshot: [String: Any]) -> Double? {
        guard let battery = snapshot["BatteryData"] as? [String: Any] else { return nil }
        for key in ["NominalChargeCapacity", "FullChargeCapacity", "DesignCapacity"] {
            if let value = (battery[key] as? NSNumber)?.doubleValue, value > 0 {
                return value
            }
        }
        return nil
    }

    private static func trueRemaining(_ snapshot: [String: Any]) -> Double? {
        guard let battery = snapshot["BatteryData"] as? [String: Any],
              let value = (battery["TrueRemainingCapacity"] as? NSNumber)?.doubleValue,
              value > 0
        else { return nil }
        return value
    }

    private static func integer(_ snapshot: [String: Any], _ key: String) -> Int? {
        (snapshot[key] as? NSNumber)?.intValue
    }

    /// Ces clés sont des entiers 0/1 dans l'IORegistry, pas des booléens
    /// CoreFoundation — `as? Bool` marcherait par accident et masquerait le reste.
    private static func flag(_ snapshot: [String: Any], _ key: String) -> Bool {
        (integer(snapshot, key) ?? 0) != 0
    }

    /// Ces compteurs sont stockés non signés : il faut réinterpréter les bits pour
    /// retrouver le signe, sans quoi une décharge devient un nombre astronomique.
    private static func signed(_ snapshot: [String: Any], _ key: String) -> Int64? {
        guard let raw = (snapshot[key] as? NSNumber)?.uint64Value else { return nil }
        return Int64(bitPattern: raw)
    }

    private static func amperage(_ snapshot: [String: Any]) -> Int? {
        signed(snapshot, "Amperage").map(Int.init)
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
