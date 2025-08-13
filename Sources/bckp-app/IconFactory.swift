import AppKit

/// Generates a crisp vector-based app icon at runtime.
/// This avoids asset catalogs in SwiftPM and still shows a custom Dock icon.
enum IconFactory {
    static func makeAppIcon(size: CGFloat = 1024) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()

        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        let corner: CGFloat = size * 0.18

        // Background: rounded rect with subtle vertical gradient (blue-ish)
        let bgPath = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: corner, yRadius: corner)
        let top = NSColor(calibratedRed: 0.11, green: 0.42, blue: 0.93, alpha: 1)
        let bottom = NSColor(calibratedRed: 0.02, green: 0.23, blue: 0.60, alpha: 1)
        let gradient = NSGradient(starting: top, ending: bottom)
        gradient?.draw(in: bgPath, angle: 90)

        // Foreground: a large white monospaced capital 'B'
        let title = "B"
        let fontSize = size * 0.62
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .heavy)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let text = NSAttributedString(string: title, attributes: attrs)
        // Center the glyph within the rounded rect with comfortable side insets
        let textHeight = fontSize * 1.08
        let textRect = NSRect(
            x: rect.minX + size * 0.12,
            y: rect.midY - textHeight / 2,
            width: rect.width - size * 0.24,
            height: textHeight
        )
        text.draw(in: textRect)

    // No text or extra ornaments — minimal white arrow on blue

        img.unlockFocus()
        return img
    }
}
