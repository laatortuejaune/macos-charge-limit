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
            menu.addItem(header(L("menu.unsupported")))
            menu.addItem(.separator())
            menu.addItem(loginItem())
            menu.addItem(.separator())
            menu.addItem(quitItem())
            return
        }

        let current = ChargeLimit.current()
        menu.addItem(header(L("menu.header")))

        for limit in ChargeLimit.availableLimits() {
            let title = L(limit >= 100 ? "menu.level.unlimited" : "menu.level", limit)
            let item = NSMenuItem(title: title, action: #selector(selectLimit(_:)), keyEquivalent: "")
            item.target = self
            item.tag = limit
            item.state = (limit == current) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(loginItem())
        menu.addItem(.separator())
        menu.addItem(quitItem())

        refreshTitle()
    }

    @objc private func selectLimit(_ sender: NSMenuItem) {
        if case .failure(let error) = ChargeLimit.set(sender.tag) {
            warn(L("error.setFailed", sender.tag), error.localizedDescription)
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
