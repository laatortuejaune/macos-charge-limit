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
    private static let nubGap: CGFloat = 1.5
    private static let nubWidth: CGFloat = 1.7
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
        let nubHeight = bodySize.height * 0.30
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
    /// Il est cerné d'un liseré transparent qui laisse voir le fond, obtenu en
    /// effaçant le glyphe décalé tout autour avant de le redessiner plein.
    /// `.destinationOut` n'efface que là où la source est opaque, contrairement à
    /// `.clear` qui viderait tout le rectangle.
    ///
    /// Le décalage circulaire est indispensable : agrandir le glyphe donnerait un
    /// liseré d'épaisseur variable, épais loin du centre et quasi nul près de lui,
    /// puisqu'une homothétie écarte les bords proportionnellement à leur distance
    /// au centre. Seule une dilatation donne une épaisseur constante.
    private static func drawBolt(in body: NSRect) {
        let height = body.height * 1.06
        guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: height, weight: .regular))
        else { return }

        let box = NSRect(x: body.midX - bolt.size.width / 2,
                         y: body.midY - bolt.size.height / 2,
                         width: bolt.size.width, height: bolt.size.height)

        let halo: CGFloat = 1.1
        let steps = 16
        for step in 0..<steps {
            let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
            bolt.draw(in: box.offsetBy(dx: cos(angle) * halo, dy: sin(angle) * halo),
                      from: .zero, operation: .destinationOut, fraction: 1)
        }
        bolt.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
