import AppKit
import os

/// Shows the standard "there's more content below" cues over a vertically
/// scrolling view: a down-chevron disc and a soft bottom fade, plus a one-time
/// scroller flash when overflowing content first appears.
///
/// Shared by the creation wizard's steps and the delete-VM sheet so the cue is
/// identical everywhere. It is purely a hint — it never gates interaction. The
/// overlays are driven by live scroll geometry (clip bounds + document frame):
/// they fade in when the content overflows and isn't scrolled to the bottom, and
/// out when it fits or reaches the bottom (no latch — they track scroll position).
/// All overlays are hit-transparent, so the indicator never blocks scrolling.
///
/// Create one per scroll view and retain it (typically a stored property on the
/// owning view controller). It inserts its hit-transparent overlays into the
/// scroll view's superview on the first layout — so it works whether the scroll
/// view is already in a hierarchy or mounted later — and removes them on `deinit`.
@MainActor
final class ScrollMoreIndicator {
    private static let logger = Logger(subsystem: "app.kernova", category: "ScrollMoreIndicator")

    /// Fractional-point tolerance so layout rounding doesn't leave the cue stuck a
    /// sub-pixel short of "at the bottom".
    private static let epsilon: CGFloat = 1.0

    private weak var scrollView: NSScrollView?
    private let fade = ScrollMoreFadeView()
    private let chevron = makeScrollMoreChevron()

    private var didInsertOverlays = false
    private var didFlash = false
    private var overlaysVisible = false

    /// Whether the content currently overflows below the visible area.
    ///
    /// Exposed for tests; production observes it only through the overlay state.
    private(set) var hasMoreBelow = false

    #if DEBUG
    /// The overlays in z-order — `[fade, chevron]`, chevron on top — once inserted,
    /// else empty.
    var overlaysForTesting: [NSView] { didInsertOverlays ? [fade, chevron] : [] }

    /// Whether the one-time scroller flash has latched.
    var hasFlashedForTesting: Bool { didFlash }
    #endif

    init(scrollView: NSScrollView) {
        self.scrollView = scrollView

        let clip = scrollView.contentView
        // Scrolling and clip resizes post bounds-changed; content growth posts the
        // document's frame-changed. Together they cover every geometry change.
        clip.postsBoundsChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(geometryChanged),
            name: NSView.boundsDidChangeNotification, object: clip)
        if let documentView = scrollView.documentView {
            center.addObserver(
                self, selector: #selector(geometryChanged),
                name: NSView.frameDidChangeNotification, object: documentView)
        }

        recompute()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // The overlays live in the scroll view's superview (a long-lived container),
        // so they're pulled here. Every owner is an @MainActor view controller whose
        // deallocation runs on the main thread, so `assumeIsolated` holds; this would
        // need revisiting if a future owner could be last-released off the main thread.
        MainActor.assumeIsolated {
            fade.removeFromSuperview()
            chevron.removeFromSuperview()
        }
    }

    @objc private func geometryChanged() {
        recompute()
    }

    private func recompute() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        insertOverlaysIfNeeded()

        // The clip view's bounds carry both the scroll offset (origin) and the
        // visible height (size). With the flipped clip view, origin.y runs from 0 at
        // the top to `docHeight - visibleHeight` at the bottom. Reading the clip
        // bounds avoids `documentVisibleRect`, which returns the whole document for a
        // view that isn't in a live window.
        let clipBounds = scrollView.contentView.bounds
        let docHeight = documentView.frame.height
        let overflows = docHeight > clipBounds.height + Self.epsilon
        let atBottom = clipBounds.maxY >= docHeight - Self.epsilon
        let moreBelow = overflows && !atBottom

        if moreBelow != hasMoreBelow {
            hasMoreBelow = moreBelow
            Self.logger.debug("More below: \(moreBelow, privacy: .public)")
        }
        setOverlaysVisible(moreBelow)

        // Flash the scroller once when overflowing content first appears. Deferred
        // because `flashScrollers()` is a no-op before the scroll view has drawn (the
        // cue must outlive the first layout pass).
        if overflows, !didFlash {
            didFlash = true
            DispatchQueue.main.async { [weak self] in self?.scrollView?.flashScrollers() }
        }
    }

    /// Adds the overlays to the scroll view's superview, pinned over its bottom edge,
    /// the first time both exist.
    ///
    /// The fade is added first, then the chevron above it, so the chevron is on top.
    /// They're pinned to the scroll view's edges (not scrolled), so the cue stays at
    /// the bottom.
    private func insertOverlaysIfNeeded() {
        guard !didInsertOverlays, let scrollView, let host = scrollView.superview else { return }
        didInsertOverlays = true

        fade.translatesAutoresizingMaskIntoConstraints = false
        fade.alphaValue = 0
        host.addSubview(fade, positioned: .above, relativeTo: scrollView)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.alphaValue = 0
        host.addSubview(chevron, positioned: .above, relativeTo: fade)

        NSLayoutConstraint.activate([
            fade.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            fade.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            fade.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            fade.heightAnchor.constraint(equalToConstant: scrollMoreFadeHeight),

            chevron.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            chevron.bottomAnchor.constraint(
                equalTo: scrollView.bottomAnchor, constant: -Spacing.small),
        ])
    }

    private func setOverlaysVisible(_ visible: Bool) {
        guard didInsertOverlays, visible != overlaysVisible else { return }
        overlaysVisible = visible
        let target: CGFloat = visible ? 1 : 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.animator().alphaValue = target
            chevron.animator().alphaValue = target
        }
    }
}

// MARK: - Overlays

/// Height of the bottom fade strip.
let scrollMoreFadeHeight: CGFloat = 36

/// A passive bottom-edge fade: the content dissolves into the sheet background as
/// it nears the bottom.
///
/// Drawn with an `NSGradient` in `draw(_:)` so it adapts to light/dark without
/// `CGColor` juggling. Because the resolved colors are baked into the draw, a
/// light/dark switch is force-redrawn via `viewDidChangeEffectiveAppearance`
/// (matching `SidebarVMRowCellView`). Hit-transparent so it never blocks scrolling.
private final class ScrollMoreFadeView: NSView {
    override var isOpaque: Bool { false }

    // RATIONALE: nil from hitTest drops the view from event routing so the scroll
    // view beneath still scrolls under the cursor.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // A custom `draw(_:)` bakes the resolved colors, so AppKit won't refresh it
        // on a light/dark switch on its own — mark it dirty.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let opaque = NSColor.windowBackgroundColor
        let clear = opaque.withAlphaComponent(0)
        // 90° runs bottom→top: opaque background at the bottom edge fading to clear,
        // so content shows through above and dissolves into the sheet at the bottom.
        NSGradient(starting: opaque, ending: clear)?.draw(in: bounds, angle: 90)
    }
}

/// A passive overlay container that lets clicks and scroll-wheel events fall
/// through to the content beneath.
///
/// Used for the chevron disc so it never intercepts the scrolling it's prompting.
private final class ScrollMoreHitTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Builds the chevron disc: a `chevron.down` on a small adaptive grey disc.
///
/// The disc is an `NSBox` so its fill/border are `NSColor`s that adapt to light/dark
/// automatically; the fill sits above the grouped-form cards' faint tint so the disc
/// reads against form content, and a hairline border defines its edge. Returned
/// hit-transparent so it never blocks scrolling.
@MainActor
private func makeScrollMoreChevron() -> NSView {
    let diameter: CGFloat = 28

    let disc = NSBox()
    disc.boxType = .custom
    disc.titlePosition = .noTitle
    disc.cornerRadius = diameter / 2
    disc.fillColor = .secondaryLabelColor.withAlphaComponent(0.2)
    disc.borderWidth = 1
    disc.borderColor = .separatorColor

    let chevron = NSImageView(
        image: .systemSymbol(
            "chevron.down", accessibilityDescription: "More content below — scroll to continue"))
    chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
    chevron.contentTintColor = .secondaryLabelColor
    chevron.translatesAutoresizingMaskIntoConstraints = false

    // RATIONALE: a custom NSBox sizes a `contentView` through the legacy autoresizing
    // path and collapses, so it's pinned as a chrome layer behind the chevron sibling
    // (the same pattern as `makeGroupedFormBox`).
    let container = ScrollMoreHitTransparentView()
    container.addFullSizeSubview(disc)
    container.addSubview(chevron)

    NSLayoutConstraint.activate([
        container.widthAnchor.constraint(equalToConstant: diameter),
        container.heightAnchor.constraint(equalToConstant: diameter),
        chevron.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        chevron.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])
    return container
}
