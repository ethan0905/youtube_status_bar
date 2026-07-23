import Cocoa

// The idle-state menu bar icon: the YouTube play button, drawn natively (no bundled asset).
// Red variant renders as-is; the template variant is a black rounded rect with the triangle
// punched out as negative space (isTemplate), so macOS adapts it to the menu bar appearance.
enum YouTubeIcon {
    static let red = NSColor(srgbRed: 1.0, green: 0.0, blue: 0.0, alpha: 1)

    static func icon(template: Bool) -> NSImage {
        let s: CGFloat = 18
        let rw: CGFloat = 16, rh: CGFloat = 11.5, radius: CGFloat = 3.2
        let body = NSRect(x: (s - rw) / 2, y: (s - rh) / 2, width: rw, height: rh)
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (template ? NSColor.black : red).setFill()
            NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).fill()
            // Play triangle, optically centered (nudged right: a centroid-centered triangle reads left-heavy).
            let tw: CGFloat = 5.2, th: CGFloat = 5.6
            let cx = body.midX + 0.4, cy = body.midY
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: cx - tw / 2, y: cy - th / 2))
            tri.line(to: NSPoint(x: cx - tw / 2, y: cy + th / 2))
            tri.line(to: NSPoint(x: cx + tw / 2, y: cy))
            tri.close()
            if template {
                NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                NSColor.black.setFill()
                tri.fill()
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            } else {
                NSColor.white.setFill()
                tri.fill()
            }
            return true
        }
        img.isTemplate = template
        return img
    }
}
