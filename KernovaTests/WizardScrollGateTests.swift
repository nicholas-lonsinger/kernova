import AppKit
import Testing

@testable import Kernova

@Suite("WizardScrollGate Tests")
@MainActor
struct WizardScrollGateTests {
    private static let viewportHeight: CGFloat = 200
    private static let width: CGFloat = 300

    /// Builds a scroll view with an explicitly-framed flipped clip and document
    /// view, so the gate sees deterministic geometry without depending on a
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

    @Test("Gate stays satisfied for content that fits the viewport")
    func satisfiedWhenContentFits() {
        let scrollView = makeScrollView(documentHeight: 50)

        var reports: [Bool] = []
        let gate = WizardScrollGate(scrollView: scrollView) { reports.append($0) }
        _ = gate  // retain for the duration of the test

        // No overflow → the gate never engages (the satisfied default holds).
        #expect(reports.isEmpty)
    }

    @Test("Gate engages for overflowing content and releases at the bottom")
    func engagesThenReleasesOnScrollToBottom() {
        let scrollView = makeScrollView(documentHeight: 1000)

        var reports: [Bool] = []
        let gate = WizardScrollGate(scrollView: scrollView) { reports.append($0) }
        _ = gate

        // Overflows and starts at the top → engaged (unsatisfied).
        #expect(reports == [false])

        // Scroll to the bottom → released (satisfied).
        let maxScroll = 1000 - Self.viewportHeight
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxScroll))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        #expect(reports == [false, true])
    }

    @Test("Gate latches satisfied: scrolling back up does not re-engage it")
    func staysSatisfiedAfterScrollingBackUp() {
        let scrollView = makeScrollView(documentHeight: 1000)

        var reports: [Bool] = []
        let gate = WizardScrollGate(scrollView: scrollView) { reports.append($0) }
        _ = gate

        let maxScroll = 1000 - Self.viewportHeight
        // Down to the bottom (satisfies), then back to the top.
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxScroll))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // Engaged once, satisfied once — no re-engage on the way back up.
        #expect(reports == [false, true])
    }

    @Test("Gate re-evaluates when content grows in place")
    func reevaluatesWhenContentGrows() {
        let scrollView = makeScrollView(documentHeight: 50)

        var reports: [Bool] = []
        let gate = WizardScrollGate(scrollView: scrollView) { reports.append($0) }
        _ = gate
        #expect(reports.isEmpty)  // fits

        // Grow past the viewport (mirrors a step rebuilding its conditional section).
        scrollView.documentView?.setFrameSize(NSSize(width: Self.width, height: 1000))

        #expect(reports == [false])  // now overflows, still at the top
    }
}
