import AppKit

extension NSColor {
    /// `self` at `alpha`, re-resolved for each appearance it is drawn in.
    func withDynamicAlpha(_ alpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            var tinted = self
            appearance.performAsCurrentDrawingAppearance { tinted = self.withAlphaComponent(alpha) }
            return tinted
        }
    }
}
