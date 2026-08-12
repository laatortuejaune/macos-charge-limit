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
        statusItem.button?.image = Self.statusIcon()
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        refreshTitle()

        // Resynchronisation quand la limite change ailleurs (Réglages Système,
        // Raccourcis). Le démon poste la notification quelle qu'en soit l'origine.
        ChargeLimit.observeChanges { [weak self] in self?.refreshTitle() }
    }

    // MARK: - Barre de menu

    private func refreshTitle() {
        guard let button = statusItem.button else { return }
        if let limit = ChargeLimit.current() {
            button.title = L("status.title", limit)
            button.toolTip = L("status.tooltip", limit)
        } else {
            button.title = L("status.title.unavailable")
            button.toolTip = L("status.tooltip.unavailable")
        }
    }

    private static func statusIcon() -> NSImage? {
        // Le premier symbole disponible gagne : les noms SF Symbols ont changé
        // entre versions de macOS, autant ne pas parier sur un seul.
        for name in ["battery.100percent.bolt", "bolt.batteryblock",
                     "battery.100percent", "battery.100"] {
            if let image = NSImage(systemSymbolName: name,
                                   accessibilityDescription: "Limite de charge") {
                image.isTemplate = true   // suit le thème clair / sombre
                return image
            }
        }
        return nil
    }

    // MARK: - Menu

    /// Reconstruit le menu à chaque ouverture : l'état affiché est relu au moment
    /// où tu le regardes, même si une notification avait été manquée.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        guard ChargeLimit.isSupported else {
            addBatteryStatus(to: menu, limit: nil)
            menu.addItem(header(L("menu.unsupported")))
            menu.addItem(.separator())
            menu.addItem(loginItem())
            menu.addItem(.separator())
            menu.addItem(quitItem())
            return
        }

        let current = ChargeLimit.current()
        addBatteryStatus(to: menu, limit: current)
        menu.addItem(header(L("menu.header")))

        menu.addItem(limitsItem(current: current, limits: ChargeLimit.availableLimits()))

        menu.addItem(.separator())
        menu.addItem(loginItem())
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

    /// Temps restant, en tête de menu. Le menu étant reconstruit à chaque
    /// ouverture, la valeur est fraîche au moment où on la regarde — inutile
    /// d'ajouter un minuteur pour une ligne qu'on ne voit que menu ouvert.
    private func addBatteryStatus(to menu: NSMenu, limit: Int?) {
        guard let summary = BatteryTime.summary(limit: limit) else { return }
        menu.addItem(header(summary))
        menu.addItem(.separator())
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
