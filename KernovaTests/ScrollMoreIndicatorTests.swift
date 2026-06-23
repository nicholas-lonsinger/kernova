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

    @Test("Inserts its two overlays into the scroll view's superview")
    func insertsOverlaysIntoSuperview() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.viewportHeight))
        let scrollView = makeScrollView(documentHeight: 1000)
        host.addSubview(scrollView)
        #expect(host.subviews.count == 1)

        let indicator = ScrollMoreIndicator(scrollView: scrollView)
        // The chevron disc + fade are layered above the scroll view on first layout.
        #expect(host.subviews.count == 3)
        #expect(host.subviews.last !== scrollView)
        _ = indicator
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
