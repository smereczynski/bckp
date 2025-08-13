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

        // Symbol: circular backup arrow (white)
        let symbolColor = NSColor.white
        symbolColor.set()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let ringRadius = size * 0.28
        let ringLineWidth = size * 0.065
        let startAngle: CGFloat = 35
        let endAngle: CGFloat = 320

        let ringPath = NSBezierPath()
        ringPath.lineWidth = ringLineWidth
        ringPath.lineCapStyle = .round
        ringPath.appendArc(withCenter: center, radius: ringRadius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        ringPath.stroke()

        // Arrow head at endAngle
        let arrowLen = ringLineWidth * 2.1
        let arrowWidth = ringLineWidth * 1.2
        let theta = endAngle * (.pi / 180)
        let endPt = CGPoint(x: center.x + ringRadius * cos(theta), y: center.y + ringRadius * sin(theta))
        let dir = CGPoint(x: cos(theta), y: sin(theta))
        // Perpendicular vector
        let perp = CGPoint(x: -dir.y, y: dir.x)
        let a1 = CGPoint(x: endPt.x - dir.x * arrowLen + perp.x * arrowWidth, y: endPt.y - dir.y * arrowLen + perp.y * arrowWidth)
        let a2 = CGPoint(x: endPt.x - dir.x * arrowLen - perp.x * arrowWidth, y: endPt.y - dir.y * arrowLen - perp.y * arrowWidth)
        let arrowPath = NSBezierPath()
        arrowPath.move(to: endPt)
        arrowPath.line(to: a1)
        arrowPath.line(to: a2)
        arrowPath.close()
        arrowPath.fill()

    // No text or extra ornaments — minimal white arrow on blue

        img.unlockFocus()
        return img
    }
}
