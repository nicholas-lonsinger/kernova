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

    @Test("Latches the one-time scroller flash on overflow, not when content fits")
    func flashLatch() {
        let fits = ScrollMoreIndicator(scrollView: makeScrollView(documentHeight: 50))
        #expect(fits.hasFlashedForTesting == false)

        let overflows = ScrollMoreIndicator(scrollView: makeScrollView(documentHeight: 1000))
        #expect(overflows.hasFlashedForTesting == true)
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
}
