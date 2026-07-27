import AppKit

extension NSImage {
    /// The badge's fill color, matching the enablement banner's icon tint.
    private static let attentionBadgeColor = NSColor.systemOrange

    /// Returns a copy of this (assumed template) symbol image with a small
    /// filled attention badge composited at the top-trailing corner.
    ///
    /// Rendered via a `drawingHandler` closure so `NSColor.labelColor` resolves in
    /// the *current* menu-bar appearance on every redraw. The result must stay
    /// non-template — a template re-tint would strip the badge's color along with
    /// the glyph's — and carries `accessibilityDescription` over from the base
    /// image, which a fresh `NSImage(size:flipped:drawingHandler:)` lacks.
    public func withAttentionBadge() -> NSImage {
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
            Self.attentionBadgeColor.setFill()
            NSBezierPath(ovalIn: badgeRect).fill()
            return true
        }
        badged.isTemplate = false
        badged.accessibilityDescription = base.accessibilityDescription
        return badged
    }
}
