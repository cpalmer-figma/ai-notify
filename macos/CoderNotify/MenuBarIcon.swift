import AppKit
import CoreText

@MainActor
enum MenuBarIcon {
    // A single template image keeps the braces and bell together in MenuBarExtra.
    // macOS supplies the correct tint for light and dark menu bars.
    static func image(symbolName: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 34, height: 18), flipped: false) { _ in
            let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .medium)
            let ctFont = CTFontCreateWithName(font.fontName as CFString, font.pointSize, nil)
            // Center visible glyph outlines, rather than the font's baseline box.
            for (character, centerX): (UniChar, CGFloat) in [(123, 4), (125, 30)] {
                var character = character
                var glyph: CGGlyph = 0
                guard CTFontGetGlyphsForCharacters(ctFont, &character, &glyph, 1),
                      let path = CTFontCreatePathForGlyph(ctFont, glyph, nil),
                      let context = NSGraphicsContext.current?.cgContext else { continue }
                let bounds = path.boundingBoxOfPath
                context.saveGState()
                context.translateBy(x: centerX - bounds.midX, y: 9 - bounds.midY)
                context.addPath(path)
                context.setFillColor(NSColor.black.cgColor)
                context.fillPath()
                context.restoreGState()
            }
            let bell = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
            if let bell {
                let bounds = bell.alignmentRect
                let scale = min(14 / bounds.width, 14 / bounds.height)
                bell.draw(in: NSRect(x: 17 - bounds.midX * scale,
                                     y: 9 - bounds.midY * scale,
                                     width: bell.size.width * scale,
                                     height: bell.size.height * scale))
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
