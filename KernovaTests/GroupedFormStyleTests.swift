import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("GroupedFormStyle Tests", .caseScoped)
@MainActor
struct GroupedFormStyleTests {
    /// A note whose state holds, refreshed so it shows `text`.
    private func shownNote(_ text: String) -> GroupedFormStateNote {
        let note = GroupedFormStateNote(text, shownWhen: { true })
        note.refresh()
        return note
    }

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
    private func laidOutCard(notes: [GroupedFormStateNote]) -> (card: NSView, lastRow: NSView) {
        let first = makeGroupedFormCardRow("Width", control: NSTextField(labelWithString: "1"))
        let last = makeGroupedFormCardRow("Height", control: NSTextField(labelWithString: "2"))
        let card = makeGroupedFormCard(rows: [first, last], notes: notes)
        card.frame = NSRect(x: 0, y: 0, width: 400, height: card.fittingSize.height)
        card.layoutSubtreeIfNeeded()
        return (card, last)
    }

    @Test("A card's note sits inside it under the last row, inset like a row")
    func noteSitsInsideTheCardUnderTheLastRow() throws {
        let note = shownNote("Boots at 800 × 900 pixels.")
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
        let note = shownNote("Boots at 800 × 900 pixels.")
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
        let note = shownNote("This virtual machine has no network device.")
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
        let note = GroupedFormStateNote("Takes effect on next start.", shownWhen: { false })
        note.refresh()
        let (withHiddenNote, _) = laidOutCard(notes: [note])
        let (withoutNotes, _) = laidOutCard(notes: [])

        #expect(withHiddenNote.fittingSize.height == withoutNotes.fittingSize.height)
    }

    /// A card holding a top-level row and a sub-option group whose sub-option
    /// owns `subOptionNotes`, with `cardNotes` under it all, laid out at a
    /// fixed width.
    private func laidOutSubOptionCard(
        subOptionNotes: [GroupedFormStateNote], cardNotes: [GroupedFormStateNote] = [],
        isSubOptionHidden: Bool = false
    ) -> (card: NSView, subOption: NSView) {
        let subOption = makeGroupedFormCardRow(
            "Baseline snapshot", control: NSTextField(labelWithString: "Snapshot 0"))
        let group = makeGroupedFormSubOptionGroup(
            primary: makeGroupedFormCardRow("Ephemeral Mode", control: NSSwitch()),
            subOption: subOptionNotes.isEmpty
                ? subOption : GroupedFormNotedRow(subOption, notes: subOptionNotes))
        group.isSubOptionHidden = isSubOptionHidden
        let card = makeGroupedFormCard(
            rows: [makeGroupedFormCardRow("Start", control: NSSwitch()), group],
            notes: cardNotes)
        card.frame = NSRect(x: 0, y: 0, width: 400, height: card.fittingSize.height)
        card.layoutSubtreeIfNeeded()
        return (card, subOption)
    }

    @Test("A sub-option's note sits a small gap under it, at its indent and across its width")
    func subOptionNoteTakesTheSubOptionsEdges() throws {
        let note = shownNote("Comes back suspended.")
        let (card, subOption) = laidOutSubOptionCard(subOptionNotes: [note])

        // The card's own view is not flipped: "below" is a smaller y.
        let noteInCard = try alignmentRect(of: note, in: card)
        let rowInCard = subOption.convert(subOption.bounds, to: card)
        #expect(noteInCard.height > 0)
        #expect(rowInCard.minX == GroupedFormStyle.cardPadding + groupedFormSubOptionIndent)
        #expect(noteInCard.minX == rowInCard.minX)
        #expect(noteInCard.maxX == rowInCard.maxX)
        #expect(rowInCard.minY - noteInCard.maxY == GroupedFormStyle.cardStackSpacing)
    }

    @Test("Hiding a sub-option hides its notes with it")
    func hiddenSubOptionTakesItsNotes() {
        let note = shownNote("Comes back suspended.")
        let (withNote, _) = laidOutSubOptionCard(subOptionNotes: [note], isSubOptionHidden: true)
        let (withoutNote, _) = laidOutSubOptionCard(subOptionNotes: [], isSubOptionHidden: true)

        #expect(withNote.fittingSize.height == withoutNote.fittingSize.height)
    }

    @Test("A card's own note beside a sub-option group sits at the rows' edge")
    func cardNoteBesideAGroupSitsAtTheRowsEdge() throws {
        let rowNote = shownNote("Comes back suspended.")
        let cardNote = shownNote("Takes effect at the next power-off.")
        let (card, _) = laidOutSubOptionCard(subOptionNotes: [rowNote], cardNotes: [cardNote])

        let noteInCard = try alignmentRect(of: cardNote, in: card)
        #expect(noteInCard.minX == GroupedFormStyle.cardPadding)
        #expect(noteInCard.maxX == card.bounds.maxX - GroupedFormStyle.cardPadding)
    }

    @Test("A field row that owns a note still shares the card's label column")
    func notedFieldRowSharesTheLabelColumn() throws {
        let short = NSTextField(string: "")
        let long = NSTextField(string: "")
        let card = makeGroupedFormCard(rows: [
            GroupedFormNotedRow(
                GroupedFormFieldRow("Name", control: short),
                notes: [shownNote("Shown in the sidebar.")]),
            GroupedFormFieldRow("Account name", control: long),
        ])
        card.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        card.layoutSubtreeIfNeeded()

        let widest = try #require(findLabel(withText: "Account name", in: card))
        let shortInCard = short.convert(short.bounds, to: card)
        let longInCard = long.convert(long.bounds, to: card)
        #expect(shortInCard.minX == longInCard.minX)
        #expect(shortInCard.minX > widest.convert(widest.bounds, to: card).maxX)
    }

    // MARK: - Row info

    @Test(
        "A card row with info shows an info button between its title and any kind of control",
        arguments: ["switch", "stepped", "value"])
    func cardRowShowsInfoForAnyControl(kind: String) throws {
        let control: NSView =
            switch kind {
            case "switch": NSSwitch()
            case "stepped":
                makeGroupedFormSteppedControl(NSTextField(string: "4"), NSStepper(), unit: "GB")
            default: makeGroupedFormValueLabel("192.168.64.10")
            }
        let row = makeGroupedFormCardRow(
            "Memory", control: control, info: [.body("Committed at start.")])
        let card = makeGroupedFormCard(rows: [row])
        card.frame = NSRect(x: 0, y: 0, width: 400, height: card.fittingSize.height)
        card.layoutSubtreeIfNeeded()

        let info = try #require(row.infoButton)
        #expect(info.isDescendant(of: row))
        #expect(info.button.toolTip == "About Memory")
        let titleInCard = row.titleLabel.convert(row.titleLabel.bounds, to: card)
        let infoInCard = info.convert(info.bounds, to: card)
        let controlInCard = control.convert(control.bounds, to: card)
        #expect(infoInCard.minX > titleInCard.maxX)
        #expect(controlInCard.minX > infoInCard.maxX)
        #expect(
            row.titleLabel.contentCompressionResistancePriority(for: .horizontal) == .required)
    }

    @Test("A card row without info has no info button")
    func cardRowWithoutInfoHasNoButton() {
        let row = makeGroupedFormCardRow("Name", control: NSSwitch())

        #expect(row.infoButton == nil)
        #expect(firstSubview(InfoButtonView.self, in: row) == nil)
    }

    @Test("A field row with info keeps the card's label column, its button inside it")
    func fieldRowWithInfoKeepsTheLabelColumn() throws {
        let short = NSTextField(string: "")
        let long = NSTextField(string: "")
        let withInfo = GroupedFormFieldRow(
            "Password", control: short, info: [.body("Not saved.")])
        let card = makeGroupedFormCard(rows: [
            withInfo,
            GroupedFormFieldRow("Account name", control: long),
        ])
        card.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        card.layoutSubtreeIfNeeded()

        let info = try #require(withInfo.infoButton)
        let widest = try #require(findLabel(withText: "Account name", in: card))
        let shortInCard = short.convert(short.bounds, to: card)
        let longInCard = long.convert(long.bounds, to: card)
        let infoInCard = info.convert(info.bounds, to: card)
        #expect(shortInCard.minX == longInCard.minX)
        #expect(shortInCard.minX > widest.convert(widest.bounds, to: card).maxX)
        #expect(infoInCard.minX > withInfo.titleLabel.convert(withInfo.titleLabel.bounds, to: card).maxX)
        #expect(infoInCard.maxX < shortInCard.minX)
    }

    // MARK: - State-bound notes

    @Test("A state note shows its text while its state holds and hides when it doesn't")
    func stateNoteFollowsItsCondition() {
        let holds = TestState(false)
        let note = GroupedFormStateNote(
            "This virtual machine has no network device.", shownWhen: { holds.value })
        #expect(note.isHidden)

        note.refresh()
        #expect(note.isHidden)

        holds.value = true
        note.refresh()
        #expect(!note.isHidden)
        #expect(note.stringValue == "This virtual machine has no network device.")

        holds.value = false
        note.refresh()
        #expect(note.isHidden)
    }

    @Test("A state note built from content shows whatever the content states now")
    func stateNoteRereadsItsContent() {
        let content = TestState<String?>("Comes back suspended.")
        let note = GroupedFormStateNote(content: { content.value })
        note.refresh()
        #expect(!note.isHidden)
        #expect(note.stringValue == "Comes back suspended.")

        content.value = "Comes back powered off."
        note.refresh()
        #expect(note.stringValue == "Comes back powered off.")

        content.value = nil
        note.refresh()
        #expect(note.isHidden)
    }

    @Test("A card collapses a note when its state stops holding")
    func cardCollapsesANoteWhoseStateEnds() {
        let holds = TestState(true)
        let note = GroupedFormStateNote("Takes effect on next start.", shownWhen: { holds.value })
        note.refresh()
        let (card, _) = laidOutCard(notes: [note])
        let shownHeight = card.fittingSize.height

        holds.value = false
        note.refresh()
        let (withoutNotes, _) = laidOutCard(notes: [])
        #expect(card.fittingSize.height < shownHeight)
        #expect(card.fittingSize.height == withoutNotes.fittingSize.height)
    }

    // MARK: - Titles

    @Test("A wizard step title shows an info button beside it when given info")
    func wizardTitleShowsInfo() throws {
        let plain = makeWizardTitle("Configure Resources")
        #expect(firstSubview(InfoButtonView.self, in: plain) == nil)

        let titled = makeWizardTitle("Configure Resources", info: [.body("Set at creation.")])
        titled.frame = NSRect(x: 0, y: 0, width: 600, height: titled.fittingSize.height)
        titled.layoutSubtreeIfNeeded()
        let info = try #require(firstSubview(InfoButtonView.self, in: titled))
        let label = try #require(findLabel(withText: "Configure Resources", in: titled))
        #expect(info.button.toolTip == "About Configure Resources")
        #expect(
            info.convert(info.bounds, to: titled).minX
                > label.convert(label.bounds, to: titled).maxX)
    }

    @Test("A sheet title shows an info button beside it when given info")
    func sheetTitleShowsInfo() throws {
        #expect(firstSubview(InfoButtonView.self, in: makeSheetTitle("Boot Order")) == nil)

        let titled = makeSheetTitle("Boot Order", info: [.body("Drag rows to reorder.")])
        let info = try #require(firstSubview(InfoButtonView.self, in: titled))
        #expect(info.button.toolTip == "About Boot Order")
        #expect(titled.arrangedSubviews.last === info)
    }

    @Test("A wizard radio option shows its description beneath the radio")
    func radioOptionShowsDescriptionBeneathRadio() throws {
        let radio = NSButton(radioButtonWithTitle: "macOS", target: nil, action: nil)
        let option = makeWizardRadioOption(
            radio: radio, iconSymbol: "apple.logo", description: "Run macOS.")
        option.frame = NSRect(x: 0, y: 0, width: 400, height: option.fittingSize.height)
        option.layoutSubtreeIfNeeded()

        let description = try #require(findLabel(withText: "Run macOS.", in: option))
        let descriptionFrame = description.convert(description.bounds, to: option)
        let radioFrame = radio.convert(radio.bounds, to: option)
        // Flipped or not, the description lies wholly on the far side of the
        // radio from the option's top.
        let isBelow =
            option.isFlipped
            ? descriptionFrame.minY >= radioFrame.maxY : descriptionFrame.maxY <= radioFrame.minY
        #expect(isBelow)
        #expect(descriptionFrame.minX > radioFrame.minX)
    }

    @Test(
        "A card's fill is a translucent overlay, darkening in light and lightening in dark",
        arguments: [NSAppearance.Name.aqua, .darkAqua])
    func cardFillOverlaysAnyBackground(appearance: NSAppearance.Name) throws {
        let fill = try GroupedFormStyle.cardFill.resolvedSRGB(in: appearance)

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

        #expect(try fill.resolvedSRGB(in: .aqua) != fill.resolvedSRGB(in: .darkAqua))
    }
}

/// The state a note's condition reads, changed between refreshes.
@MainActor
private final class TestState<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
