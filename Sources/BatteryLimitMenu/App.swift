import AppKit
import ServiceManagement

@main
enum Main {
    // `NSApplication.delegate` est une référence faible : ce `static let` est ce
    // qui maintient le délégué en vie. Sans point d'entrée explicite, `@main` posé
    // directement sur le délégué démarre la boucle sans jamais l'assigner —
    // l'app tourne alors, muette, sans icône.
    private static let delegate = AppDelegate()

    static func main() {
        // Sans ça, deux lancements donnent deux icônes identiques dans la barre.
        // La copie déjà en place gagne ; c'est la nouvelle qui se retire.
        if isAlreadyRunning() { return }

        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private static func isAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        // On compare les PID plutôt que de compter : à ce stade `NSApplication`
        // n'existe pas encore, donc le processus courant n'est pas toujours
        // inscrit dans la liste. Compter les autres est vrai dans les deux cas.
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != mine }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Sans nom de sauvegarde, la position choisie par l'utilisateur — en
        // cmd-glissant l'icône — serait oubliée à chaque lancement.
        statusItem.autosaveName = "BatteryLimit"
        statusItem.button?.imagePosition = .imageOnly

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refreshTitle()

        // Pose l'ancre de la moyenne de consommation : sans ça, la première
        // ouverture du menu n'aurait pas de fenêtre et retomberait sur la valeur
        // brute d'Apple, bien plus instable.
        BatteryTime.primeAverage()

        // Resynchronisation quand la limite change ailleurs (Réglages Système,
        // Raccourcis). Le démon poste la notification quelle qu'en soit l'origine.
        ChargeLimit.observeChanges { [weak self] in self?.refreshTitle() }

        // La jauge suit l'état de la batterie, qui change sans prévenir : sans
        // cet observateur elle resterait figée jusqu'à la prochaine ouverture
        // du menu.
        BatteryTime.observePowerChanges { [weak self] in self?.refreshTitle() }

        // Le mode économie teinte la jauge en jaune : il peut changer depuis les
        // Réglages ou tout seul en batterie faible, pas seulement depuis ce menu.
        BatteryTime.observeLowPowerChanges { [weak self] in self?.refreshTitle() }

        // L'image du mode économie n'est plus *template* : le système ne la
        // reteinte pas, c'est nous qui résolvons la couleur du tracé. Or au
        // moment du premier rendu le bouton n'a pas encore rejoint la barre et
        // répond « clair » même sous une barre sombre — la jauge sortirait noire
        // sur fond noir. Un délai fixe serait un pari ; observer l'apparence
        // couvre à la fois cette stabilisation et les bascules clair/sombre.
        //
        // Le filtre sur le NOM n'est pas une optimisation, c'est ce qui empêche
        // une boucle : redessiner pose une image sur le bouton, ce qui fait
        // réévaluer son apparence, ce qui redéclenche cet observateur. Sans
        // garde, l'app tournait en continu — mesuré à 64 % de processeur au
        // repos, sur un agent de barre de menu censé ne rien faire. Le nom, lui,
        // ne change qu'à une vraie bascule clair/sombre.
        // Le thème clair/sombre, sans KVO.
        //
        // L'app observait `effectiveAppearance` sur le bouton. Mesuré : ce KVO se
        // déclenche 728 fois PAR SECONDE sur un bouton de barre de menu, et coûte
        // 63 % de processeur — pas à cause du travail fait dans le gestionnaire,
        // qui était déjà filtré, mais de la machinerie KVO traversée à chaque
        // fois. Un agent de barre de menu qui brûle un demi-cœur au repos vide la
        // batterie qu'il est censé ménager.
        //
        // La notification distribuée ne part qu'à un vrai basculement de thème.
        DistributedNotificationCenter.default.addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main) { [weak self] _ in self?.refreshTitle() }

        // Reste le cas du tout premier rendu : à la création du status item, le
        // bouton n'a pas encore rejoint la barre et répond « clair » même sous une
        // barre sombre. Un second passage au tour de boucle suivant suffit — ce
        // n'est pas un délai deviné, c'est l'instant où AppKit a fini de poser la
        // hiérarchie.
        DispatchQueue.main.async { [weak self] in self?.refreshTitle() }

        // `disablesleep` survit à l'app : s'il traîne d'un lancement qui s'est mal
        // terminé, on le reprend en main plutôt que de l'ignorer. Sinon le menu
        // afficherait une case décochée devant un Mac qui ne dort plus.
        SleepGuard.adoptSystemState()

        // Même logique pour la suspension de charge, avec un enjeu plus lourd :
        // laissée derrière, elle vide la batterie au lieu de simplement empêcher
        // la veille. On relâche donc si le niveau est déjà sous le plancher.
        ChargeInhibit.enforceFloor()
    }

    /// Dernier filet. Les assertions se relâchent seules à la mort du processus,
    /// mais pas `disablesleep`, qui est un réglage système et survivrait même à un
    /// redémarrage — un portable qui ne dort plus jamais, sans rien à l'écran pour
    /// l'expliquer. Quitter proprement le repose donc à zéro.
    func applicationWillTerminate(_ notification: Notification) {
        // Ferme le fichier du journal d'usage proprement — la mort du processus
        // le fermerait aussi, mais autant que la dernière ligne soit entière.
        UsageLog.stop()
        SleepGuard.releaseAll()
        // Celle-ci mourrait seule avec le processus ; la relâcher explicitement
        // la fait disparaître de `pmset -g assertions` tout de suite plutôt qu'à
        // la faveur du ramassage, ce qui rend le diagnostic honnête.
        DisplayGuard.release()
        // Celle-ci survivrait au processus, comme `disablesleep`, mais sa
        // conséquence est pire : un Mac branché qui ne se recharge plus.
        ChargeInhibit.releaseAll()
    }

    // MARK: - Barre de menu

    /// La barre n'affiche que la jauge, comme celle de macOS : pas de texte, pour
    /// que remplacer l'icône du système ne rallonge pas la barre de menu.
    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        button.title = ""

        guard let gauge = BatteryTime.gauge() else {
            button.image = BatteryGauge.image(level: 0, charging: false)
            button.toolTip = L("status.tooltip.unavailable")
            return
        }
        // Vérifié à chaque rafraîchissement et avant de dessiner : la batterie
        // passe le plancher pendant que l'app tourne, pas avant, et l'icône ne
        // doit pas montrer un état qu'on vient d'annuler.
        ChargeInhibit.enforceFloor()

        let limit = ChargeLimit.current()
        button.image = BatteryGauge.image(level: gauge.level,
                                          charging: gauge.charging || willCharge(gauge, limit),
                                          plugged: gauge.plugged,
                                          lowPower: BatteryTime.lowPowerMode() == true,
                                          appearance: button.effectiveAppearance)

        var tip: String
        if let limit {
            tip = L("status.tooltip.full", gauge.level, limit)
        } else {
            tip = L("status.tooltip", gauge.level)
        }
        // Sur une deuxième ligne : c'est le seul endroit où l'état de la veille se
        // lit sans ouvrir le menu, la barre restant volontairement limitée à la
        // jauge pour ne pas s'allonger.
        if SleepGuard.isActive { tip += "\n" + L("sleep.tooltipActive") }
        button.toolTip = tip
    }

    /// La charge ne démarre pas à l'instant où l'on branche : mesuré sur trois
    /// cycles, elle a mis 36, 45 et 62 secondes. Pendant tout ce temps le système
    /// rapporte « branché, pas en charge », et l'icône affichait donc une prise
    /// avant de basculer sur l'éclair — un changement qui ressemble à une
    /// hésitation alors que rien n'a changé côté machine.
    ///
    /// Or l'issue est connue d'avance : sous la limite le Mac va charger, au-dessus
    /// il ne chargera pas. Autant l'afficher tout de suite. C'est un pari, mais un
    /// pari sur une règle que l'app connaît — et il se corrige seul au
    /// rafraîchissement suivant s'il se trouvait faux, par exemple sur un
    /// chargeur trop faible.
    ///
    /// Sans limite lisible on ne parie sur rien : l'icône reste le reflet exact
    /// de ce que dit le système.
    /// La suspension de charge annule le pari : elle empêche la charge quel que
    /// soit le niveau, donc parier sur l'éclair afficherait un mensonge durable
    /// au lieu d'une avance de quelques secondes.
    private func willCharge(_ gauge: (level: Int, charging: Bool, plugged: Bool),
                            _ limit: Int?) -> Bool {
        guard gauge.plugged, !gauge.charging, let limit else { return false }
        guard ChargeInhibit.isActive() != true else { return false }
        return gauge.level < limit
    }

    // MARK: - Menu

    /// Reconstruit le menu à chaque ouverture : l'état affiché est relu au moment
    /// où tu le regardes, même si une notification avait été manquée.
    ///
    /// Trois rangées, pas plus. La ligne d'état, les paliers, puis une rangée
    /// d'icônes — le détail (source d'alimentation, couverture de la veille,
    /// mode économie…) vit dans les infobulles, au survol. Le menu est passé de
    /// onze lignes de texte à ça quand chaque feature a cessé d'ajouter la sienne.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let gauge = BatteryTime.gauge()
        let current = ChargeLimit.isSupported ? ChargeLimit.current() : nil

        // Les paliers d'abord : c'est eux qui fixent la largeur du menu, dont la
        // ligne d'état et la rangée d'icônes ont besoin pour se caler.
        let limits = ChargeLimit.isSupported
            ? limitsItem(current: current, limits: ChargeLimit.availableLimits())
            : header(L("menu.unsupported"))
        menu.addItem(statusRow(gauge: gauge, limit: current))
        menu.addItem(limits)
        menu.addItem(.separator())
        menu.addItem(iconStrip())

        // La rangée d'icônes a englouti « Quitter », mais ⌘Q doit continuer de
        // marcher menu ouvert : un item invisible porte le raccourci.
        let quit = NSMenuItem(title: L("icon.quit"),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.isHidden = true
        quit.allowsKeyEquivalentWhenHidden = true
        menu.addItem(quit)

        refreshTitle()
    }

    /// « Batterie » à gauche ; niveau et état de charge à droite. Le reste —
    /// source d'alimentation, limite — est dans l'infobulle.
    private func statusRow(gauge: (level: Int, charging: Bool, plugged: Bool)?,
                           limit: Int?) -> NSMenuItem {
        var right = gauge.map { L("menu.level", $0.level) } ?? "—"
        if let summary = BatteryTime.summary(limit: limit) {
            right += "  ·  " + summary
        }
        let item = titleRow(L("panel.title"), right)

        if let gauge {
            var lines = [L("panel.source", L(gauge.plugged ? "panel.source.adapter"
                                                           : "panel.source.battery"))]
            if let limit { lines.append(L("tooltip.limit", limit)) }
            item.toolTip = lines.joined(separator: "\n")
        }
        return item
    }

    /// Les paliers sur une seule ligne, dans un contrôle segmenté. Un `NSMenuItem`
    /// porteur d'une vue ne reçoit pas le surlignage habituel des menus, ce qui
    /// tombe bien : il se lit comme un contrôle et non comme une liste d'actions.
    private func limitsItem(current: Int?, limits: [Int]) -> NSMenuItem {
        let control = NSSegmentedControl(labels: limits.map { L("menu.level", $0) },
                                         trackingMode: .selectOne,
                                         target: self,
                                         action: #selector(selectLimit(_:)))
        control.segmentDistribution = .fillEqually
        control.selectedSegment = -1
        for (index, limit) in limits.enumerated() {
            control.setTag(limit, forSegment: index)
            control.setToolTip(limit >= 100 ? L("menu.noLimitHint") : L("menu.limitHint", limit),
                               forSegment: index)
            if limit == current { control.selectedSegment = index }
        }
        control.sizeToFit()

        // Marges alignées sur celles d'un titre de menu ordinaire.
        let horizontal: CGFloat = 14, vertical: CGFloat = 5
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: control.frame.width + horizontal * 2,
                                             height: control.frame.height + vertical * 2))
        stripWidth = container.frame.width
        control.setFrameOrigin(NSPoint(x: horizontal, y: vertical))
        container.addSubview(control)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    @objc private func selectLimit(_ sender: NSSegmentedControl) {
        let limit = sender.tag(forSegment: sender.selectedSegment)
        // Une vue dans un menu ne le referme pas d'elle-même.
        sender.enclosingMenuItem?.menu?.cancelTracking()

        if case .failure(let error) = ChargeLimit.set(limit) {
            warn(L("error.setFailed", limit), error.localizedDescription)
        }
        // Le démon poste la notification, mais on rafraîchit tout de suite pour
        // que l'affichage ne dépende pas de son délai.
        refreshTitle()
    }

    // MARK: - Rangée d'icônes

    /// Veille, écran allumé, mode économie, charge suspendue, journal d'usage,
    /// lancement à l'ouverture, réglages, quitter : une rangée d'icônes (le
    /// mode économie et la suspension n'apparaissent que si la machine les
    /// permet). L'état se lit à la teinte (accentuée = actif), le détail à
    /// l'infobulle. Les glyphes sont choisis pour se passer de légende : lune,
    /// soleil, feuille, éclair barré, cercle d'enregistrement, app cochée,
    /// engrenage, croix.
    ///
    /// Lune et soleil se suivent parce qu'ils forment une paire : l'une empêche
    /// la machine de dormir, l'autre empêche l'écran de s'éteindre, et ce sont
    /// deux réglages distincts que macOS traite séparément.
    private func iconStrip() -> NSMenuItem {
        let sleepActive = SleepGuard.isActive
        let displayActive = DisplayGuard.isActive
        let lowPower = BatteryTime.lowPowerMode()
        let loginOn = SMAppService.mainApp.status == .enabled

        let buttons = [
            iconButton(symbol: sleepActive ? "moon.fill" : "moon",
                       active: sleepActive,
                       tooltip: sleepTooltip(active: sleepActive),
                       action: #selector(toggleSleepGuard)),
            iconButton(symbol: displayActive ? "sun.max.fill" : "sun.max",
                       active: displayActive,
                       tooltip: displayTooltip(active: displayActive),
                       action: #selector(toggleDisplayGuard)),
            lowPower.map { on in
                // Cliquable pour de vrai si la règle sudoers est là ; sinon on se
                // rabat sur l'ouverture des Réglages, comme la couverture du capot.
                let canToggle = LowPower.canToggle()
                let state = L(on ? "panel.on" : "panel.off")
                return iconButton(
                    symbol: on ? "leaf.fill" : "leaf",
                    active: on,
                    tooltip: L(canToggle ? "icon.lowpower.toggle" : "icon.lowpower", state),
                    action: canToggle ? #selector(toggleLowPower) : #selector(openBatterySettings))
            } ?? nil,
            // Absent des machines dont le SMC n'expose pas la clé : mieux vaut
            // pas de bouton qu'un bouton qui ne fait rien.
            ChargeInhibit.isSupported ? {
                let held = ChargeInhibit.isActive() == true
                let canToggle = ChargeInhibit.canToggle()
                return iconButton(
                    symbol: held ? "bolt.slash.fill" : "bolt.slash",
                    active: held,
                    tooltip: inhibitTooltip(held: held, canToggle: canToggle),
                    action: canToggle ? #selector(toggleChargeInhibit) : #selector(openBatterySettings))
            }() : nil,
            // Cercle d'enregistrement : tant que c'est actif, un échantillon
            // d'alimentation et d'usage toutes les dix secondes dans un CSV sur
            // le Bureau. L'infobulle porte la destination et la cadence.
            iconButton(symbol: UsageLog.isActive ? "record.circle.fill" : "record.circle",
                       active: UsageLog.isActive,
                       tooltip: L(UsageLog.isActive ? "icon.monitor.on" : "icon.monitor.off"),
                       action: #selector(toggleUsageLog)),
            iconButton(symbol: "app.badge.checkmark",
                       active: loginOn,
                       tooltip: L("icon.login", L(loginOn ? "panel.on" : "panel.off")),
                       action: #selector(toggleLoginItem)),
            iconButton(symbol: "gearshape",
                       active: false,
                       tooltip: L("panel.settings"),
                       action: #selector(openBatterySettings)),
            iconButton(symbol: "xmark.circle",
                       active: false,
                       tooltip: L("icon.quit"),
                       action: #selector(quitClicked)),
        ].compactMap { $0 }

        // Placement manuel : dans un menu, sans Auto Layout, une NSStackView
        // n'étale pas ses vues — elle les compacte à gauche. Répartir soi-même
        // est trivial et déterministe.
        let horizontal: CGFloat = 14, vertical: CGFloat = 6
        // Alignée sur la largeur du contrôle segmenté au-dessus, pour que les
        // icônes se répartissent sur la même étendue que les paliers.
        // Le plancher doit inclure les marges : sans elles le pas calculé juste
        // en dessous tombe sous la largeur d'un bouton et ils se chevauchent —
        // un clic atterrit alors sur la mauvaise bascule, sans rien pour le dire.
        let width = max(stripWidth, CGFloat(buttons.count) * 34 + horizontal * 2)
        let step = (width - horizontal * 2 - 34) / CGFloat(max(buttons.count - 1, 1))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width,
                                             height: 24 + vertical * 2))
        for (index, button) in buttons.enumerated() {
            button.setFrameOrigin(NSPoint(x: horizontal + CGFloat(index) * step, y: vertical))
            container.addSubview(button)
        }

        let item = NSMenuItem()
        item.view = container
        return item
    }

    /// Largeur du menu imposée par la rangée des paliers ; mémorisée par
    /// `limitsItem` pour que la rangée d'icônes s'étale pareil.
    private var stripWidth: CGFloat = 0

    private func iconButton(symbol: String, active: Bool, tooltip: String,
                            action: Selector) -> NSButton? {
        // `guard` et non `!` : un nom de symbole disparu d'une future version de
        // macOS coûterait un bouton, pas un plantage au premier menu ouvert.
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))
        else { return nil }
        let button = NSButton(image: image, target: self, action: action)
        button.isBordered = false
        button.setButtonType(.momentaryChange)
        button.toolTip = tooltip
        button.contentTintColor = active ? .controlAccentColor : nil
        button.setFrameSize(NSSize(width: 34, height: 24))
        return button
    }

    /// Tout ce que les anciennes lignes de texte disaient, condensé au survol :
    /// état, couverture du capot, et qui d'autre tient le Mac éveillé.
    private func sleepTooltip(active: Bool) -> String {
        var lines = [L(active ? "icon.sleep.on" : "icon.sleep.off")]
        lines.append(L(SleepGuard.canCoverLid() ? "icon.sleep.lid.on" : "icon.sleep.lid.off"))
        if SleepGuard.heldElsewhere() == true { lines.append(L("sleep.elsewhere")) }
        return lines.joined(separator: "\n")
    }

    /// L'infobulle dit ce que le bouton d'à côté ne fait PAS : empêcher la veille
    /// laisse l'écran s'éteindre. Sans cette phrase, les deux lunes/soleils
    /// passeraient pour un doublon.
    private func displayTooltip(active: Bool) -> String {
        var lines = [L(active ? "icon.display.on" : "icon.display.off")]
        if DisplayGuard.heldElsewhere() == true { lines.append(L("display.elsewhere")) }
        return lines.joined(separator: "\n")
    }

    @objc private func quitClicked(_ sender: NSButton) {
        sender.enclosingMenuItem?.menu?.cancelTracking()
        NSApp.terminate(nil)
    }

    @objc private func toggleSleepGuard() {
        // Les actions de la rangée d'icônes ne ferment pas le menu d'elles-mêmes.
        statusItem.menu?.cancelTracking()
        if case .refused = SleepGuard.toggle() {
            warn(L("error.sleepGuardFailed"), L("error.sleepGuardFailedDetail"))
        }
        // Le tooltip porte l'état de la veille : sans ça il resterait sur la
        // valeur d'avant jusqu'au prochain changement d'alimentation.
        refreshTitle()
    }

    /// L'infobulle porte ce que l'icône ne peut pas dire : le niveau plancher,
    /// et le fait que le réglage survivrait à l'app si elle était tuée.
    private func inhibitTooltip(held: Bool, canToggle: Bool) -> String {
        var lines = [L(held ? "icon.inhibit.on" : "icon.inhibit.off")]
        if !canToggle { lines.append(L("icon.inhibit.helper")) }
        else if held { lines.append(L("icon.inhibit.floor", ChargeInhibit.floor)) }
        return lines.joined(separator: "\n")
    }

    @objc private func toggleChargeInhibit() {
        statusItem.menu?.cancelTracking()
        // Relu plutôt que mémorisé : le réglage vit dans le SMC, donc il a pu
        // changer depuis un terminal entre l'ouverture du menu et le clic.
        let target = !(ChargeInhibit.isActive() ?? false)
        if !ChargeInhibit.set(target) {
            warn(L("error.inhibitFailed"),
                 L(target ? "error.inhibitFailedDetail" : "error.inhibitReleaseDetail",
                   ChargeInhibit.floor))
        }
        refreshTitle()
    }

    @objc private func toggleUsageLog() {
        statusItem.menu?.cancelTracking()
        // L'échec ne vient que de la création du fichier : premier lancement
        // sans l'accès au Bureau (macOS le demande à la première écriture) ou
        // accès refusé dans Confidentialité et sécurité.
        if !UsageLog.toggle() {
            warn(L("error.monitorFailed"), L("error.monitorFailedDetail"))
        }
    }

    @objc private func toggleDisplayGuard() {
        statusItem.menu?.cancelTracking()
        if !DisplayGuard.toggle() {
            warn(L("error.displayGuardFailed"), L("error.displayGuardFailedDetail"))
        }
        // L'icône porte l'état : sans ce rafraîchissement elle resterait sur la
        // valeur d'avant jusqu'au prochain changement d'alimentation.
        refreshTitle()
    }

    @objc private func toggleLowPower() {
        statusItem.menu?.cancelTracking()
        // On lit l'état courant plutôt que de mémoriser un booléen : il peut avoir
        // changé depuis les Réglages entre l'ouverture du menu et le clic.
        let target = !(BatteryTime.lowPowerMode() ?? false)
        if !LowPower.set(target) {
            warn(L("error.lowPowerFailed"), L("error.lowPowerFailedDetail"))
        }
    }

    // MARK: - Lancement à l'ouverture de session

    @objc private func toggleLoginItem() {
        statusItem.menu?.cancelTracking()
        let service = SMAppService.mainApp
        do {
            // `.requiresApproval` signifie que l'utilisateur a désactivé l'app dans
            // Réglages Système > Général > Ouverture ; on ne peut pas passer outre.
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            warn(L("error.loginItemFailed"), error.localizedDescription)
        }
    }

    // MARK: - Utilitaires

    /// Titre à gauche, valeur alignée à droite sur la même ligne, comme le
    /// panneau du système. Un taquet de tabulation suffit, pas besoin d'une vue
    /// sur mesure.
    private func titleRow(_ left: String, _ right: String) -> NSMenuItem {
        let paragraph = NSMutableParagraphStyle()
        // Le taquet cale la partie droite juste avant le bord du contrôle
        // segmenté, qui impose la largeur du menu.
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: max(stripWidth - 14, 200))]
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: "\(left)\t\(right)",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                         .paragraphStyle: paragraph])
        item.isEnabled = false
        return item
    }

    @objc private func openBatterySettings() {
        statusItem.menu?.cancelTracking()
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func warn(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
