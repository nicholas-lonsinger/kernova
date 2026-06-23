import AppKit
import os

/// Selects which "more below" cues a ``ScrollMoreIndicator`` shows.
///
/// The two cues — persistent `overlays` (chevron disc + bottom fade) and a
/// one-time scroller `flash` — are independent, so a surface can opt into a
/// light flash-only hint without the overlay chrome.
struct ScrollMoreCues: OptionSet, Sendable {
    let rawValue: Int

    /// The persistent chevron disc and bottom fade that track scroll position.
    static let overlays = ScrollMoreCues(rawValue: 1 << 0)
    /// A one-time scroller flash when overflowing content first appears.
    static let flash = ScrollMoreCues(rawValue: 1 << 1)

    /// Both cues — the default for the creation wizard and the delete-VM sheet.
    static let all: ScrollMoreCues = [.overlays, .flash]
}

/// Shows the standard "there's more content below" cues over a vertically
/// scrolling view.
///
/// Two independent cues, selected via ``ScrollMoreCues`` at construction:
/// persistent `overlays` — a down-chevron disc and a soft bottom fade that track
/// scroll position — and a one-time scroller `flash` when overflowing content
/// first appears. ``ScrollMoreCues/all`` (the default) shows both.
///
/// Shared by the creation wizard's steps and the delete-VM sheet (both default
/// to `.all`), and the VM settings pane (`.flash` only — a light cue that needs
/// no overlays hosted in its `NSStackView` root). It is purely a hint — it never
/// gates interaction. The overlays are driven by live scroll geometry (clip
/// bounds + document frame): they fade in when the content overflows and isn't
/// scrolled to the bottom, and out when it fits or reaches the bottom (no latch —
/// they track scroll position). All overlays are hit-transparent, so the
/// indicator never blocks scrolling.
///
/// Create one per scroll view and retain it (typically a stored property on the
/// owning view controller). It inserts its hit-transparent overlays into the
/// scroll view's superview on the first layout — so it works whether the scroll
/// view is already in a hierarchy or mounted later — and removes them on `deinit`.
///
/// - Precondition: the scroll view uses a top-anchored `FlippedClipView` and has
///   its `documentView` set before construction. The at-bottom math reads the
///   clip's flipped bounds (origin 0 at the top), and content-growth tracking
///   binds to the document view here in `init`. Every grouped-form scroll view
///   (`makeGroupedFormScrollView`) and the delete-VM sheet satisfy both; the
///   initializer asserts them so a future misuse trips in Debug.
@MainActor
final class ScrollMoreIndicator {
    private static let logger = Logger(subsystem: "app.kernova", category: "ScrollMoreIndicator")

    /// Fractional-point tolerance so layout rounding doesn't leave the cue stuck a
    /// sub-pixel short of "at the bottom".
    private static let epsilon: CGFloat = 1.0

    /// Height of the bottom fade strip.
    private static let fadeHeight: CGFloat = 36

    private weak var scrollView: NSScrollView?
    private let cues: ScrollMoreCues
    private let fade = ScrollMoreFadeView()
    private let chevron = makeScrollMoreChevron()

    private var didInsertOverlays = false
    private var didFlash = false

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

    /// Creates an indicator for `scrollView`, showing the cues named by `cues`
    /// (default ``ScrollMoreCues/all``; pass `.flash` for a flash-only hint with
    /// no overlay chrome).
    init(scrollView: NSScrollView, cues: ScrollMoreCues = .all) {
        self.scrollView = scrollView
        self.cues = cues

        // See the type's `- Precondition`: the at-bottom math assumes a flipped
        // clip, and content-growth tracking binds to the document view below.
        assert(
            scrollView.contentView.isFlipped,
            "ScrollMoreIndicator requires a top-anchored FlippedClipView; a standard NSClipView inverts the at-bottom calculation."
        )
        assert(
            scrollView.documentView != nil,
            "ScrollMoreIndicator requires scrollView.documentView to be set before construction; content-growth tracking binds to it here."
        )

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
        // not the scroll view itself, so removing the scroll view doesn't take them —
        // they're pulled here instead. Cleanup is therefore bound to this object's
        // deallocation: an owner kept alive past its on-screen life would leave its
        // overlays parented in the shared container. Every current owner is a step /
        // sheet view controller rebuilt fresh and released synchronously on each
        // transition, so they don't linger. Those owners are @MainActor controllers
        // whose deallocation runs on the main thread, so `assumeIsolated` holds; this
        // would need revisiting if a future owner could be last-released off the main
        // thread, or cached across transitions.
        MainActor.assumeIsolated {
            fade.removeFromSuperview()
            chevron.removeFromSuperview()
        }
    }

    /// Re-arms the one-time scroller flash and re-evaluates overflow, so the
    /// scroller flashes again the next time the content overflows.
    ///
    /// The flash latches after firing once — it's a per-appearance cue, sized for
    /// a short-lived owner (a wizard step or sheet rebuilt per presentation). The
    /// settings pane instead reuses one indicator across VM switches, so it calls
    /// this on each rebind: the just-rebuilt form is re-measured here and an
    /// overflowing one flashes, so every overflowing pane gets the cue rather than
    /// only the first shown in the session. A pane that now fits doesn't flash.
    func rearmFlash() {
        didFlash = false
        recompute()
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
            setOverlaysVisible(moreBelow, animated: true)
        }

        // Flash the scroller once when overflowing content first appears. Deferred to
        // the next main-actor hop because `flashScrollers()` is a no-op before the
        // scroll view has drawn.
        //
        // RATIONALE: the flash is a supplementary cue. When overlays are shown (the
        // default) they're the primary affordance, so a flash that no-ops because
        // geometry settled before the view was on screen (e.g. a sheet laid out before
        // presentation) is acceptable — the chevron and fade still show. In flash-only
        // mode the native scroller is the fallback. A `Task { @MainActor }` hop, not
        // `DispatchQueue.main.async`, matches the codebase's strict-concurrency
        // convention for main-thread re-dispatch.
        if cues.contains(.flash), overflows, !didFlash {
            didFlash = true
            Self.logger.debug(
                "Flashing scroller (window present: \(scrollView.window != nil, privacy: .public))")
            Task { @MainActor [weak self] in self?.scrollView?.flashScrollers() }
        }
    }

    /// Adds the overlays to the scroll view's superview, pinned over its bottom edge,
    /// the first time both exist.
    ///
    /// No-op unless the `overlays` cue is requested. The fade is added first, then the
    /// chevron above it, so the chevron is on top. They're pinned to the scroll view's
    /// edges (not scrolled), so the cue stays at the bottom.
    private func insertOverlaysIfNeeded() {
        guard cues.contains(.overlays) else { return }
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
            fade.heightAnchor.constraint(equalToConstant: Self.fadeHeight),

            chevron.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            chevron.bottomAnchor.constraint(
                equalTo: scrollView.bottomAnchor, constant: -Spacing.small),
        ])

        // `recompute()` may have already settled `hasMoreBelow` before the scroll
        // view had a superview to host the overlays. Reflect that state now that they
        // exist — instantly, since they're appearing for the first time from alpha 0.
        setOverlaysVisible(hasMoreBelow, animated: false)
    }

    /// Fades (or, when `animated` is false, snaps) both overlays to match `visible`.
    ///
    /// `recompute()` calls this only when `hasMoreBelow` actually changes, so the
    /// visible state is derived from that single signal — no separate "currently
    /// visible" flag to keep in sync.
    private func setOverlaysVisible(_ visible: Bool, animated: Bool) {
        guard didInsertOverlays else { return }
        let target: CGFloat = visible ? 1 : 0
        guard animated else {
            fade.alphaValue = target
            chevron.alphaValue = target
            return
        }
        animateFade(fade, chevron, to: target)
    }
}

// MARK: - Overlays

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
    // Decorative: the cue is a redundant visual hint over already-navigable content,
    // and `hitTest` suppresses only pointer events, not the accessibility tree. Drop
    // it from VoiceOver so it isn't announced as a focusable element with no action.
    chevron.setAccessibilityElement(false)

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
