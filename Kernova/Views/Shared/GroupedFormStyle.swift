import AppKit
import KernovaKit

/// Shared design tokens and atom factories for the native macOS *grouped form*
/// look — rounded, subtly-filled cards with hairline-separated rows, section
/// headers, captions, and tinted banners.
///
/// These atoms are context-neutral: tokens specific to one surface (e.g. the
/// wizard's fixed sheet dimensions) stay in that surface's own style file.
enum GroupedFormStyle {
    /// Symmetric inset from a scrolling form's viewport to its content, applied on
    /// both sides so content stays horizontally centered — and the clearance
    /// between content and a trailing overlay scroller.
    static let contentSideInset: CGFloat = 16

    /// Width a form's content is capped at in a pane with no natural width, so a
    /// row's control stays beside its label however wide the window gets.
    static let columnWidth: CGFloat = 620

    /// Inset from a card's edges to its rows.
    static let cardPadding: CGFloat = 12

    /// Spacing between the views a card stacks: a note under the row above it.
    /// A ``GroupedFormCardSeparator`` pads out the rest of a row-to-row gap.
    static let cardStackSpacing = Spacing.small

    /// Fill for a grouped card: a translucent overlay — darkening in light,
    /// lightening in dark — so a card stands off whatever background it sits on.
    static let cardFill = NSColor(name: "groupedFormCardFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .secondarySystemFill
            : .tertiarySystemFill
    }
}

// MARK: - Scrolling

/// A clip view that reports itself flipped so its document view is anchored at
/// the top-left and scrolls downward.
///
/// Without this, `NSClipView`'s default bottom-left origin anchors short content
/// to the bottom of the viewport — and when content is marginally taller than
/// the viewport, the initial scroll position shows the bottom, clipping the top
/// out of view.
final class FlippedClipView: NSClipView {
    nonisolated override var isFlipped: Bool { true }
}

/// Wraps `content` in a borderless vertical scroll view.
///
/// `content` is hosted inside a full-width document view and inset symmetrically
/// by ``GroupedFormStyle/contentSideInset``, plus `topInset` / `bottomInset`.
/// The document view fills the clip view's width: pinning it *narrower* than the
/// clip makes `NSClipView` offset its bounds origin to align the under-sized
/// document, which scrolls the content sideways and defeats the inset. Callers
/// add their own per-subview width constraints against `content`.
///
/// `maxContentWidth` caps the content and centers it, for a pane with no natural
/// width of its own; a viewport narrower than the cap still fills, minus the
/// insets.
@MainActor
func makeGroupedFormScrollView(
    documentView content: NSView,
    topInset: CGFloat = 0,
    bottomInset: CGFloat = 0,
    maxContentWidth: CGFloat? = nil
) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.contentView = FlippedClipView()
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.autohidesScrollers = true
    // No `scrollerStyle`: the user's scroll-bar setting chooses it. Under
    // "Always", the legacy scroller and the gutter it reserves are the form's
    // persistent more-below cue — `ScrollMoreIndicator` leaves that scroller
    // unveiled for the same reason.
    scrollView.automaticallyAdjustsContentInsets = false
    scrollView.contentInsets = NSEdgeInsetsZero
    scrollView.contentView.automaticallyAdjustsContentInsets = false
    scrollView.contentView.contentInsets = NSEdgeInsetsZero

    let docView = NSView()
    docView.translatesAutoresizingMaskIntoConstraints = false
    content.translatesAutoresizingMaskIntoConstraints = false
    docView.addSubview(content)
    scrollView.documentView = docView

    let clip = scrollView.contentView
    let inset = GroupedFormStyle.contentSideInset
    NSLayoutConstraint.activate([
        // Document view fills the clip width; its height flows from the content.
        docView.topAnchor.constraint(equalTo: clip.topAnchor),
        docView.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
        docView.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
        docView.widthAnchor.constraint(equalTo: clip.widthAnchor),
        content.topAnchor.constraint(equalTo: docView.topAnchor, constant: topInset),
        content.bottomAnchor.constraint(equalTo: docView.bottomAnchor, constant: -bottomInset),
    ])

    guard let maxContentWidth else {
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -inset),
        ])
        return scrollView
    }
    applyCappedColumn(content, in: docView, maxWidth: maxContentWidth)
    return scrollView
}

/// Pins `content` as a centered column inside `container`: inset from both
/// edges, capped at `maxWidth`, and filling whatever is narrower than the cap.
///
/// The one place the column rule is expressed, so a pinned header and the
/// scrolling form it sits above line up by construction.
///
/// The preferred width is the cap as a **constant**, never `container.width`
/// less the insets: a container-relative equality is bidirectional, so at any
/// priority it also pulls the container in to the column's width wherever the
/// container's own width is negotiable — which is what a split-view divider and
/// a window edge are. The inset inequalities alone make a narrow container
/// squeeze the column, so the fill behavior survives the change.
@MainActor
func applyCappedColumn(_ content: NSView, in container: NSView, maxWidth: CGFloat) {
    content.translatesAutoresizingMaskIntoConstraints = false
    let inset = GroupedFormStyle.contentSideInset
    let prefersFullColumn = content.widthAnchor.constraint(equalToConstant: maxWidth)
    prefersFullColumn.priority = .defaultHigh
    NSLayoutConstraint.activate([
        content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        content.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
        content.leadingAnchor.constraint(
            greaterThanOrEqualTo: container.leadingAnchor, constant: inset),
        content.trailingAnchor.constraint(
            lessThanOrEqualTo: container.trailingAnchor, constant: -inset),
        prefersFullColumn,
    ])
}

// MARK: - Grouped cards (System Settings style)

/// A card row that spans the card's full width and insets its own content,
/// because it carries hairlines of its own that bleed to the card's trailing
/// edge the way the card's do.
@MainActor
protocol GroupedFormFullBleedRow: NSView {}

@MainActor
func makeGroupedFormHairline() -> NSView {
    let line = NSBox()
    line.boxType = .custom
    line.borderWidth = 0
    line.fillColor = .separatorColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
}

/// A hairline padded so that, set between two rows in a stack spaced
/// ``GroupedFormStyle/cardStackSpacing``, it puts ``Spacing/relaxed`` on each
/// side of the line.
///
/// The padding lives on the separator rather than in the stack's spacing so
/// that a card's notes sit ``GroupedFormStyle/cardStackSpacing`` under
/// whichever row is the last one showing.
@MainActor
final class GroupedFormCardSeparator: NSView {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let line = makeGroupedFormHairline()
        addSubview(line)
        let pad = Spacing.relaxed - GroupedFormStyle.cardStackSpacing
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            line.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -pad),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GroupedFormCardSeparator does not support NSCoder")
    }
}

/// The leading title of a card row, which keeps its full width however narrow
/// the row gets.
@MainActor
private func makeGroupedFormRowTitle(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Typography.body
    label.isSelectable = false
    label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    return label
}

/// A card row naming the control it holds: its leading title, an info button
/// beside the title when the row has one, then the control.
///
/// The title is the row's own, so ``applyGroupedFormRowEnabled(_:control:)``
/// grays it with any control inside the row.
@MainActor
class GroupedFormControlRow: NSStackView {
    let titleLabel: NSTextField
    /// The button opening the row's info popover; `nil` for a row without one.
    let infoButton: InfoButtonView?
    /// The title, with ``infoButton`` beside it when there is one: what a
    /// ``GroupedFormFieldRow`` lines its control up after.
    let labelColumn: NSView

    fileprivate init(
        _ labelText: String, info: [InfoPopoverParagraph], trailing: [NSView],
        alignment: NSLayoutConstraint.Attribute
    ) {
        titleLabel = makeGroupedFormRowTitle(labelText)
        if info.isEmpty {
            infoButton = nil
            labelColumn = titleLabel
        } else {
            let button = makeGroupedFormInfoButton(label: labelText, paragraphs: info)
            infoButton = button
            let column = NSStackView(views: [titleLabel, button])
            column.orientation = .horizontal
            column.alignment = .centerY
            column.spacing = Spacing.small
            column.setHuggingPriority(.defaultHigh, for: .horizontal)
            labelColumn = column
        }
        super.init(frame: .zero)
        setViews([labelColumn] + trailing, in: .leading)
        orientation = .horizontal
        self.alignment = alignment
        spacing = Spacing.standard
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GroupedFormControlRow does not support NSCoder")
    }
}

/// Builds a full-width card row: a leading title, an info button beside it
/// when `info` has paragraphs, and `control` pushed to the trailing edge — a
/// stepper, switch, popup, a stack of controls, or a read-only value. An input
/// that fills the row is a ``GroupedFormFieldRow``.
@MainActor
func makeGroupedFormCardRow(
    _ labelText: String,
    control: NSView,
    info: [InfoPopoverParagraph] = [],
    alignment: NSLayoutConstraint.Attribute = .centerY
) -> GroupedFormControlRow {
    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    return GroupedFormControlRow(
        labelText, info: info, trailing: [spacer, control], alignment: alignment)
}

/// A card row whose control fills the space after its label — a text field or
/// an editor — starting at the label column ``makeGroupedFormCard(rows:notes:)``
/// gives its field rows; an info button sits inside that column, beside the
/// title.
@MainActor
final class GroupedFormFieldRow: GroupedFormControlRow {
    init(
        _ labelText: String, control: NSView, info: [InfoPopoverParagraph] = [],
        alignment: NSLayoutConstraint.Attribute = .centerY
    ) {
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        super.init(labelText, info: info, trailing: [control], alignment: alignment)
    }
}

/// A card row that can be shown and hidden after its card is built.
///
/// ``makeGroupedFormCard(rows:notes:)`` draws a hairline before every row but the
/// first, which a row hidden on its own would leave stranded against the next
/// separator. This carries that hairline instead, so `isHidden` takes both.
/// Never a card's first row — the hairline would have nothing above it.
@MainActor
final class GroupedFormCollapsibleRow: NSStackView, GroupedFormFullBleedRow {
    init(row: NSView) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = GroupedFormStyle.cardStackSpacing
        translatesAutoresizingMaskIntoConstraints = false
        let hairline = GroupedFormCardSeparator()
        for view in [hairline, row] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(
                equalTo: widthAnchor,
                constant: view === hairline ? 0 : -GroupedFormStyle.cardPadding
            ).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GroupedFormCollapsibleRow does not support NSCoder")
    }
}

/// A row and the notes that describe it, stacked so each note sits
/// ``GroupedFormStyle/cardStackSpacing`` under the row and takes its leading
/// edge and width from it.
///
/// A note about one row is owned by that row, so it goes wherever the row goes:
/// a card's top-level row, a ``GroupedFormSubOptionGroup``'s primary, or its
/// sub-option, where it shares the indent and hides with the sub-option. A
/// hidden note collapses, leaving no gap. ``makeGroupedFormCard(rows:notes:)``
/// treats it as the row it wraps.
@MainActor
final class GroupedFormNotedRow: NSStackView {
    let wrappedRow: NSView

    init(_ row: NSView, notes: [GroupedFormStateNote]) {
        wrappedRow = row
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = GroupedFormStyle.cardStackSpacing
        translatesAutoresizingMaskIntoConstraints = false
        // A full-bleed row spans to the card's trailing edge and insets its own
        // content; its notes take the inset a row's content has.
        let noteInset =
            groupedFormJudgedRow(row) is GroupedFormFullBleedRow ? GroupedFormStyle.cardPadding : 0
        for view in [row] + notes as [NSView] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(
                equalTo: widthAnchor, constant: view === row ? 0 : -noteInset
            ).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GroupedFormNotedRow does not support NSCoder")
    }
}

/// The row ``makeGroupedFormCard(rows:notes:)`` infers layout from for `row`:
/// the row inside any ``GroupedFormNotedRow``, since its notes change nothing
/// about how the row sits in the card.
@MainActor
private func groupedFormJudgedRow(_ row: NSView) -> NSView {
    guard let noted = row as? GroupedFormNotedRow else { return row }
    return groupedFormJudgedRow(noted.wrappedRow)
}

/// Builds a card: hairline-separated rows on a rounded, filled background.
///
/// Separators run from the label edge to the card's trailing edge — the
/// asymmetry System Settings draws — so the content stack spans to that edge
/// and every non-hairline row is inset back by ``GroupedFormStyle/cardPadding``.
/// The ``GroupedFormFieldRow``s among `rows`, bare or in a
/// ``GroupedFormNotedRow``, share one label column, the width of their widest
/// title and info button, so their controls start at one edge.
///
/// `notes` state the card's current state as a whole and sit inside it under
/// the rows, at the rows' leading edge, with no hairline, collapsing when
/// hidden; a note about one row is owned by that row as a
/// ``GroupedFormNotedRow``. Text explaining what the section is or does goes in
/// its header's info paragraphs, never on screen.
@MainActor
func makeGroupedFormCard(rows: [NSView], notes: [GroupedFormStateNote] = []) -> NSView {
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = GroupedFormStyle.cardStackSpacing
    content.translatesAutoresizingMaskIntoConstraints = false

    var arranged: [(view: NSView, bleeds: Bool)] = []
    for (index, row) in rows.enumerated() {
        // A collapsible row carries its own hairline, so that hiding it takes
        // the separator with it.
        let judged = groupedFormJudgedRow(row)
        if index > 0, !(judged is GroupedFormCollapsibleRow) {
            arranged.append((GroupedFormCardSeparator(), true))
        }
        arranged.append((row, judged is GroupedFormFullBleedRow))
    }
    arranged += notes.map { ($0, false) }
    arranged.forEach { content.addArrangedSubview($0.view) }

    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.cornerRadius = CornerRadius.card
    box.borderWidth = 0
    box.fillColor = GroupedFormStyle.cardFill
    box.borderColor = .clear

    let container = NSView()
    container.addFullSizeSubview(box)
    container.addSubview(content)
    let pad = GroupedFormStyle.cardPadding
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: container.topAnchor, constant: pad),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -pad),
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: pad),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    for entry in arranged {
        entry.view.widthAnchor.constraint(
            equalTo: content.widthAnchor, constant: entry.bleeds ? 0 : -pad
        ).isActive = true
    }
    let labelColumns = rows.compactMap {
        (groupedFormJudgedRow($0) as? GroupedFormFieldRow)?.labelColumn
    }
    for column in labelColumns.dropFirst() {
        column.widthAnchor.constraint(equalTo: labelColumns[0].widthAnchor).isActive = true
    }
    return container
}

/// Leading indent applied to a sub-option nested beneath its parent row.
let groupedFormSubOptionIndent: CGFloat = 20

/// Wraps `view` so it sits at the sub-option indent while its container
/// still spans its stack — which leaves the stack's leading alignment
/// satisfied and lets the stack hide it as a row.
@MainActor
func makeGroupedFormIndented(_ view: NSView) -> NSView {
    let container = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(view)
    NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: container.topAnchor),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        view.leadingAnchor.constraint(
            equalTo: container.leadingAnchor, constant: groupedFormSubOptionIndent),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
    ])
    return container
}

/// A primary row and a dependent sub-option as a single grouped-form "row": the
/// sub-option (and the hairline separating it) are indented beneath the primary
/// so the pair reads as a parent → child unit.
///
/// Pass one to ``makeGroupedFormCard(rows:notes:)`` in place of two sibling rows, so
/// the card's full-width separators land only *around* the pair.
/// ``isSubOptionHidden`` collapses the sub-option and its hairline together,
/// for a child that is meaningless until the parent is on. Either row may be a
/// ``GroupedFormNotedRow``; a sub-option's notes are indented and hidden with it.
@MainActor
final class GroupedFormSubOptionGroup: NSStackView, GroupedFormFullBleedRow {
    private let hairlineRow: NSView
    private let subOptionRow: NSView

    init(primary: NSView, subOption: NSView) {
        hairlineRow = makeGroupedFormIndented(makeGroupedFormHairline())
        subOptionRow = makeGroupedFormIndented(subOption)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Spacing.relaxed
        translatesAutoresizingMaskIntoConstraints = false
        for view in [primary, hairlineRow, subOptionRow] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addArrangedSubview(view)
            view.widthAnchor.constraint(
                equalTo: widthAnchor,
                constant: view === hairlineRow ? 0 : -GroupedFormStyle.cardPadding
            ).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GroupedFormSubOptionGroup does not support NSCoder")
    }

    /// Hides the sub-option along with the hairline above it, leaving the
    /// primary row as the card's whole row.
    var isSubOptionHidden: Bool {
        get { subOptionRow.isHidden }
        set {
            hairlineRow.isHidden = newValue
            subOptionRow.isHidden = newValue
        }
    }
}

@MainActor
func makeGroupedFormSubOptionGroup(
    primary: NSView, subOption: NSView
) -> GroupedFormSubOptionGroup {
    GroupedFormSubOptionGroup(primary: primary, subOption: subOption)
}

// MARK: - Row enablement

/// Enables or disables `control` with the appearance that says so, graying the
/// title of the ``GroupedFormControlRow`` holding it — the one way a control
/// whose enablement is decided per-refresh, rather than by the pane's
/// read-only lock, is enabled.
///
/// `isEnabled` alone is not enough: AppKit draws a disabled `NSSwitch` that is
/// **on** at about 0.7 opacity of its accent fill (measured on macOS 27.0
/// 26A428), fainter than the pane lock's `Alpha.disabled`, and never fades a
/// plain `NSTextField` for a neighboring control.
@MainActor
func applyGroupedFormRowEnabled(_ isEnabled: Bool, control: NSControl) {
    control.isEnabled = isEnabled
    control.alphaValue = isEnabled ? 1 : Alpha.disabled
    applyGroupedFormRowTitleEnabled(isEnabled, of: control)
}

/// Grays the title of the ``GroupedFormControlRow`` holding `view` unless it
/// takes input — for a control that says so its own way, such as an inline
/// label whose click-to-edit is disarmed.
@MainActor
func applyGroupedFormRowTitleEnabled(_ isEnabled: Bool, of view: NSView) {
    let row = sequence(first: view, next: \.superview).lazy
        .compactMap { $0 as? GroupedFormControlRow }.first
    row?.titleLabel.textColor = isEnabled ? .labelColor : .disabledControlTextColor
}

// MARK: - Labels

@MainActor
func makeGroupedFormValueLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = Typography.body
    label.textColor = .secondaryLabelColor
    label.lineBreakMode = .byTruncatingMiddle
    label.isSelectable = false
    return label
}

/// What a section header says about rows only a stopped VM can change.
let groupedFormLockHintText = "Editable when stopped"

/// A section-header hint naming the states in which the rows below take an
/// edit.
///
/// `text` states the condition for *this* section: the default suits everything
/// a live `VZVirtualMachine` pins, and a section a running guest still takes an
/// edit on passes its own wording rather than a claim the user can disprove.
@MainActor
func makeGroupedFormLockHint(text: String = groupedFormLockHintText) -> NSView {
    let icon = NSImageView(image: .systemSymbol("lock.fill", accessibilityDescription: text))
    icon.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
    icon.contentTintColor = .secondaryLabelColor

    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabelColor
    label.isSelectable = false

    let hint = NSStackView(views: [icon, label])
    hint.orientation = .horizontal
    hint.alignment = .centerY
    hint.spacing = Spacing.tight
    hint.toolTip = text
    hint.setContentHuggingPriority(.required, for: .horizontal)
    hint.setContentCompressionResistancePriority(.required, for: .horizontal)
    return hint
}

@MainActor
func makeGroupedFormSectionHeader(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .preferredFont(forTextStyle: .subheadline)
    label.textColor = .secondaryLabelColor
    label.isSelectable = false
    // Required so an over-constrained ancestor (e.g. a height-capped pane
    // hugging its content) breaks its own optional constraint instead of
    // resolving the conflict by collapsing the text to zero height.
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
}

@MainActor
private func applyGroupedFormCaptionStyle(_ label: NSTextField) {
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 0
    label.isSelectable = false
    label.setContentCompressionResistancePriority(.required, for: .vertical)
}

/// Caption-styled text that is the content of what holds it — an empty list's
/// placeholder, an alert accessory's lead-in — rather than a note about a
/// control, which is a ``GroupedFormStateNote``.
@MainActor
func makeGroupedFormContentText(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    applyGroupedFormCaptionStyle(label)
    return label
}

/// On-screen caption text about a row, a card, or a section, shown only while
/// the state it states holds: in a card's `notes`, a ``GroupedFormNotedRow``'s,
/// or below a card.
///
/// `content` is the whole note: its text while the state holds, `nil` while it
/// doesn't, which hides the note. ``refresh()`` re-reads it, so the owner calls
/// that wherever it repaints what the note describes; the note is hidden until
/// the first call.
@MainActor
final class GroupedFormStateNote: NSTextField {
    private var content: @MainActor () -> String? = { nil }

    convenience init(content: @escaping @MainActor () -> String?) {
        self.init(wrappingLabelWithString: "")
        self.content = content
        applyGroupedFormCaptionStyle(self)
        isHidden = true
    }

    /// A note reading `text` while `isShown` holds.
    convenience init(_ text: String, shownWhen isShown: @escaping @MainActor () -> Bool) {
        self.init(content: { isShown() ? text : nil })
    }

    func refresh() {
        guard let text = content() else {
            isHidden = true
            return
        }
        stringValue = text
        isHidden = false
    }
}

/// A borderless button drawn in a fixed tint.
///
/// A tint barely desaturates when AppKit disables a borderless button, so it is
/// driven from `isEnabled` — otherwise a disabled button reads as clickable and
/// clicking it does nothing.
@MainActor
final class TintedButton: NSButton {
    var tint: NSColor = .linkColor {
        didSet { applyTint() }
    }

    override var isEnabled: Bool {
        didSet { applyTint() }
    }

    // AppKit's press dimming covers template images but not a tinted title, so
    // the press effect is applied to the tint itself.
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        applyTint()
    }

    private func applyTint() {
        guard isEnabled else {
            contentTintColor = .disabledControlTextColor
            return
        }
        let pressed = cell?.isHighlighted ?? false
        contentTintColor = pressed ? tint.withSystemEffect(.pressed) : tint
    }
}

/// A borderless button in `tint`, optionally trailed by a symbol.
@MainActor
func makeTintedButton(
    _ title: String,
    tint: NSColor,
    font: NSFont = .preferredFont(forTextStyle: .caption1),
    trailingSymbolName: String? = nil,
    target: AnyObject,
    action: Selector
) -> NSButton {
    let button = TintedButton(frame: .zero)
    button.setButtonType(.momentaryPushIn)
    button.title = title
    button.target = target
    button.action = action
    button.isBordered = false
    button.bezelStyle = .badge
    button.font = font
    if let trailingSymbolName {
        button.image = .systemSymbol(trailingSymbolName, accessibilityDescription: "")
        button.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
        button.imagePosition = .imageTrailing
    }
    button.tint = tint
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

/// A borderless button that reads as a link.
@MainActor
func makeLinkButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    makeTintedButton(title, tint: .linkColor, target: target, action: action)
}

// MARK: - Boxes & banners

/// Wraps `content` in a rounded, tinted container drawn by an `NSBox`.
///
/// The box is a chrome layer pinned behind the content rather than its
/// `box.contentView`: a custom `NSBox` sizes its content view through the legacy
/// autoresizing path and never derives an intrinsic height from Auto Layout
/// content, so it collapses. Pinning the content as a sibling makes the
/// container's size a pure function of the content's own constraints.
@MainActor
func makeGroupedFormBox(
    content: NSView,
    fill: NSColor,
    border: NSColor,
    borderWidth: CGFloat,
    cornerRadius: CGFloat,
    padding: CGFloat
) -> NSView {
    let box = NSBox()
    box.boxType = .custom
    box.titlePosition = .noTitle
    box.cornerRadius = cornerRadius
    box.borderWidth = borderWidth
    box.fillColor = fill
    box.borderColor = border

    let container = NSView()
    container.addFullSizeSubview(box)

    content.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(content)
    NSLayoutConstraint.activate([
        content.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
        content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
        content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
        content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
    ])
    return container
}

/// A tinted banner: a symbol, `message`, then `trailingButtons` and, when
/// `info` is given, an info button labeled `info.label` opening its paragraphs.
@MainActor
func makeGroupedFormBanner(
    symbolName: String,
    tint: NSColor,
    message: String,
    trailingButtons: [NSButton] = [],
    info: (label: String, paragraphs: [InfoPopoverParagraph])? = nil
) -> NSView {
    let icon = NSImageView(image: .systemSymbol(symbolName, accessibilityDescription: ""))
    icon.contentTintColor = tint
    icon.setContentHuggingPriority(.required, for: .horizontal)
    icon.setContentCompressionResistancePriority(.required, for: .horizontal)

    let label = NSTextField(wrappingLabelWithString: message)
    label.font = .preferredFont(forTextStyle: .callout)
    label.maximumNumberOfLines = 0
    label.isSelectable = false

    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    var views: [NSView] = [icon, label, spacer]
    for button in trailingButtons {
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        views.append(button)
    }
    if let info {
        views.append(makeGroupedFormInfoButton(label: info.label, paragraphs: info.paragraphs))
    }

    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Spacing.standard

    return makeGroupedFormBox(
        content: row,
        fill: tint.withDynamicAlpha(0.1),
        border: tint.withDynamicAlpha(0.3),
        borderWidth: 1,
        cornerRadius: 8,
        padding: 10
    )
}

// MARK: - Form atoms shared by the settings panels

/// Stacks a section's header, card, and the notes below it.
@MainActor
func makeGroupedFormSection(_ subviews: [NSView]) -> NSStackView {
    let stack = NSStackView(views: subviews)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Spacing.small
    stack.translatesAutoresizingMaskIntoConstraints = false
    for view in subviews {
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    return stack
}

/// An info affordance for a row, a section header, a title, or a panel header
/// that states a single-section category's name in its place.
@MainActor
func makeGroupedFormInfoButton(label: String, paragraphs: [InfoPopoverParagraph]) -> InfoButtonView {
    let info = InfoButtonView()
    info.configure(label: label, paragraphs: paragraphs)
    return info
}

/// A vertical stack for a card's dynamic list of rows.
@MainActor
func makeGroupedFormListStack() -> NSStackView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = Spacing.standard
    stack.translatesAutoresizingMaskIntoConstraints = false
    return stack
}

@MainActor
func makeGroupedFormPushButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = NSButton(title: title, target: target, action: action)
    button.bezelStyle = .push
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
}

/// A card row of push buttons, left-aligned.
@MainActor
func makeGroupedFormButtonRow(_ buttons: [NSButton]) -> NSView {
    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: buttons + [spacer])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Spacing.standard
    return row
}

@MainActor
func makeGroupedFormSwitch(target: AnyObject, action: Selector) -> NSSwitch {
    let toggle = NSSwitch()
    toggle.controlSize = .small
    toggle.target = target
    toggle.action = action
    return toggle
}

/// A numeric field, its stepper, and the unit that follows them.
@MainActor
func makeGroupedFormSteppedControl(
    _ field: NSTextField, _ stepper: NSStepper, unit: String
) -> NSStackView {
    let unitLabel = NSTextField(labelWithString: unit)
    unitLabel.font = Typography.body
    unitLabel.textColor = .secondaryLabelColor
    unitLabel.isSelectable = false
    unitLabel.widthAnchor.constraint(equalToConstant: 22).isActive = true

    let control = NSStackView(views: [field, stepper, unitLabel])
    control.orientation = .horizontal
    control.alignment = .centerY
    control.spacing = Spacing.tight
    return control
}

/// Sets up a count field and its stepper over `bounds`, showing `value`.
@MainActor
func configureGroupedFormCount(
    field: NSTextField, stepper: NSStepper, bounds: InclusiveBounds<Int>, value: Int,
    delegate: any NSTextFieldDelegate, target: AnyObject, stepperAction: Selector
) {
    configureGroupedFormStepped(
        field: field, fieldWidth: 44, stepper: stepper, delegate: delegate, target: target,
        stepperAction: stepperAction)
    stepper.minValue = Double(bounds.lower)
    stepper.maxValue = Double(bounds.upper)
    field.integerValue = value
    stepper.integerValue = value
}

/// Sets up a memory field and its stepper over `bounds`, showing `value`.
///
/// The field takes decimal gigabytes; the arrows move between whole ones, as
/// ``groupedFormMemoryStep(_:from:within:)`` reads them.
@MainActor
func configureGroupedFormMemory(
    field: NSTextField, stepper: NSStepper, bounds: InclusiveBounds<VMMemorySize>,
    value: VMMemorySize, delegate: any NSTextFieldDelegate, target: AnyObject, stepperAction: Selector
) {
    // Wide enough for a size named to the megabyte, such as 1.501.
    configureGroupedFormStepped(
        field: field, fieldWidth: 56, stepper: stepper, delegate: delegate, target: target,
        stepperAction: stepperAction)
    stepper.minValue = bounds.lower.gibibytes
    stepper.maxValue = bounds.upper.gibibytes
    field.stringValue = value.gibibytesText
    stepper.doubleValue = value.gibibytes
}

/// The size an arrow click on `stepper` moves `current` to: the next whole
/// gigabyte in the arrow's direction, within `bounds`, or `nil` when the click
/// moved nothing.
///
/// Reads the direction off the stepper, which must hold `current` from
/// before the click.
@MainActor
func groupedFormMemoryStep(
    _ stepper: NSStepper, from current: VMMemorySize, within bounds: InclusiveBounds<VMMemorySize>
) -> VMMemorySize? {
    let clicked = stepper.doubleValue
    guard clicked != current.gibibytes else { return nil }
    return bounds.clamp(current.nextWholeGibibyte(upward: clicked > current.gibibytes))
}

@MainActor
private func configureGroupedFormStepped(
    field: NSTextField, fieldWidth: CGFloat, stepper: NSStepper, delegate: any NSTextFieldDelegate, target: AnyObject,
    stepperAction: Selector
) {
    field.alignment = .right
    field.delegate = delegate
    field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true

    stepper.controlSize = .small
    stepper.increment = 1
    stepper.valueWraps = false
    stepper.target = target
    stepper.action = stepperAction
}

/// The read-only switch on an attachment row, tagged with the item's id.
@MainActor
func makeGroupedFormReadOnlySwitch(
    id: UUID, isOn: Bool, enabled: Bool, target: AnyObject, action: Selector
) -> NSSwitch {
    let toggle = NSSwitch()
    toggle.controlSize = .small
    toggle.state = isOn ? .on : .off
    toggle.isEnabled = enabled
    toggle.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
    toggle.target = target
    toggle.action = action
    return toggle
}

@MainActor
func makeGroupedFormReadOnlyCaption() -> NSTextField {
    let caption = NSTextField(labelWithString: "Read Only")
    caption.font = .preferredFont(forTextStyle: .caption1)
    caption.textColor = .secondaryLabelColor
    caption.isSelectable = false
    caption.setContentHuggingPriority(.required, for: .horizontal)
    return caption
}

/// An inline trailing "eject" button for an attachment/share row.
///
/// Detaches only — the backing file is untouched — so it is neutral-tinted
/// rather than destructive red.
@MainActor
func makeGroupedFormEjectButton(
    id: UUID, enabled: Bool, target: AnyObject, action: Selector
) -> NSButton {
    let button = NSButton()
    button.image = .systemSymbol("eject.circle.fill", accessibilityDescription: "Eject")
    button.imagePosition = .imageOnly
    button.isBordered = false
    button.contentTintColor = .secondaryLabelColor
    button.isEnabled = enabled
    button.identifier = NSUserInterfaceItemIdentifier(id.uuidString)
    button.target = target
    button.action = action
    return button
}

@MainActor
func makeGroupedFormSecondaryLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.textColor = .secondaryLabelColor
    label.isSelectable = false
    return label
}

/// Empties a stack of its arranged subviews.
@MainActor
func clearGroupedFormStack(_ stack: NSStackView) {
    stack.arrangedSubviews.forEach {
        stack.removeArrangedSubview($0)
        $0.removeFromSuperview()
    }
}

/// Appends `view` to `stack`, pinned to its full width.
@MainActor
func addGroupedFormFullWidth(_ view: NSView, to stack: NSStackView) {
    stack.addArrangedSubview(view)
    view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
}
