import Cocoa

/// The clipboard toolbar item's view: a standard `.toolbar`-bezel button with a
/// transfer-progress bar overlaid as a subview across the bottom of the platter
/// circle.
///
/// The button is pinned to the glass toolbar platter's 36×36 metric; at exactly
/// that size the bezel's rollover is the platter's circular hover highlight (see
/// docs/TOOLBAR.md for the platter metrics).
final class ClipboardToolbarButton: NSButton {
    /// The button's glyph, shared with the toolbar item's menu form
    /// representation so the overflow menu shows the same symbol.
    static let symbolName = "doc.on.clipboard"

    /// The glass toolbar platter's circle diameter (docs/TOOLBAR.md).
    ///
    /// The bezel's hover circle matches the platter only at exactly this size.
    private static let platterDiameter: CGFloat = 36

    private let bar = TransferBarView()

    /// The in-flight transfer's completion fraction, or `nil` when idle.
    var transferFraction: Double? {
        didSet {
            guard transferFraction != oldValue else { return }
            bar.isHidden = transferFraction == nil
            bar.fraction = transferFraction ?? 0
        }
    }

    init() {
        super.init(frame: .zero)
        image = .systemSymbol(Self.symbolName, accessibilityDescription: "Clipboard")
        bezelStyle = .toolbar
        isBordered = true
        translatesAutoresizingMaskIntoConstraints = false

        bar.isHidden = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.platterDiameter),
            heightAnchor.constraint(equalToConstant: Self.platterDiameter),
            // Safari's downloads-button bar metrics: 22×6, centered, bottom
            // edge 3 pt above the circle's rim.
            bar.widthAnchor.constraint(equalToConstant: 22),
            bar.heightAnchor.constraint(equalToConstant: 6),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// The capsule-shaped progress bar inside `ClipboardToolbarButton`: an opaque
/// track with an accent-colored fill, drawn in `draw(_:)` so the dynamic colors
/// resolve in the current appearance on every redraw.
private final class TransferBarView: NSView {
    /// Completion fraction, clamped to 0…1 at draw time.
    var fraction: Double = 0 {
        didSet {
            guard fraction != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Opaque track grays: light gray on the dark toolbar, a slightly darker
    /// gray on the light one.
    ///
    /// Deliberately not a system fill color — those are translucent, which makes
    /// the track illegible over the glass platter.
    private static let trackColor = NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.85, alpha: 1)
                : NSColor(white: 0.75, alpha: 1)
        })

    /// Decoration only: hands every event through to the button underneath, so
    /// the bar can't swallow hits over the bottom of the circle.
    nonisolated override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        Self.trackColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()

        // Never narrower than the capsule's round cap, so a just-started
        // transfer shows a full leading dot rather than a clipped sliver.
        let clamped = CGFloat(min(max(fraction, 0), 1))
        let fillWidth = max(bounds.height, bounds.width * clamped)
        let fill = NSRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }
}
