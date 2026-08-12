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
    // Toutes ces valeurs sont relevées sur les assets du système et sur son
    // icône capturée au pixel, pas estimées à l'œil.
    private static let bodySize = NSSize(width: 23, height: 12)
    private static let cornerRadius: CGFloat = 4.4
    /// Dôme visible du téton, et son écart au corps.
    private static let capVisible = NSSize(width: 1.5, height: 4.5)
    private static let capGap: CGFloat = 1.0
    /// Hauteur à laquelle le système affiche l'éclair : il déborde du corps.
    private static let boltVisibleHeight: CGFloat = 14
    /// Le corps vide et le téton sont atténués, la portion chargée est pleine.
    private static let dimmed: CGFloat = 0.4

    static func image(level: Int, charging: Bool) -> NSImage {
        let size = NSSize(width: bodySize.width + capGap + capVisible.width + 1,
                          height: boltVisibleHeight + 1)
        let image = NSImage(size: size)
        let originY = (size.height - bodySize.height) / 2

        image.lockFocus()
        defer { image.unlockFocus(); }

        let body = NSRect(x: 0, y: originY, width: bodySize.width, height: bodySize.height)
        let shape = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)

        NSColor.black.withAlphaComponent(dimmed).setFill()
        shape.fill()

        drawCap(after: body)

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
    private static let controlCentre = Bundle(path: "/System/Library/CoreServices/ControlCenter.app")

    private static let systemBolt: (glyph: NSImage, mask: NSImage)? = {
        guard let glyph = controlCentre?.image(forResource: "battery-bolt"),
              let mask = controlCentre?.image(forResource: "battery-bolt-mask")
        else { return nil }
        return (glyph, mask)
    }()

    private static let systemCap = controlCentre?.image(forResource: "battery-cap")

    /// Le téton est un dôme, plat côté corps et bombé vers l'extérieur, pas un
    /// bâtonnet uniforme. Autant prendre celui du système que le retracer.
    private static func drawCap(after body: NSRect) {
        guard let cap = systemCap else {
            // Repli grossier : un demi-disque approché par un rectangle arrondi.
            let height = capVisible.height
            NSBezierPath(roundedRect: NSRect(x: body.maxX + capGap, y: body.midY - height / 2,
                                             width: capVisible.width, height: height),
                         xRadius: capVisible.width / 2, yRadius: capVisible.width / 2).fill()
            return
        }
        // Le dôme est collé au bord gauche de sa boîte — la demi-unité de marge
        // est à droite — donc le bord de la boîte donne directement l'écart voulu.
        cap.draw(in: NSRect(x: body.maxX + capGap, y: body.midY - cap.size.height / 2,
                            width: cap.size.width, height: cap.size.height),
                 from: .zero, operation: .sourceOver, fraction: 1)
    }

    private static func drawBolt(in body: NSRect) {
        if let systemBolt {
            // L'asset mesure 12 de haut pour son glyphe visible, alors que le
            // système l'affiche sur 14 : il l'agrandit, et c'est ce qui le fait
            // dépasser du corps et épaissit son liseré d'autant.
            let scale = boltVisibleHeight / 12.0
            let size = NSSize(width: systemBolt.glyph.size.width * scale,
                              height: systemBolt.glyph.size.height * scale)
            let box = NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2,
                             width: size.width, height: size.height)
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
