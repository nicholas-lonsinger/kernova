import AppKit

extension NSImage {
    /// Stroke width of the ring, as a fraction of the icon's side.
    private static let progressRingLineFraction: CGFloat = 0.09

    /// How much of the icon's side the glyph inside the ring occupies.
    ///
    /// Sized to clear the ring by a comfortable margin at menu-bar scale rather
    /// than to the largest inscribed rectangle: a symbol's corners are almost
    /// never filled, so inscribing exactly would shrink the glyph well past
    /// legibility for a clearance nothing needs.
    private static let progressRingGlyphFraction: CGFloat = 0.62

    /// Returns a copy of this (assumed template) symbol image with a determinate
    /// progress ring drawn around a shrunken copy of the glyph.
    ///
    /// The menu-bar indicator for a paste materializing in the background
    /// (#643), shared by the host and guest status-item controllers. It carries
    /// no timer: the caller redraws it per throttled progress update, so the
    /// ring's motion *is* the byte stream.
    ///
    /// Deliberately monochrome — `labelColor` for the filled arc, the same at
    /// low alpha for the track — because a tinted menu-bar icon reads as a
    /// foreign element next to the system's own. Like `withAttentionBadge()`
    /// this renders through a `drawingHandler` so `labelColor` resolves in
    /// whatever appearance the menu bar currently has, returns a
    /// non-template image (a re-tint would flatten the track's alpha into the
    /// arc), and carries `accessibilityDescription` over from the base image so
    /// VoiceOver keeps the status item's spoken label.
    ///
    /// The result is square even when the symbol isn't, so the ring is a circle
    /// rather than a squashed oval; the glyph keeps its own aspect ratio inside.
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
            // already opaque, and confining it to the glyph's own rect keeps the
            // ring below free to use its own alpha.
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
