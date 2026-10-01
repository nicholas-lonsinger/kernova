import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("GroupedFormStyle Tests", .caseScoped)
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

    @Test("A card's field rows start their fields at one edge, past the widest label")
    func fieldRowsShareALabelColumn() throws {
        let short = NSTextField(string: "")
        let long = NSTextField(string: "")
        let card = makeGroupedFormCard(rows: [
            GroupedFormFieldRow("Name", control: short),
            GroupedFormFieldRow("Account name", control: long),
        ])
        card.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        card.layoutSubtreeIfNeeded()

        let widest = try #require(findLabel(withText: "Account name", in: card))
        let widestInCard = widest.convert(widest.bounds, to: card)
        let shortInCard = short.convert(short.bounds, to: card)
        let longInCard = long.convert(long.bounds, to: card)
        #expect(
            widest.alignmentRect(forFrame: widest.frame).width == widest.intrinsicContentSize.width)
        #expect(shortInCard.minX == longInCard.minX)
        #expect(shortInCard.minX > widestInCard.maxX)
        #expect(shortInCard.maxX == card.bounds.maxX - GroupedFormStyle.cardPadding)
        #expect(longInCard.maxX == shortInCard.maxX)
    }

    /// A two-row card laid out at a fixed width, with `notes` under its rows.
    private func laidOutCard(notes: [NSView]) -> (card: NSView, lastRow: NSView) {
        let first = makeGroupedFormCardRow("Width", control: NSTextField(labelWithString: "1"))
        let last = makeGroupedFormCardRow("Height", control: NSTextField(labelWithString: "2"))
        let card = makeGroupedFormCard(rows: [first, last], notes: notes)
        card.frame = NSRect(x: 0, y: 0, width: 400, height: card.fittingSize.height)
        card.layoutSubtreeIfNeeded()
        return (card, last)
    }

    @Test("A card's note sits inside it under the last row, inset like a row")
    func noteSitsInsideTheCardUnderTheLastRow() throws {
        let note = makeGroupedFormCaption("Boots at 800 × 900 pixels.")
        let (card, lastRow) = laidOutCard(notes: [note])

        // The card's own view is not flipped: "below" is a smaller y.
        let noteInCard = try alignmentRect(of: note, in: card)
        let rowInCard = lastRow.convert(lastRow.bounds, to: card)
        #expect(note.isDescendant(of: card))
        #expect(noteInCard.height > 0)
        #expect(noteInCard.maxY <= rowInCard.minY)
        #expect(noteInCard.minY >= card.bounds.minY + GroupedFormStyle.cardPadding)
        #expect(noteInCard.minX == GroupedFormStyle.cardPadding)
        #expect(noteInCard.maxX == card.bounds.maxX - GroupedFormStyle.cardPadding)
    }

    @Test("No hairline separates a card's last row from its notes")
    func noHairlineBeforeTheNotes() {
        let note = makeGroupedFormCaption("Boots at 800 × 900 pixels.")
        let (card, lastRow) = laidOutCard(notes: [note])

        let rowMinY = lastRow.convert(lastRow.bounds, to: card).minY
        let hairlines = allSubviews(NSBox.self, in: card) { $0.frame.height == 1 }
        #expect(!hairlines.isEmpty)
        for hairline in hairlines {
            #expect(hairline.convert(hairline.bounds, to: card).minY >= rowMinY)
        }
    }

    @Test("A note sits a small gap under the last row showing, past a hidden collapsible row")
    func noteGapSkipsAHiddenLastRow() throws {
        let first = makeGroupedFormCardRow("Mode", control: NSTextField(labelWithString: "None"))
        let collapsed = GroupedFormCollapsibleRow(
            row: makeGroupedFormCardRow("MAC address", control: NSTextField(labelWithString: "-")))
        collapsed.isHidden = true
        let note = makeGroupedFormCaption("This virtual machine has no network device.")
        let card = makeGroupedFormCard(rows: [first, collapsed], notes: [note])
        card.frame = NSRect(x: 0, y: 0, width: 400, height: card.fittingSize.height)
        card.layoutSubtreeIfNeeded()

        let rowInCard = first.convert(first.bounds, to: card)
        #expect(try rowInCard.minY - alignmentRect(of: note, in: card).maxY == Spacing.small)
    }

    @Test(
        "Rows sit a relaxed gap either side of the hairline between them, collapsible or not",
        arguments: [false, true])
    func rowToRowDistanceIsRelaxedAroundTheHairline(collapsible: Bool) {
        let first = makeGroupedFormCardRow("Width", control: NSTextField(labelWithString: "1"))
        let plain = makeGroupedFormCardRow("Height", control: NSTextField(labelWithString: "2"))
        let second: NSView = collapsible ? GroupedFormCollapsibleRow(row: plain) : plain
        let card = makeGroupedFormCard(rows: [first, second])
        card.frame = NSRect(x: 0, y: 0, width: 400, height: card.fittingSize.height)
        card.layoutSubtreeIfNeeded()

        let firstInCard = first.convert(first.bounds, to: card)
        let secondInCard = plain.convert(plain.bounds, to: card)
        let hairline = allSubviews(NSBox.self, in: card) { $0.frame.height == 1 }
        #expect(hairline.count == 1)
        let hairlineInCard = hairline[0].convert(hairline[0].bounds, to: card)
        #expect(firstInCard.minY - hairlineInCard.maxY == Spacing.relaxed)
        #expect(hairlineInCard.minY - secondInCard.maxY == Spacing.relaxed)
    }

    @Test("A card whose only note is hidden is as tall as a card with none")
    func hiddenNoteLeavesNoGap() {
        let note = makeGroupedFormCaption("Takes effect on next start.")
        note.isHidden = true
        let (withHiddenNote, _) = laidOutCard(notes: [note])
        let (withoutNotes, _) = laidOutCard(notes: [])

        #expect(withHiddenNote.fittingSize.height == withoutNotes.fittingSize.height)
    }

    @Test(
        "A card's fill is a translucent overlay, darkening in light and lightening in dark",
        arguments: [NSAppearance.Name.aqua, .darkAqua])
    func cardFillOverlaysAnyBackground(appearance: NSAppearance.Name) throws {
        var resolved: NSColor?
        try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
            resolved = GroupedFormStyle.cardFill.usingColorSpace(.sRGB)
        }
        let fill = try #require(resolved)

        #expect(fill.alphaComponent > 0 && fill.alphaComponent < 1)
        if appearance == .darkAqua {
            #expect(fill.brightnessComponent > 0.5)
        } else {
            #expect(fill.brightnessComponent < 0.5)
        }
    }

    @Test("A banner's tinted fill follows light/dark")
    func bannerFillFollowsAppearance() throws {
        let banner = makeGroupedFormBanner(symbolName: "info.circle", tint: .systemOrange, message: "Message")
        let fill = try #require(banner.subviews.lazy.compactMap { $0 as? NSBox }.first).fillColor
        var light: NSColor?
        var dark: NSColor?
        try #require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            light = fill.usingColorSpace(.sRGB)
        }
        try #require(NSAppearance(named: .darkAqua)).performAsCurrentDrawingAppearance {
            dark = fill.usingColorSpace(.sRGB)
        }

        #expect(try #require(light) != (try #require(dark)))
    }
}
