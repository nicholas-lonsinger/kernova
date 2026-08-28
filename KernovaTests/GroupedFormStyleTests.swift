import AppKit
import Testing

@testable import Kernova

@Suite("GroupedFormStyle Tests")
@MainActor
struct GroupedFormStyleTests {
    /// A scroll view laid out at `width`, with a content view tall enough to
    /// scroll and no width of its own.
    ///
    /// Measurements are taken against the document view rather than the scroll
    /// view: the scroller style decides whether the two are the same width.
    private func laidOutScrollView(
        width: CGFloat, maxContentWidth: CGFloat?
    ) -> (documentWidth: CGFloat, content: NSView) {
        let content = NSView()
        content.heightAnchor.constraint(equalToConstant: 200).isActive = true
        let scrollView = makeGroupedFormScrollView(
            documentView: content, maxContentWidth: maxContentWidth)
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: 300)
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView.documentView?.frame.width ?? 0, content)
    }

    @Test("A viewport wider than the cap holds the content at the column width, centered")
    func wideViewportCapsAndCentersContent() {
        let (documentWidth, content) = laidOutScrollView(
            width: 1200, maxContentWidth: GroupedFormStyle.columnWidth)

        #expect(content.frame.width == GroupedFormStyle.columnWidth)
        #expect(content.frame.midX == documentWidth / 2)
    }

    @Test("A viewport narrower than the cap fills it, minus the side insets")
    func narrowViewportFillsMinusInsets() {
        let (documentWidth, content) = laidOutScrollView(
            width: 400, maxContentWidth: GroupedFormStyle.columnWidth)

        #expect(content.frame.width == documentWidth - 2 * GroupedFormStyle.contentSideInset)
    }

    @Test("Without a cap the content fills any viewport, minus the side insets")
    func uncappedContentFillsTheViewport() {
        let (documentWidth, content) = laidOutScrollView(width: 1200, maxContentWidth: nil)

        #expect(content.frame.width == documentWidth - 2 * GroupedFormStyle.contentSideInset)
    }

    @Test("A card's hairlines bleed past its rows to the trailing edge")
    func hairlinesBleedPastTheRows() throws {
        let first = makeGroupedFormCardRow("Width", control: NSTextField(labelWithString: "1"))
        let second = makeGroupedFormCardRow("Height", control: NSTextField(labelWithString: "2"))
        let card = makeGroupedFormCard(rows: [first, second])
        card.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        card.layoutSubtreeIfNeeded()

        let hairline = try #require(firstSubview(NSBox.self, in: card) { $0.frame.height == 1 })
        let hairlineInCard = hairline.convert(hairline.bounds, to: card)
        let rowInCard = first.convert(first.bounds, to: card)
        #expect(hairlineInCard.maxX == card.bounds.maxX)
        #expect(rowInCard.minX == GroupedFormStyle.cardPadding)
        #expect(rowInCard.maxX == card.bounds.maxX - GroupedFormStyle.cardPadding)
    }
}
