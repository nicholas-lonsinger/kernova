import AppKit
import os

/// Selects which "more below" cues a ``ScrollMoreIndicator`` shows.
///
/// The two cues are independent, so a surface can opt into a light flash-only
/// hint without the overlay chrome.
struct ScrollMoreCues: OptionSet, Sendable {
    let rawValue: Int

    /// The persistent chevron disc and bottom fade that track scroll position.
    static let overlays = ScrollMoreCues(rawValue: 1 << 0)
    /// A one-time scroller flash when overflowing content first appears.
    static let flash = ScrollMoreCues(rawValue: 1 << 1)

    /// Both cues.
    static let all: ScrollMoreCues = [.overlays, .flash]
}

/// Shows the standard "there's more content below" cues over a vertically
/// scrolling view.
///
/// Create one per scroll view and retain it: it inserts its hit-transparent
/// overlays into the scroll view's superview on first layout and removes them on
/// `deinit`.
///
/// - Precondition: a top-anchored `FlippedClipView` with `documentView` set.
@MainActor
final class ScrollMoreIndicator {
    private static let logger = Logger(subsystem: "app.kernova", category: "ScrollMoreIndicator")

    /// Fractional-point tolerance so layout rounding doesn't leave the cue stuck a
    /// sub-pixel short of "at the bottom".
    private static let epsilon: CGFloat = 1.0

    /// Height of the bottom fade strip.
    private static let fadeHeight: CGFloat = 36

    /// How long the veiled scroller takes to fade in, matching the system
    /// scroller reveal it stands in for.
    private static let unveilDuration: TimeInterval = 0.3

    private weak var scrollView: NSScrollView?
    private let cues: ScrollMoreCues
    private let fade = ScrollMoreFadeView()
    private let chevron = makeScrollMoreChevron()

    private var didInsertOverlays = false
    private var didFlash = false

    /// Whether the content currently overflows below the visible area.
    private(set) var hasMoreBelow = false

    #if DEBUG
    /// The overlays in z-order — `[fade, chevron]`, chevron on top — once inserted,
    /// else empty.
    var overlaysForTesting: [NSView] { didInsertOverlays ? [fade, chevron] : [] }

    /// How many times the flash has fired.
    ///
    /// The only signal that separates a flash from a spent latch: `didFlash` also
    /// reads spent for one held at birth by `flashOnFirstOverflow: false`, and a
    /// re-arm over still-overflowing content re-latches before a test can look.
    private(set) var flashCountForTesting = 0
    #endif

    /// Creates an indicator for `scrollView`, showing the cues named by `cues`.
    ///
    /// `flashOnFirstOverflow` arms the one-time flash at birth, which suits a
    /// surface built fresh per appearance (a wizard step, a sheet) where the
    /// first overflow against a visible window *is* the arrival. Pass `false`
    /// for a surface whose arrivals are cued by an explicit ``rearmFlash()``:
    /// the flash then waits for that cue, and an overlay scroller is held at
    /// zero alpha until the first one executes.
    init(
        scrollView: NSScrollView, cues: ScrollMoreCues = .all, flashOnFirstOverflow: Bool = true
    ) {
        self.scrollView = scrollView
        self.cues = cues
        self.didFlash = !flashOnFirstOverflow

        // AppKit reveals an overlay scroller when content first fills it, and a
        // reveal applied to a layer that has never been presented takes effect
        // instantly rather than animating. A surface reaching the screen for the
        // first time therefore draws its scroller already solid, and the arriving
        // flash has only its fade-out left to play. Hold the scroller at zero
        // alpha from here so that first frame carries no scroller at all; the
        // first flash to execute animates it in (see `recompute`).
        //
        // A flash is the only thing that lifts the veil, so an indicator without
        // that cue applies none. Overlay scrollers only: a legacy scroller is a
        // persistent control, and veiling it would hide a scrollbar meant to stay
        // on screen.
        if !flashOnFirstOverflow, cues.contains(.flash), scrollView.scrollerStyle == .overlay {
            scrollView.verticalScroller?.alphaValue = 0
        }

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
        // The overlays live in the scroll view's superview, not the scroll view
        // itself, so removing the scroll view doesn't take them — they're pulled
        // here instead, and an owner kept alive past its on-screen life would leave
        // them parented in the shared container. Every owner is a @MainActor
        // controller released on the main thread, so `assumeIsolated` holds.
        MainActor.assumeIsolated {
            fade.removeFromSuperview()
            chevron.removeFromSuperview()
        }
    }

    /// Re-arms the one-time scroller flash and re-evaluates overflow, so the
    /// scroller flashes again the next time the content overflows.
    ///
    /// The flash latches after firing once, so an owner that outlives a single
    /// appearance — the settings pane, reused across VM switches — must call this
    /// on each rebind or only its first overflowing content gets the cue.
    func rearmFlash() {
        didFlash = false
        recompute()
    }

    /// Animates off the zero-alpha veil the initializer may have put on the
    /// scroller, so the flash that follows reads as a fade-in.
    ///
    /// A no-op once the veil is gone, which is every flash after the first: from
    /// then on the scroller rests hidden and AppKit's own reveal animates it.
    private func unveilScroller() {
        guard let scroller = scrollView?.verticalScroller, scroller.alphaValue < 1 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.unveilDuration
            scroller.animator().alphaValue = 1
        }
    }

    @objc private func geometryChanged() {
        recompute()
    }

    private func recompute() {
        guard let scrollView, let documentView = scrollView.documentView else { return }
        insertOverlaysIfNeeded()

        // The clip view's bounds carry both the scroll offset and the visible
        // height. Reading them avoids `documentVisibleRect`, which returns the
        // whole document for a view that isn't in a live window.
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

        // Flash the scroller once when overflowing content first appears, and only
        // with a window to animate against — see `canFlash`. Deferred to the next
        // main-actor hop because `flashScrollers()` is a no-op before the scroll
        // view has drawn.
        if cues.contains(.flash), overflows, !didFlash, canFlash {
            didFlash = true
            #if DEBUG
            flashCountForTesting += 1
            #endif
            Self.logger.debug("Flashing scroller")
            Task { @MainActor [weak self] in
                guard let scrollView = self?.scrollView else { return }
                self?.unveilScroller()
                scrollView.flashScrollers()
            }
        }
    }

    /// Whether the scroller has an on-screen window to animate against.
    ///
    /// `flashScrollers()` fades the scroller in, holds it, then fades it out.
    /// Run before the window is ordered on screen, the fade-in plays where
    /// nobody can see it and the user meets the scroller already at full alpha
    /// with only the fade-out left — so a surface's first visit looks unlike
    /// every later one. Staying armed until there is a visible window means the
    /// next geometry change or ``rearmFlash()`` shows the whole animation.
    private var canFlash: Bool { scrollView?.window?.isVisible == true }

    /// Adds the overlays to the scroll view's superview, pinned over its bottom
    /// edge, the first time both exist.
    ///
    /// They are pinned to the scroll view's edges rather than scrolled, so the cue
    /// stays at the bottom.
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
        // view had a superview to host the overlays; reflect that state now.
        setOverlaysVisible(hasMoreBelow, animated: false)
    }

    /// Fades (or, when `animated` is false, snaps) both overlays to match `visible`.
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
/// Hit-transparent, so it never blocks scrolling.
private final class ScrollMoreFadeView: NSView {
    override var isOpaque: Bool { false }

    // nil from hitTest drops the view from event routing so the scroll view
    // beneath still scrolls under the cursor.
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
private final class ScrollMoreHitTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Builds the chevron disc: a `chevron.down` on a small adaptive grey disc.
///
/// The disc is an `NSBox`, so its fill/border are `NSColor`s that adapt to
/// light/dark automatically. Returned hit-transparent.
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
    // `hitTest` suppresses only pointer events, not the accessibility tree. Drop the
    // decorative cue from VoiceOver so it isn't announced as a focusable element
    // with no action.
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
