#!/usr/bin/env swift
// Génère Resources/AppIcon.icns.
//   swift Resources/make-icon.swift
// Dessine à chaque taille plutôt que de réduire un master : le glyphe reste net
// à 16 px, ce qu'un simple downscale ne donne pas.

import AppKit
import Foundation

let symbolNames = ["battery.100percent.bolt", "bolt.batteryblock", "battery.100percent"]

func symbol(pointSize: CGFloat) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    for name in symbolNames {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            return image
        }
    }
    return nil
}

/// Teinte le glyphe en blanc sur un fond TRANSPARENT.
/// `.sourceAtop` ne peint que là où la destination est déjà opaque : appliqué
/// directement sur le dégradé, il repeindrait tout le rectangle du glyphe.
func whiteGlyph(pointSize: CGFloat) -> NSImage? {
    guard let glyph = symbol(pointSize: pointSize) else { return nil }
    let size = glyph.size
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width.rounded()),
        pixelsHigh: Int(size.height.rounded()), bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    glyph.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
    NSGraphicsContext.restoreGraphicsState()

    let out = NSImage(size: size)
    out.addRepresentation(rep)
    return out
}

func render(size: Int) -> Data? {
    let side = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Squircle : marge transparente puis coins arrondis, comme les icônes système.
    let margin = side * 0.085
    let box = NSRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin)
    let squircle = NSBezierPath(roundedRect: box,
                                xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGradient(colors: [NSColor(srgbRed: 0.30, green: 0.85, blue: 0.39, alpha: 1),
                        NSColor(srgbRed: 0.06, green: 0.52, blue: 0.25, alpha: 1)])?
        .draw(in: squircle, angle: -90)

    if let glyph = whiteGlyph(pointSize: side * 0.46) {
        let s = glyph.size
        let origin = NSPoint(x: (side - s.width) / 2, y: (side - s.height) / 2)
        glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (taille de base, facteur) → nom attendu par iconutil
for (base, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                      (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = base * scale
    guard let png = render(size: pixels) else {
        FileHandle.standardError.write("échec du rendu \(pixels)px\n".data(using: .utf8)!)
        exit(1)
    }
    let suffix = scale == 2 ? "@2x" : ""
    try png.write(to: iconset.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path,
                     "-o", resources.appendingPathComponent("AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)

print(convert.terminationStatus == 0 ? "AppIcon.icns généré" : "iconutil a échoué")
exit(convert.terminationStatus)
