import AppKit
import KernovaCore

extension VMTagColor {
    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .gray: .systemGray
        }
    }

    /// A filled circle `diameter` points across, drawn in this color as the
    /// appearance it is drawn in resolves it — for a menu item's image.
    @MainActor
    func dotImage(diameter: CGFloat = 8) -> NSImage {
        let color = nsColor
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        image.accessibilityDescription = title
        return image
    }
}
