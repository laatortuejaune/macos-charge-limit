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
    private static let bodySize = NSSize(width: 23, height: 12)
    private static let nubGap: CGFloat = 1.5
    private static let nubWidth: CGFloat = 2
    private static let cornerRadius: CGFloat = 4.4
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
    /// L'éclair et son détourage viennent du bundle de Contrôle : ce sont les
    /// images d'Apple elles-mêmes, lues sur la machine au moment de l'affichage.
    /// Rien n'est copié dans le dépôt, exactement comme pour un SF Symbol.
    ///
    /// Le masque est une version épaissie du glyphe, livrée telle quelle — donc
    /// le liseré est celui du système au pixel près, au lieu d'être approché.
    private static let systemBolt: (glyph: NSImage, mask: NSImage)? = {
        guard let bundle = Bundle(path: "/System/Library/CoreServices/ControlCenter.app"),
              let glyph = bundle.image(forResource: "battery-bolt"),
              let mask = bundle.image(forResource: "battery-bolt-mask")
        else { return nil }
        return (glyph, mask)
    }()

    private static func drawBolt(in body: NSRect) {
        if let systemBolt {
            let box = NSRect(x: body.midX - systemBolt.glyph.size.width / 2,
                             y: body.midY - systemBolt.glyph.size.height / 2,
                             width: systemBolt.glyph.size.width,
                             height: systemBolt.glyph.size.height)
            systemBolt.mask.draw(in: box, from: .zero, operation: .destinationOut, fraction: 1)
            systemBolt.glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        // Repli si le bundle du système bouge : on refait le liseré à la main.
        // Le décalage circulaire est indispensable, car agrandir le glyphe
        // donnerait une épaisseur variable — une homothétie écarte les bords
        // proportionnellement à leur distance au centre, pas uniformément.
        guard let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: body.height * 1.06,
                                                                 weight: .regular))
        else { return }
        let box = NSRect(x: body.midX - bolt.size.width / 2,
                         y: body.midY - bolt.size.height / 2,
                         width: bolt.size.width, height: bolt.size.height)
        for step in 0..<16 {
            let angle = CGFloat(step) / 16 * 2 * .pi
            bolt.draw(in: box.offsetBy(dx: cos(angle) * 1.1, dy: sin(angle) * 1.1),
                      from: .zero, operation: .destinationOut, fraction: 1)
        }
        bolt.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
