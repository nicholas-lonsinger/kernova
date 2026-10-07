import AppKit

/// A row's tags as a line of colored dots, one per tag in the library's order
/// of its tags.
///
/// Draws only: the row cell states the tag names as its accessibility value,
/// so the dots are no accessibility element of their own.
@MainActor
final class SidebarTagDotsView: NSView {
    static let dotDiameter: CGFloat = 8
    static let dotSpacing: CGFloat = 2

    /// How wide `count` dots draw — the width the snap-to-fit measurement
    /// adds for a row carrying `count` tags.
    static func width(forCount count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * dotDiameter + CGFloat(count - 1) * dotSpacing
    }

    /// The colors of the dots, in order.
    var colors: [VMTagColor] = [] {
        didSet {
            guard colors != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarTagDotsView does not support NSCoder")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width(forCount: colors.count), height: Self.dotDiameter)
    }

    /// Fills each dot in its color as this view's appearance resolves it.
    override func draw(_ dirtyRect: NSRect) {
        let top = (bounds.height - Self.dotDiameter) / 2
        for (index, color) in colors.enumerated() {
            let x = CGFloat(index) * (Self.dotDiameter + Self.dotSpacing)
            color.nsColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: top, width: Self.dotDiameter, height: Self.dotDiameter)).fill()
        }
    }
}
