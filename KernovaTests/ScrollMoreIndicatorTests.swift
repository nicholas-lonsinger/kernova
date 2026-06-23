import AppKit
import Testing

@testable import Kernova

@Suite("ScrollMoreIndicator Tests")
@MainActor
struct ScrollMoreIndicatorTests {
    private static let viewportHeight: CGFloat = 200
    private static let width: CGFloat = 300

    /// Builds a scroll view with an explicitly-framed flipped clip and document
    /// view, so the indicator sees deterministic geometry without depending on a
    /// window/display cycle to resolve Auto Layout.
    ///
    /// Mirrors the production setup (top-anchored `FlippedClipView`); only the
    /// sizing is frame-driven here.
    private func makeScrollView(documentHeight: CGFloat) -> NSScrollView {
        let frame = NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight)
        let scrollView = NSScrollView(frame: frame)
        scrollView.contentView = FlippedClipView(frame: frame)
        scrollView.documentView = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: documentHeight))
        scrollView.tile()
        scrollView.reflectScrolledClipView(scrollView.contentView)
        return scrollView
    }

    @Test("No cue when content fits the viewport")
    func noCueWhenContentFits() {
        let scrollView = makeScrollView(documentHeight: 50)
        let indicator = ScrollMoreIndicator(scrollView: scrollView)
        #expect(indicator.hasMoreBelow == false)
    }

    @Test("Cue shows when content overflows and is at the top")
    func cueWhenOverflowingAtTop() {
        let scrollView = makeScrollView(documentHeight: 1000)
        let indicator = ScrollMoreIndicator(scrollView: scrollView)
        #expect(indicator.hasMoreBelow == true)
    }

    @Test("Cue clears at the bottom and returns on scroll up (no latch)")
    func cueTracksScrollPosition() {
        let scrollView = makeScrollView(documentHeight: 1000)
        let indicator = ScrollMoreIndicator(scrollView: scrollView)
        #expect(indicator.hasMoreBelow == true)

        let maxScroll = 1000 - Self.viewportHeight
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxScroll))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(indicator.hasMoreBelow == false)

        // Unlike the old gate, the hint is not sticky — scrolling back up re-shows it.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(indicator.hasMoreBelow == true)
    }

    @Test("Inserts the fade + chevron lazily once the scroll view is mounted, chevron on top")
    func lazilyInsertsOverlaysOnMount() {
        // Production creates the indicator in loadView, before the scroll view is in
        // any hierarchy — so at init there is no superview and nothing is inserted.
        let scrollView = makeScrollView(documentHeight: 1000)
        let indicator = ScrollMoreIndicator(scrollView: scrollView)
        #expect(indicator.overlaysForTesting.isEmpty)

        // Mount it, then fire a geometry notification: the overlays insert into the
        // superview, the chevron above the fade.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight))
        host.addSubview(scrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let overlays = indicator.overlaysForTesting
        #expect(overlays.count == 2)
        #expect(overlays.allSatisfy { $0.superview === host })
        let fadeIndex = host.subviews.firstIndex { $0 === overlays[0] }
        let chevronIndex = host.subviews.firstIndex { $0 === overlays[1] }
        #expect(fadeIndex != nil && chevronIndex != nil)
        if let f = fadeIndex, let c = chevronIndex { #expect(c > f) }
    }

    @Test("Overlays render visible (alpha 1) on overflow at mount, hidden (alpha 0) when content fits")
    func overlaysReflectOverflowAlphaAtMount() {
        // Mounted + overflowing: the insert path applies the settled state instantly,
        // so the overlays are fully opaque. Guards against a future edit inverting the
        // alpha target (e.g. `visible ? 0 : 1`) or dropping the visibility call — the
        // geometry flag alone wouldn't catch either.
        let overflowing = makeScrollView(documentHeight: 1000)
        let overflowIndicator = ScrollMoreIndicator(scrollView: overflowing)
        let overflowHost = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight))
        overflowHost.addSubview(overflowing)
        overflowing.contentView.scroll(to: NSPoint(x: 0, y: 1))
        overflowing.reflectScrolledClipView(overflowing.contentView)

        let visibleOverlays = overflowIndicator.overlaysForTesting
        #expect(visibleOverlays.count == 2)
        #expect(visibleOverlays.allSatisfy { $0.alphaValue == 1 })

        // Mounted but content fits: overlays still insert, but stay fully transparent.
        let fitting = makeScrollView(documentHeight: 50)
        let fitIndicator = ScrollMoreIndicator(scrollView: fitting)
        let fitHost = NSView(
            frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight))
        fitHost.addSubview(fitting)
        // A still-fitting document resize fires frameDidChange, driving the insert.
        fitting.documentView?.setFrameSize(NSSize(width: Self.width, height: 60))

        let hiddenOverlays = fitIndicator.overlaysForTesting
        #expect(hiddenOverlays.count == 2)
        #expect(hiddenOverlays.allSatisfy { $0.alphaValue == 0 })
    }

    @Test("Latches the one-time scroller flash on overflow, not when content fits")
    func flashLatch() {
        let fits = ScrollMoreIndicator(scrollView: makeScrollView(documentHeight: 50))
        #expect(fits.hasFlashedForTesting == false)

        let overflows = ScrollMoreIndicator(scrollView: makeScrollView(documentHeight: 1000))
        #expect(overflows.hasFlashedForTesting == true)
    }

    @Test("Flash-only cue flashes the scroller but inserts no overlays, even once mounted")
    func flashOnlyCueSkipsOverlays() {
        // The settings pane opts into `.flash` alone: it should still latch the
        // one-time scroller flash on overflow, but never build or host the
        // chevron/fade overlays (its root is an NSStackView).
        let scrollView = makeScrollView(documentHeight: 1000)
        let indicator = ScrollMoreIndicator(scrollView: scrollView, cues: .flash)
        #expect(indicator.hasFlashedForTesting == true)

        // Mount + a geometry notification would normally lazily insert overlays;
        // with `.flash` only they must stay absent.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight))
        host.addSubview(scrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(indicator.overlaysForTesting.isEmpty)
    }

    @Test("Overlays-only cue inserts overlays but never flashes the scroller")
    func overlaysOnlyCueSkipsFlash() {
        let scrollView = makeScrollView(documentHeight: 1000)
        let indicator = ScrollMoreIndicator(scrollView: scrollView, cues: .overlays)
        #expect(indicator.hasFlashedForTesting == false)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight))
        host.addSubview(scrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(indicator.overlaysForTesting.count == 2)
    }

    @Test("rearmFlash re-arms the one-time flash for a reused indicator")
    func rearmFlashReevaluates() {
        // Mirrors the settings pane reusing one indicator across VM switches.
        let scrollView = makeScrollView(documentHeight: 1000)
        let indicator = ScrollMoreIndicator(scrollView: scrollView, cues: .flash)
        #expect(indicator.hasFlashedForTesting == true)  // flashed on first overflow

        // Switching to a shorter form that fits, then re-arming, clears the latch
        // and — since nothing overflows now — leaves it un-flashed.
        scrollView.documentView?.setFrameSize(NSSize(width: Self.width, height: 50))
        indicator.rearmFlash()
        #expect(indicator.hasFlashedForTesting == false)

        // A subsequent overflow re-flashes, proving the latch was genuinely cleared
        // (a never-reset latch would have stayed `true` throughout).
        scrollView.documentView?.setFrameSize(NSSize(width: Self.width, height: 1000))
        #expect(indicator.hasFlashedForTesting == true)
    }

    @Test("Re-evaluates when content grows in place")
    func reevaluatesWhenContentGrows() {
        let scrollView = makeScrollView(documentHeight: 50)
        let indicator = ScrollMoreIndicator(scrollView: scrollView)
        #expect(indicator.hasMoreBelow == false)

        // Mirrors a step rebuilding its conditional section to overflow.
        scrollView.documentView?.setFrameSize(NSSize(width: Self.width, height: 1000))
        #expect(indicator.hasMoreBelow == true)
    }

    @Test("Pulls its overlays out of the host superview when deallocated")
    func deinitRemovesOverlays() {
        // The overlays live in the scroll view's *superview*, not the scroll view,
        // so they outlive the scroll view's removal and are torn down only in the
        // indicator's `deinit`. Hold strong refs to the overlays so they survive
        // the indicator's deallocation and we can assert they were unparented (not
        // merely collected).
        let scrollView = makeScrollView(documentHeight: 1000)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight))
        host.addSubview(scrollView)

        var overlays: [NSView] = []
        do {
            let indicator = ScrollMoreIndicator(scrollView: scrollView)
            // Mount-driven insert: a geometry notification parents the overlays into
            // the host.
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            overlays = indicator.overlaysForTesting
            #expect(overlays.count == 2)
            #expect(overlays.allSatisfy { $0.superview === host })
        }
        // The indicator is released at the end of the `do` scope; its `deinit`
        // removes both overlays from the host.
        #expect(overlays.allSatisfy { $0.superview == nil })
    }
}
