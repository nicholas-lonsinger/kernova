import AppKit

extension NSImage {
    /// The badge's fill color. Not exposed as a parameter — every current
    /// caller wants the same "needs attention" orange, matching
    /// `ClipboardEnablementBanner`'s icon tint; add a parameter back if a
    /// second color is ever genuinely needed.
    private static let attentionBadgeColor = NSColor.systemOrange

    /// Returns a copy of this (assumed template) symbol image with a small
    /// filled attention badge composited at the top-trailing corner.
    ///
    /// Shared by the host and guest status-item controllers to make the
    /// "enable File Provider" reminder (#581) glanceable without opening the
    /// dropdown. Rendered via a `drawingHandler` closure so `NSColor.labelColor`
    /// resolves in the *current* menu-bar appearance every time AppKit
    /// redraws the status item. The result is intentionally non-template: the
    /// base glyph is baked in `labelColor` and the badge keeps its own color,
    /// since a template re-tint would strip the badge's color along with the
    /// glyph's. Carries over `accessibilityDescription` from the base image,
    /// since a fresh `NSImage(size:flipped:drawingHandler:)` has none — VoiceOver
    /// would otherwise lose the status item's spoken label while the badge shows.
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
