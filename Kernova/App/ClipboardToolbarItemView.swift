import Cocoa

/// The clipboard toolbar item's custom view: a standard `.toolbar`-bezel
/// `NSButton` with a Safari-style transfer capsule at its bottom edge (#635).
///
/// RATIONALE: a custom view instead of a native group/bordered item because the
/// Safari-download-item look requires two things a native item's image cannot
/// express: the glyph stays full-size with the bar drawn separately at the
/// bottom, and the bar must stay fully opaque when the window is inactive (an
/// item's image — including anything composited into it — is dimmed wholesale
/// by the toolbar's inactive-window rendering). The button itself is a plain
/// AppKit `NSButton` with the standard toolbar bezel, so glyph metrics,
/// hover/pressed chrome, and enabled-state dimming stay native.
@MainActor
final class ClipboardToolbarItemView: NSView {
    /// Edge length of the square button, matching the native toolbar items.
    ///
    /// RATIONALE: a native toolbar item renders in a 36×36 pt platter on
    /// macOS 26 but there is no public API exposing that metric, and a
    /// `.toolbar`-bezel button's intrinsic size is smaller — left to its own
    /// size the button (and its glyph) visibly undershoots its native
    /// neighbors, so the button is pinned to the measured platter size.
    private static let buttonSide: CGFloat = 36
    /// Bar geometry after Safari's download toolbar item: a small opaque
    /// capsule roughly three-fifths the button width, horizontally centered
    /// under the glyph at the bottom edge of the button circle.
    ///
    /// RATIONALE: Safari hangs its bar *below* the button, but that is
    /// unreachable for a third-party item on macOS 26 — the glass toolbar
    /// composites item content through its platter machinery
    /// (`NSGlassContainerView`/`PortalView`), and content outside the item
    /// view's bounds never reaches the screen even though `visibleRect` and
    /// the layer ancestors' `masksToBounds` say nothing clips (verified live
    /// against both a drawRect- and a layer-backed bar, #635; `cacheDisplay`
    /// captures — which bypass that machinery — do show it, so don't trust
    /// them here). The capsule therefore sits *inside* the circle's bottom
    /// edge, inset far enough that its corners clear the platter's rounded
    /// shape.
    private static let barSize = NSSize(width: 20, height: 5)
    private static let barBottomInset: CGFloat = 4

    let button: NSButton
    let transferBar: ClipboardTransferBarView

    init(image: NSImage, action: Selector) {
        button = NSButton(image: image, target: nil, action: action)
        button.bezelStyle = .toolbar
        transferBar = ClipboardTransferBarView()
        transferBar.isHidden = true
        super.init(frame: .zero)

        addSubview(button)
        addSubview(transferBar)
        button.translatesAutoresizingMaskIntoConstraints = false
        transferBar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.buttonSide),
            heightAnchor.constraint(equalToConstant: Self.buttonSide),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            transferBar.centerXAnchor.constraint(equalTo: centerXAnchor),
            transferBar.widthAnchor.constraint(equalToConstant: Self.barSize.width),
            transferBar.heightAnchor.constraint(equalToConstant: Self.barSize.height),
            transferBar.bottomAnchor.constraint(
                equalTo: bottomAnchor, constant: -Self.barBottomInset),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardToolbarItemView does not support NSCoder")
    }
}

/// A Safari-style transfer capsule: an opaque light-gray track with an
/// accent-color fill growing left to right.
///
/// Deliberately not an `NSProgressIndicator` (the standard control the
/// clipboard window's bottom bar uses): on a toolbar background the
/// indicator's translucent track is near-invisible — the legibility failure
/// #635 fixes — while Safari's reference bar is fully opaque and keeps its
/// colors when the window is inactive.
///
/// Built from bare `CALayer`s with imperatively-set properties rather than
/// `draw(_:)`: a fraction update then costs one transaction-wrapped layer-frame
/// set instead of a full redraw, which matters at the chunk cadence the
/// transfer observation currently fires at.
@MainActor
final class ClipboardTransferBarView: NSView {
    /// Progress in `0...1`; out-of-range values are clamped.
    var fraction: Double = 0 {
        didSet {
            if oldValue != fraction { layoutFillLayer() }
        }
    }

    private let fillLayer = CALayer()

    /// Opaque track grays sampled from Safari's download bar.
    ///
    /// Light gray on the dark toolbar, a slightly darker gray on the light one.
    /// Deliberately not a system fill color — those are translucent, which is
    /// what made the previous bar illegible.
    private static let trackColor = NSColor(
        name: nil,
        dynamicProvider: { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.85, alpha: 1)
                : NSColor(white: 0.75, alpha: 1)
        })

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(fillLayer)
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClipboardTransferBarView does not support NSCoder")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        fillLayer.cornerRadius = bounds.height / 2
        layoutFillLayer()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Self.trackColor.cgColor
            fillLayer.backgroundColor = NSColor.controlAccentColor.cgColor
        }
    }

    private func layoutFillLayer() {
        let clamped = min(1, max(0, fraction))
        // Never narrower than the capsule's round cap, so a just-started
        // transfer shows a full leading dot rather than a clipped sliver.
        let fillWidth = max(bounds.height, bounds.width * clamped)
        // Chunk-cadence updates would otherwise each start a 0.25 s implicit
        // frame animation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: 0, width: fillWidth, height: bounds.height)
        CATransaction.commit()
    }
}
