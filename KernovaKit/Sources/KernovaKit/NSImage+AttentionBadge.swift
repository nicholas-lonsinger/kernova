import AppKit

extension NSImage {
    /// Returns a copy of this (assumed template) symbol image with a small
    /// filled attention badge composited at the top-trailing corner.
    ///
    /// Shared by the host and guest status-item controllers to make the
    /// "enable File Provider" reminder (#581) glanceable without opening the
    /// dropdown. Rendered via a `drawingHandler` closure — the same technique
    /// as `VMToolbarManager.clipboardProgressImage` — so `NSColor.labelColor`
    /// resolves in the *current* menu-bar appearance every time AppKit
    /// redraws the status item. The result is intentionally non-template: the
    /// base glyph is baked in `labelColor` and the badge keeps `color`, since
    /// a template re-tint would strip the badge's color along with the
    /// glyph's.
    public func withAttentionBadge(color: NSColor = .systemOrange) -> NSImage {
        let base = self
        let size = base.size
        let badged = NSImage(size: size, flipped: false) { rect in
            NSColor.labelColor.set()
            base.draw(in: rect)
            rect.fill(using: .sourceAtop)  // tint the template glyph for the current appearance

            let diameter = floor(rect.height * 0.44)
            let badgeRect = NSRect(
                x: rect.maxX - diameter, y: rect.maxY - diameter,
                width: diameter, height: diameter)
            color.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            return true
        }
        badged.isTemplate = false
        return badged
    }
}
