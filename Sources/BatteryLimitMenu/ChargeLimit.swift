import Foundation

// La limite de charge s'appelle MCL (Maximum Charge Level) en interne. Elle n'est
// pas une propriété du matériel : ni ioreg, ni pmset, ni system_profiler ne
// l'exposent. C'est un état détenu par le démon PowerUI, joignable en XPC via
// PowerUISmartChargeClient (PowerUI.framework, privé). Le démon est déjà
// privilégié — on lui parle, donc l'app n'a besoin d'aucun droit particulier.

/// Raccourci de localisation. Les fichiers `.strings` sont posés directement dans
/// `Contents/Resources/<langue>.lproj`, donc `Bundle.main` les trouve sans détour.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return arguments.isEmpty ? format : String(format: format, arguments: arguments)
}

/// Signatures exactes des méthodes de `PowerUISmartChargeClient`.
/// Ce protocole ne fournit aucune implémentation : il donne au compilateur les
/// sélecteurs et les conventions d'appel pour taper dans une classe que l'on ne
/// peut pas lier statiquement (elle n'existe que dans le dyld shared cache).
@objc protocol SmartChargeClientAPI {
    func isMCLSupported() -> Bool
    func getMCLLimitWithError(_ error: UnsafeMutablePointer<NSError?>?) -> UInt8
    func setMCLLimit(_ limit: UInt8, error: UnsafeMutablePointer<NSError?>?) -> Bool
    func availableChargeLimitsWithError(_ error: UnsafeMutablePointer<NSError?>?) -> NSArray?
}

enum ChargeLimit {

    /// Postée par le démon à chaque changement, quelle qu'en soit l'origine :
    /// Réglages Système, app Raccourcis, ou cette app.
    static let changeNotification = "com.apple.powerui.smartchargestatuschanged"

    /// Utilisé seulement si le système ne renvoie pas de liste exploitable.
    static let fallbackLimits = [80, 85, 90, 95, 100]

    // MARK: - Client XPC

    /// Tout ce que `SmartChargeClientAPI` déclare, donc tout ce qu'on enverra à
    /// l'objet. À garder synchronisé avec le protocole.
    private static let requiredSelectors = [
        "isMCLSupported",
        "getMCLLimitWithError:",
        "setMCLLimit:error:",
        "availableChargeLimitsWithError:",
    ]

    /// Propriétaire ARC du client. Créé une fois, gardé vivant pour toute la
    /// durée de vie de l'app : c'est lui qui porte la connexion XPC.
    /// `nil` dès qu'un morceau de l'API privée manque — c'est ce qui permet à
    /// l'app de se contenter d'afficher « non pris en charge ».
    private static let owner: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI", RTLD_NOW) != nil,
              let cls = NSClassFromString("PowerUISmartChargeClient") as? NSObject.Type
        else { return nil }

        let object = cls.init()

        // Piège vérifié à la main : `-init` réussit et rend un objet parfaitement
        // vivant, mais MUET — sans connexion XPC, il répond false / 0 / tableau
        // vide, et sans jamais remplir le NSError. Seul `-initWithClientName:`
        // monte la connexion. Il renvoie self, donc `object` reste le
        // propriétaire ARC et rien ne fuit.
        let designated = Selector(("initWithClientName:"))
        guard object.responds(to: designated) else { return nil }
        _ = object.perform(designated, with: "BatteryLimitMenu")

        // Indispensable : `unsafeBitCast` vers un protocole @objc ne vérifie rien.
        // Si une mise à jour de macOS renomme ne serait-ce qu'un sélecteur, le
        // message part quand même et le processus meurt sur « unrecognized
        // selector ». On refuse donc le client entier plutôt que de planter.
        guard requiredSelectors.allSatisfy({ object.responds(to: Selector(($0))) })
        else { return nil }

        return object
    }()

    private static var client: SmartChargeClientAPI? {
        // Un protocole @objc n'a qu'une représentation : le pointeur d'objet.
        owner.map { unsafeBitCast($0, to: SmartChargeClientAPI.self) }
    }

    // MARK: - Lecture

    /// `true` si la machine gère une limite de charge réglable.
    static var isSupported: Bool { client?.isMCLSupported() ?? false }

    /// Limite réglée, en pourcent. `nil` si indisponible.
    ///
    /// `getMCLLimitWithError:` est la seule clé qui suive réellement le réglage.
    /// `currentChargeLimit:` renvoie la limite *effective à l'instant t* et reste
    /// à 100 quand la machine est débranchée — c'est un piège, on ne l'utilise pas.
    /// À 100 %, la limite est désactivée mais cette clé renvoie quand même 100,
    /// donc elle suffit seule à l'affichage.
    static func current() -> Int? {
        guard let client else { return nil }
        var error: NSError?
        let value = client.getMCLLimitWithError(&error)
        guard error == nil, value > 0 else { return nil }
        return Int(value)
    }

    /// Paliers proposés par le système, ordre croissant.
    /// Demandés au système plutôt que codés en dur, pour suivre si Apple en change.
    static func availableLimits() -> [Int] {
        guard let client else { return fallbackLimits }
        var error: NSError?
        guard let values = client.availableChargeLimitsWithError(&error) as? [NSNumber],
              !values.isEmpty
        else { return fallbackLimits }
        return values.map(\.intValue).sorted()
    }

    // MARK: - Écriture

    /// Applique une limite. Renvoie l'erreur du démon en cas d'échec.
    static func set(_ limit: Int) -> Result<Void, Error> {
        guard let client else {
            return .failure(Failure(L("error.unreachable")))
        }
        guard (0...100).contains(limit) else {
            return .failure(Failure(L("error.outOfRange", limit)))
        }
        var error: NSError?
        guard client.setMCLLimit(UInt8(limit), error: &error) else {
            return .failure(error ?? Failure(L("error.refused", limit)))
        }
        return .success(())
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Changements externes

    /// Le callback Darwin est une fonction C : il ne peut rien capturer, d'où ce
    /// stockage à part. Un seul observateur suffit pour toute l'app.
    private static var changeHandler: (() -> Void)?

    /// Observe les changements venus d'ailleurs (Réglages Système, Raccourcis).
    /// La notification Darwin ne porte aucune donnée : c'est un simple signal
    /// « quelque chose a bougé, relis ». Des changements rapprochés peuvent être
    /// fusionnés en une seule notification, ce qui est sans conséquence puisqu'on
    /// relit systématiquement l'état complet.
    static func observeChanges(_ handler: @escaping () -> Void) {
        changeHandler = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async { ChargeLimit.changeHandler?() }
            },
            changeNotification as CFString,
            nil,
            .deliverImmediately)
    }
}
