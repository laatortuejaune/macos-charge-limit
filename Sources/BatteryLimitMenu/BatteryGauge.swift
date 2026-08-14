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
    /// Hauteur à laquelle le système affiche l'éclair et la prise : ils débordent
    /// du corps.
    private static let overlayHeight: CGFloat = 14.5
    /// Hauteur du canevas, tenue à un entier pour que le corps tombe sur un
    /// multiple de 0,5 pt. À 15,5 l'origine vaut 1,75 et le corps se retrouve à
    /// cheval sur la grille rétina : il est alors rendu sur 12,5 pt au lieu de 12.
    private static let canvasHeight: CGFloat = 15
    /// Le corps vide et le téton sont atténués, la portion chargée est pleine.
    private static let dimmed: CGFloat = 0.4

    /// `plugged` sans `charging` n'est pas un détail : c'est l'état normal une
    /// fois la limite atteinte, et le système y affiche une prise plutôt qu'un
    /// éclair. Sans ça, l'icône ne montre plus rien alors que le Mac est branché.
    ///
    /// `lowPower` teinte la jauge en jaune, comme macOS et iOS. Ça force à sortir
    /// du mode *template* : une image template n'a pas de couleur propre, le
    /// système la teinte lui-même. Il faut donc résoudre soi-même la teinte du
    /// reste — d'où `appearance`, celle de la barre de menu et non celle de
    /// l'app, les deux pouvant différer.
    static func image(level: Int, charging: Bool, plugged: Bool = false,
                      lowPower: Bool = false,
                      appearance: NSAppearance? = nil) -> NSImage {
        let size = NSSize(width: bodySize.width + capGap + capVisible.width + 1,
                          height: canvasHeight)
        let image = NSImage(size: size)
        let originY = (size.height - bodySize.height) / 2

        image.lockFocus()
        defer { image.unlockFocus(); }

        // En mode template on dessine en noir : le système remplace la teinte.
        // Sinon il faut la résoudre soi-même, contre l'apparence de la barre.
        let ink = lowPower ? resolvedInk(appearance) : .black
        let fill = lowPower ? NSColor.systemYellow : .black

        let body = NSRect(x: 0, y: originY, width: bodySize.width, height: bodySize.height)
        let shape = NSBezierPath(roundedRect: body, xRadius: cornerRadius, yRadius: cornerRadius)

        ink.withAlphaComponent(dimmed).setFill()
        shape.fill()

        drawCap(after: body, ink: ink)

        // Portion chargée : la même forme, rognée à la largeur du niveau, pour
        // que les coins arrondis restent ceux du corps.
        let fraction = CGFloat(min(max(level, 0), 100)) / 100
        if fraction > 0 {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            fill.setFill()
            NSRect(x: body.minX, y: body.minY,
                   width: body.width * fraction, height: body.height).fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        if charging {
            drawOverlay(systemBolt, in: body, ink: ink)
        } else if plugged {
            drawOverlay(systemPlug, in: body, ink: ink)
        }

        image.isTemplate = !lowPower
        return image
    }

    /// Teinte du tracé quand l'image n'est plus template. La barre de menu peut
    /// être sombre alors que l'app est claire, d'où l'apparence passée en
    /// paramètre plutôt que celle de l'application.
    private static func resolvedInk(_ appearance: NSAppearance?) -> NSColor {
        let source = appearance ?? NSApp.effectiveAppearance
        let dark = source.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? .white : .black
    }

    // Les glyphes viennent du bundle de Contrôle : ce sont les images d'Apple
    // elles-mêmes, lues sur la machine au moment de l'affichage. Rien n'est copié
    // dans le dépôt, exactement comme pour un SF Symbol.
    //
    // Chacun est livré avec son masque, une version épaissie du même dessin. Le
    // liseré autour du glyphe est donc celui du système au pixel près, au lieu
    // d'être approché à la main.

    private static let controlCentre = Bundle(path: "/System/Library/CoreServices/ControlCenter.app")

    private static func systemGlyph(_ name: String) -> (glyph: NSImage, mask: NSImage, scale: CGFloat)? {
        guard let glyph = controlCentre?.image(forResource: name),
              let mask = controlCentre?.image(forResource: "\(name)-mask")
        else { return nil }
        // Chaque glyphe occupe sa boîte différemment — l'éclair fait 12 de haut,
        // la prise 12,875 — donc un facteur commun en décalerait un. On mesure la
        // hauteur réellement dessinée pour l'amener à celle qu'affiche le système.
        let drawn = visibleHeight(of: glyph)
        guard drawn > 0 else { return nil }
        return (glyph, mask, overlayHeight / drawn)
    }

    /// Hauteur du dessin à l'intérieur de la boîte de l'image, marges exclues.
    private static func visibleHeight(of image: NSImage) -> CGFloat {
        let sampling: CGFloat = 4
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width * sampling),
            pixelsHigh: Int(image.size.height * sampling),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return 0 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero,
                              size: NSSize(width: image.size.width * sampling,
                                           height: image.size.height * sampling)))
        NSGraphicsContext.restoreGraphicsState()

        var top = -1, bottom = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                if top < 0 { top = y }
                bottom = y
                break
            }
        }
        return bottom < 0 ? 0 : CGFloat(bottom - top + 1) / sampling
    }

    private static let systemBolt = systemGlyph("battery-bolt")
    /// Branché sans charger : le système montre une prise, pas un éclair.
    private static let systemPlug = systemGlyph("battery-plug")

    private static let systemCap = controlCentre?.image(forResource: "battery-cap")

    /// Le téton est un dôme, plat côté corps et bombé vers l'extérieur, pas un
    /// bâtonnet uniforme. Autant prendre celui du système que le retracer.
    private static func drawCap(after body: NSRect, ink: NSColor) {
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
        let box = NSRect(x: body.maxX + capGap, y: body.midY - cap.size.height / 2,
                         width: cap.size.width, height: cap.size.height)

        guard ink != .black else {
            // Mode template : le système teinte, on dessine tel quel.
            cap.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            return
        }

        // Hors template, l'atténuation doit venir de l'opacité du DESSIN, pas de
        // la couleur qui le repeint. Teinter du noir opaque avec un blanc à 40 %
        // donne un gris sombre *opaque* — invisible sur une barre sombre, ce qui
        // faisait disparaître le dôme. On dessine donc à 40 %, puis `.sourceAtop`
        // remplace la couleur en conservant cette opacité.
        cap.draw(in: box, from: .zero, operation: .sourceOver, fraction: dimmed)
        ink.setFill()
        box.fill(using: .sourceAtop)
    }

    private static func drawOverlay(_ pair: (glyph: NSImage, mask: NSImage, scale: CGFloat)?,
                                    in body: NSRect, ink: NSColor) {
        if let pair {
            // Le système agrandit ces glyphes : c'est ce qui les fait dépasser du
            // corps tout en épaississant leur liseré d'autant.
            let size = NSSize(width: pair.glyph.size.width * pair.scale,
                              height: pair.glyph.size.height * pair.scale)
            let box = NSRect(x: body.midX - size.width / 2, y: body.midY - size.height / 2,
                             width: size.width, height: size.height)
            pair.mask.draw(in: box, from: .zero, operation: .destinationOut, fraction: 1)
            pair.glyph.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1)
            // Hors mode template, le glyphe reste noir : on le repeint dans la
            // teinte résolue, `.sourceAtop` ne touchant que ce qui est déjà opaque.
            if ink != .black {
                ink.setFill()
                box.fill(using: .sourceAtop)
            }
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
