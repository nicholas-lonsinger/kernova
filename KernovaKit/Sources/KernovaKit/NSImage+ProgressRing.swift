import AppKit

extension NSImage {
    /// Stroke width of the ring, as a fraction of the icon's side.
    private static let progressRingLineFraction: CGFloat = 0.09

    /// How much of the icon's side the glyph inside the ring occupies.
    private static let progressRingGlyphFraction: CGFloat = 0.62

    /// Returns a copy of this (assumed template) symbol image with a determinate
    /// progress ring drawn around a shrunken copy of the glyph.
    ///
    /// It carries no timer: the caller redraws it per progress update. Like
    /// `withAttentionBadge()` it renders through a `drawingHandler` so
    /// `labelColor` resolves in the menu bar's current appearance, must stay
    /// non-template (a re-tint would flatten the track's alpha into the arc), and
    /// carries `accessibilityDescription` over. The result is always square.
    public func withProgressRing(fraction: Double) -> NSImage {
        let base = self
        let side = max(base.size.width, base.size.height)
        guard side > 0 else { return base }
        let clamped = min(1, max(0, fraction))

        let ringed = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let lineWidth = max(1.5, rect.height * Self.progressRingLineFraction)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.height / 2 - lineWidth / 2

            let glyphBox = rect.height * Self.progressRingGlyphFraction
            let scale = min(glyphBox / base.size.width, glyphBox / base.size.height)
            let glyphSize = NSSize(
                width: base.size.width * scale, height: base.size.height * scale)
            let glyphRect = NSRect(
                x: center.x - glyphSize.width / 2, y: center.y - glyphSize.height / 2,
                width: glyphSize.width, height: glyphSize.height)
            base.draw(in: glyphRect)
            NSColor.labelColor.set()
            // Tint only the glyph: `.sourceAtop` paints where the destination is
            // already opaque, so confining it here keeps the ring's own alpha.
            glyphRect.fill(using: .sourceAtop)

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.labelColor.withAlphaComponent(0.25).setStroke()
            track.stroke()

            guard clamped > 0 else { return true }
            // Clockwise from twelve o'clock, the direction every progress ring
            // on the platform fills.
            let progress = NSBezierPath()
            progress.appendArc(
                withCenter: center, radius: radius, startAngle: 90,
                endAngle: 90 - 360 * clamped, clockwise: true)
            progress.lineWidth = lineWidth
            progress.lineCapStyle = .round
            NSColor.labelColor.setStroke()
            progress.stroke()
            return true
        }
        ringed.isTemplate = false
        ringed.accessibilityDescription = base.accessibilityDescription
        return ringed
    }
}
