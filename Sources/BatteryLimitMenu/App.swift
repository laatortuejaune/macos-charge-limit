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
        button.image = BatteryGauge.image(level: gauge.level, charging: gauge.charging,
                                          plugged: gauge.plugged)

        if let limit = ChargeLimit.current() {
            button.toolTip = L("status.tooltip.full", gauge.level, limit)
        } else {
            button.toolTip = L("status.tooltip", gauge.level)
        }
    }

    // MARK: - Menu

    /// Reconstruit le menu à chaque ouverture : l'état affiché est relu au moment
    /// où tu le regardes, même si une notification avait été manquée.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let gauge = BatteryTime.gauge()
        let current = ChargeLimit.isSupported ? ChargeLimit.current() : nil

        // Même ossature que le panneau batterie de macOS — titre et pourcentage,
        // source d'alimentation, état de charge, mode économie, accès aux
        // réglages — pour qu'on puisse masquer celui du système sans rien perdre.
        menu.addItem(titleRow(L("panel.title"),
                              gauge.map { L("menu.level", $0.level) } ?? "—"))
        if let gauge {
            menu.addItem(header(L("panel.source",
                                  L(gauge.plugged ? "panel.source.adapter"
                                                  : "panel.source.battery"))))
        }
        if let summary = BatteryTime.summary(limit: current) {
            menu.addItem(header(summary))
        }

        menu.addItem(.separator())
        if ChargeLimit.isSupported {
            menu.addItem(header(L("menu.header")))
            menu.addItem(limitsItem(current: current, limits: ChargeLimit.availableLimits()))
        } else {
            menu.addItem(header(L("menu.unsupported")))
        }

        if let low = BatteryTime.lowPowerMode() {
            menu.addItem(.separator())
            // Lecture seule : le clic renvoie aux Réglages, seul endroit où le
            // basculer sans le droit système qui nous manque.
            let item = NSMenuItem(title: L("panel.lowPower", L(low ? "panel.on" : "panel.off")),
                                  action: #selector(openBatterySettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(loginItem())
        let settings = NSMenuItem(title: L("panel.settings"),
                                  action: #selector(openBatterySettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(quitItem())

        refreshTitle()
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
            if limit >= 100 { control.setToolTip(L("menu.noLimitHint"), forSegment: index) }
            if limit == current { control.selectedSegment = index }
        }
        control.sizeToFit()

        // Marges alignées sur celles d'un titre de menu ordinaire.
        let horizontal: CGFloat = 14, vertical: CGFloat = 5
        let container = NSView(frame: NSRect(x: 0, y: 0,
                                             width: control.frame.width + horizontal * 2,
                                             height: control.frame.height + vertical * 2))
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

    // MARK: - Lancement à l'ouverture de session

    private func loginItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("menu.launchAtLogin"),
                              action: #selector(toggleLoginItem), keyEquivalent: "")
        item.target = self
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
        return item
    }

    @objc private func toggleLoginItem() {
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
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 200)]
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(
            string: "\(left)\t\(right)",
            attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                         .paragraphStyle: paragraph])
        item.isEnabled = false
        return item
    }

    @objc private func openBatterySettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func quitItem() -> NSMenuItem {
        NSMenuItem(title: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
