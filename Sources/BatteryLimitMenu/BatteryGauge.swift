import AppKit

// Jauge de batterie de la barre de menu, dessinée pour ressembler à celle de
// macOS. Aucun SF Symbol ne convient : les symboles `battery.*` n'acceptent pas
// la valeur variable — vérifié sur les six, alors que `wifi` et `speaker.wave.3`
// l'acceptent. Apple dessine donc la sienne, et il faut faire de même pour avoir
// un remplissage continu plutôt que cinq paliers figés.
//
// L'image est *template* : seul l'alpha porte l'information, la teinte est
// choisie par le système. C'est ce qui la fait basculer toute seule entre thème
// clair et sombre, et passer en inversé quand le menu est ouvert.

enum BatteryGauge {

    // Proportions relevées sur l'icône de macOS, agrandie au pixel : corps de
    // rapport ~1,84, coins très arrondis, téton détaché par un léger espace.
    private static let bodySize = NSSize(width: 23.6, height: 12.8)
    private static let nubGap: CGFloat = 0.8
    private static let nubWidth: CGFloat = 1.5
    private static let cornerRadius: CGFloat = 5.2
    /// Le corps vide et le téton sont atténués, la portion chargée est pleine.
    private static let dimmed: CGFloat = 0.4

    static func image(level: Int, charging: Bool) -> NSImage {
        let size = NSSize(width: bodySize.width + nubGap + nubWidth + 1,
                          height: bodySize.height + 2)
        let image = NSImage(size: size)
        let originY = (size.height - bodySize.height) / 2

        image.lockFocus()
        defer { image.unlockFocus(); }

        let body = NSRect(x: 0, y: originY, width: bodySize.width, height: bodySize.height)
        let shape = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)

        NSColor.black.withAlphaComponent(dimmed).setFill()
        shape.fill()

        // Téton détaché, dans le même gris que la partie vide.
        let nubHeight = bodySize.height * 0.38
        let nub = NSBezierPath(roundedRect: NSRect(x: body.maxX + nubGap,
                                                   y: body.midY - nubHeight / 2,
                                                   width: nubWidth, height: nubHeight),
                               xRadius: nubWidth / 2, yRadius: nubWidth / 2)
        nub.fill()

        // Portion chargée : la même forme, rognée à la largeur du niveau, pour
        // que les coins arrondis restent ceux du corps.
        let fraction = CGFloat(min(max(level, 0), 100)) / 100
        if fraction > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSColor.black.setFill()
            NSRect(x: body.minX, y: body.minY,
                   width: body.width * fraction, height: body.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        if charging { drawBolt(in: body) }

        image.isTemplate = true
        return image
    }

    /// L'éclair vient du symbole `bolt.fill` : c'est le dessin d'Apple lui-même,
    /// donc inutile d'essayer de le retracer à la main.
    ///
    /// Il est cerné d'un liseré transparent qui laisse voir le fond. On l'obtient
    /// en effaçant d'abord une version légèrement agrandie — `.destinationOut`
    /// n'efface que là où la source est opaque, contrairement à `.clear` qui
    /// viderait tout le rectangle.
    private static func drawBolt(in body: NSRect) {
        let height = body.height * 1.06
        guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: height, weight: .regular))
        else { return }

        let size = bolt.size
        func rect(scale: CGFloat) -> NSRect {
            NSRect(x: body.midX - size.width * scale / 2,
                   y: body.midY - size.height * scale / 2,
                   width: size.width * scale, height: size.height * scale)
        }

        bolt.draw(in: rect(scale: 1.20), from: .zero, operation: .destinationOut, fraction: 1)
        bolt.draw(in: rect(scale: 1.0), from: .zero, operation: .sourceOver, fraction: 1)
    }
}
