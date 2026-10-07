import AppKit

/// A row's tags as a line of colored dots, one per tag in the library's order
/// of its tags, and the one accessibility element that names them.
@MainActor
final class SidebarTagDotsView: NSView {
    static let dotDiameter: CGFloat = 8
    static let dotSpacing: CGFloat = 2
    /// The ring a dot on a selected row is drawn inside, as Finder rings its
    /// tag dots there.
    static let ringWidth: CGFloat = 1

    /// How wide `count` dots draw — the width the snap-to-fit measurement
    /// adds for a row carrying `count` tags.
    static func width(forCount count: Int) -> CGFloat {
        count == 0 ? 0 : CGFloat(count) * dotDiameter + CGFloat(count - 1) * dotSpacing
    }

    /// The tags the dots show, in order.
    var tags: [VMTag] = [] {
        didSet {
            guard tags != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
            setAccessibilityLabel(tags.isEmpty ? nil : "Tags: " + tags.map(\.name).joined(separator: ", "))
        }
    }

    /// The row's background, which the cell passes on: `.emphasized` while
    /// the row is selected in a focused list.
    var backgroundStyle: NSView.BackgroundStyle = .normal {
        didSet {
            guard backgroundStyle != oldValue else { return }
            needsDisplay = true
        }
    }

    /// The color of the ring each dot is drawn inside, `nil` for none: a
    /// selected row's highlight is itself an accent color a dot can match.
    var ringColor: NSColor? {
        backgroundStyle == .emphasized ? .alternateSelectedControlTextColor : nil
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarTagDotsView does not support NSCoder")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.width(forCount: tags.count), height: Self.dotDiameter)
    }

    /// Fills each dot in its tag's color as this view's appearance resolves
    /// it, inside ``ringColor``'s ring when there is one.
    override func draw(_ dirtyRect: NSRect) {
        let top = (bounds.height - Self.dotDiameter) / 2
        let ring = ringColor
        for (index, tag) in tags.enumerated() {
            let x = CGFloat(index) * (Self.dotDiameter + Self.dotSpacing)
            let dot = NSRect(x: x, y: top, width: Self.dotDiameter, height: Self.dotDiameter)
            if let ring {
                ring.setFill()
                NSBezierPath(ovalIn: dot).fill()
                tag.color.nsColor.setFill()
                NSBezierPath(ovalIn: dot.insetBy(dx: Self.ringWidth, dy: Self.ringWidth)).fill()
            } else {
                tag.color.nsColor.setFill()
                NSBezierPath(ovalIn: dot).fill()
            }
        }
    }
}
