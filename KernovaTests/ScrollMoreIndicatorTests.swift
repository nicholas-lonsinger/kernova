import AppKit
import Testing

@testable import Kernova

@Suite("ScrollMoreIndicator Tests", .admissionGated)
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

    /// A scroll view already hosted in an on-screen window.
    ///
    /// The flash only fires against a visible window, so every flash assertion
    /// builds its scroll view through this rather than ``makeScrollView(documentHeight:)``.
    private func makeShownScrollView(documentHeight: CGFloat) -> (NSScrollView, NSWindow) {
        let scrollView = makeScrollView(documentHeight: documentHeight)
        return (scrollView, showInTestWindow(scrollView))
    }

    @Test("Latches the one-time scroller flash on overflow, not when content fits")
    func flashLatch() {
        let (fitting, fittingWindow) = makeShownScrollView(documentHeight: 50)
        defer { fittingWindow.orderOut(nil) }
        let fits = ScrollMoreIndicator(scrollView: fitting)
        #expect(fits.flashCountForTesting == 0)

        let (overflowing, overflowingWindow) = makeShownScrollView(documentHeight: 1000)
        defer { overflowingWindow.orderOut(nil) }
        let overflows = ScrollMoreIndicator(scrollView: overflowing)
        #expect(overflows.flashCountForTesting == 1)
    }

    /// The latch has to survive until there is a visible window to spend it on.
    ///
    /// The cue is an animated fade-in, so one fired before the window is ordered
    /// on screen is spent where nobody can see it — the pane's first visit then
    /// shows a scroller that only fades out, unlike every later visit.
    @Test("Holds the flash until the scroller has a visible window")
    func flashWaitsForAVisibleWindow() {
        let scrollView = makeScrollView(documentHeight: 1000)
        let indicator = ScrollMoreIndicator(scrollView: scrollView, cues: .flash)
        #expect(indicator.flashCountForTesting == 0)

        let window = showInTestWindow(scrollView)
        defer { window.orderOut(nil) }
        indicator.rearmFlash()
        #expect(indicator.flashCountForTesting == 1)
    }

    @Test("Flash-only cue flashes the scroller but inserts no overlays, even once mounted")
    func flashOnlyCueSkipsOverlays() {
        // The settings pane opts into `.flash` alone: it should still latch the
        // one-time scroller flash on overflow, but never build or host the
        // chevron/fade overlays (its root is an NSStackView).
        let (scrollView, window) = makeShownScrollView(documentHeight: 1000)
        defer { window.orderOut(nil) }
        let indicator = ScrollMoreIndicator(scrollView: scrollView, cues: .flash)
        #expect(indicator.flashCountForTesting == 1)

        // Mounted (the window's content view) + a geometry notification would
        // normally lazily insert overlays; with `.flash` only they must stay absent.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(indicator.overlaysForTesting.isEmpty)
    }

    @Test("Overlays-only cue inserts overlays but never flashes the scroller")
    func overlaysOnlyCueSkipsFlash() {
        let scrollView = makeScrollView(documentHeight: 1000)
        let indicator = ScrollMoreIndicator(scrollView: scrollView, cues: .overlays)
        #expect(indicator.flashCountForTesting == 0)

        let host = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight))
        host.addSubview(scrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(indicator.overlaysForTesting.count == 2)
    }

    /// A surface whose arrivals are cued by an explicit `rearmFlash()` opts out
    /// of the born-armed flash: fired from pre-appearance layout churn, it would
    /// spend the fade-in off screen and leave the arrival cue a scroller already
    /// at full alpha.
    @Test("An indicator born spent holds the flash for an explicit rearm")
    func bornSpentFlashWaitsForRearm() {
        let (scrollView, window) = makeShownScrollView(documentHeight: 1000)
        defer { window.orderOut(nil) }
        let indicator = ScrollMoreIndicator(
            scrollView: scrollView, cues: .flash, flashOnFirstOverflow: false)
        // Overflowing content against a visible window — the born-armed
        // configuration flashes here; born spent must not.
        #expect(indicator.flashCountForTesting == 0)

        // Nor from later geometry churn (a pane laying out before it is shown).
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 1))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        #expect(indicator.flashCountForTesting == 0)

        // The arrival cue is the first flash anyone gets.
        indicator.rearmFlash()
        #expect(indicator.flashCountForTesting == 1)
    }

    /// A scroll view with an explicit scroller style, so the veil assertions do
    /// not depend on the host's "Show scroll bars" setting.
    private func makeScrollView(documentHeight: CGFloat, scrollerStyle: NSScroller.Style)
        -> NSScrollView
    {
        let scrollView = makeScrollView(documentHeight: documentHeight)
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = scrollerStyle
        return scrollView
    }

    /// AppKit presents a virgin overlay scroller already shown, so an
    /// arrival-cued surface would meet a solid scroller on its first-ever frame.
    ///
    /// The reveal can't animate on a never-presented layer. The indicator veils
    /// the scroller behind zero view alpha at init; the first executed flash
    /// animates it off.
    @Test("Born-spent init veils an overlay scroller; born-armed leaves it alone")
    func bornSpentVeilsOverlayScroller() throws {
        let veiled = makeScrollView(documentHeight: 1000, scrollerStyle: .overlay)
        let veiledScroller = try #require(veiled.verticalScroller)
        _ = ScrollMoreIndicator(scrollView: veiled, cues: .flash, flashOnFirstOverflow: false)
        #expect(veiledScroller.alphaValue == 0)

        // The born-armed default serves surfaces whose first presentation is a
        // brand-new window, where the system reveal reads fine — no veil.
        let stock = makeScrollView(documentHeight: 1000, scrollerStyle: .overlay)
        let stockScroller = try #require(stock.verticalScroller)
        _ = ScrollMoreIndicator(scrollView: stock, cues: .flash)
        #expect(stockScroller.alphaValue == 1)
    }

    /// A legacy scroller is a persistent control rather than a transient
    /// overlay, so veiling one would hide a scrollbar meant to stay on screen —
    /// what a reader with "Show scroll bars: Always" would see.
    @Test("A legacy scroller is never veiled")
    func legacyScrollerIsNotVeiled() throws {
        let scrollView = makeScrollView(documentHeight: 1000, scrollerStyle: .legacy)
        let scroller = try #require(scrollView.verticalScroller)
        _ = ScrollMoreIndicator(scrollView: scrollView, cues: .flash, flashOnFirstOverflow: false)
        #expect(scroller.alphaValue == 1)
    }

    /// A flash is the only thing that lifts the veil, so a flash-less indicator
    /// applies none.
    ///
    /// Veiled with nothing to unveil it, the scroller would stay invisible for the
    /// scroll view's whole life.
    @Test("An indicator without the flash cue never veils the scroller")
    func flashlessIndicatorIsNotVeiled() throws {
        let scrollView = makeScrollView(documentHeight: 1000, scrollerStyle: .overlay)
        let scroller = try #require(scrollView.verticalScroller)
        _ = ScrollMoreIndicator(
            scrollView: scrollView, cues: .overlays, flashOnFirstOverflow: false)
        #expect(scroller.alphaValue == 1)
    }

    @Test("rearmFlash re-arms the one-time flash for a reused indicator")
    func rearmFlashReevaluates() {
        // Mirrors the settings pane reusing one indicator across VM switches.
        let (scrollView, window) = makeShownScrollView(documentHeight: 1000)
        defer { window.orderOut(nil) }
        let indicator = ScrollMoreIndicator(scrollView: scrollView, cues: .flash)
        #expect(indicator.flashCountForTesting == 1)  // flashed on first overflow

        // Switching to a shorter form that fits, then re-arming, clears the latch
        // with nothing to spend it on — so the count holds.
        scrollView.documentView?.setFrameSize(NSSize(width: Self.width, height: 50))
        indicator.rearmFlash()
        #expect(indicator.flashCountForTesting == 1)

        // A subsequent overflow re-flashes, proving the latch was genuinely cleared
        // (a never-reset latch would have left the count at 1).
        scrollView.documentView?.setFrameSize(NSSize(width: Self.width, height: 1000))
        #expect(indicator.flashCountForTesting == 2)
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
