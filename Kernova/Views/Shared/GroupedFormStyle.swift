import AppKit

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

    /// Fill for a grouped card, standing off the window background it sits on:
    /// the control background (white in Aqua) in light, a lightening overlay in
    /// dark, where a card lighter than the window is what reads as raised.
    static let cardFill = NSColor(name: "groupedFormCardFill") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .secondaryLabelColor.withAlphaComponent(0.08)
            : .controlBackgroundColor
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
/// The document view fills the clip view's width on purpose: pinning it
/// *narrower* than the clip makes `NSClipView` offset its bounds origin to align
/// the under-sized document, which scrolls the content sideways and defeats the
/// inset. Callers add their own per-subview width constraints against `content`.
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

/// Builds a full-width card row: a leading label and a trailing control/value.
///
/// By default the control is pushed to the trailing edge (for steppers, switches,
/// popups, and read-only values). Pass `fillsControl: true` for an input that
/// should stretch to fill the row (a text field). `titleLabel` hands the
/// freshly-built label back to the caller, for rows whose text has to be
/// restyled later.
@MainActor
func makeGroupedFormCardRow(
    _ labelText: String,
    control: NSView,
    alignment: NSLayoutConstraint.Attribute = .centerY,
    fillsControl: Bool = false,
    titleLabel: ((NSTextField) -> Void)? = nil
) -> NSView {
    let label = NSTextField(labelWithString: labelText)
    label.font = Typography.body
    label.isSelectable = false
    label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    titleLabel?(label)

    let views: [NSView]
    if fillsControl {
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views = [label, control]
    } else {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        views = [label, spacer, control]
    }

    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = alignment
    row.spacing = Spacing.standard
    return row
}

/// A card row that can be shown and hidden after its card is built.
///
/// ``makeGroupedFormCard(rows:)`` draws a hairline before every row but the
/// first, which a row hidden on its own would leave stranded against the next
/// separator. This carries that hairline instead, so `isHidden` takes both.
/// Never a card's first row — the hairline would have nothing above it.
@MainActor
final class GroupedFormCollapsibleRow: NSStackView, GroupedFormFullBleedRow {
    init(row: NSView) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Spacing.relaxed
        translatesAutoresizingMaskIntoConstraints = false
        let hairline = makeGroupedFormHairline()
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

/// Builds a card: hairline-separated rows on a rounded, filled background.
///
/// Separators run from the label edge to the card's trailing edge — the
/// asymmetry System Settings draws — so the content stack spans to that edge
/// and every non-hairline row is inset back by ``GroupedFormStyle/cardPadding``.
@MainActor
func makeGroupedFormCard(rows: [NSView]) -> NSView {
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .leading
    content.spacing = Spacing.relaxed
    content.translatesAutoresizingMaskIntoConstraints = false

    var arranged: [(view: NSView, bleeds: Bool)] = []
    for (index, row) in rows.enumerated() {
        // A collapsible row carries its own hairline, so that hiding it takes
        // the separator with it.
        if index > 0, !(row is GroupedFormCollapsibleRow) {
            arranged.append((makeGroupedFormHairline(), true))
        }
        arranged.append((row, row is GroupedFormFullBleedRow))
    }
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
    return container
}

/// Leading indent applied to a sub-option nested beneath its parent row.
let groupedFormSubOptionIndent: CGFloat = 20

/// A primary row and a dependent sub-option as a single grouped-form "row": the
/// sub-option (and the hairline separating it) are indented beneath the primary
/// so the pair reads as a parent → child unit.
///
/// Pass one to ``makeGroupedFormCard(rows:)`` in place of two sibling rows, so
/// the card's full-width separators land only *around* the pair.
/// ``isSubOptionHidden`` collapses the sub-option and its hairline together,
/// for a child that is meaningless until the parent is on.
@MainActor
final class GroupedFormSubOptionGroup: NSStackView, GroupedFormFullBleedRow {
    private let hairlineRow: NSView
    private let subOptionRow: NSView

    init(primary: NSView, subOption: NSView) {
        hairlineRow = Self.indented(makeGroupedFormHairline())
        subOptionRow = Self.indented(subOption)
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

    /// Wraps `view` so it sits at the sub-option indent while its container
    /// still spans the card, which is what lets the stack hide it as a row.
    private static func indented(_ view: NSView) -> NSView {
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
}

@MainActor
func makeGroupedFormSubOptionGroup(
    primary: NSView, subOption: NSView
) -> GroupedFormSubOptionGroup {
    GroupedFormSubOptionGroup(primary: primary, subOption: subOption)
}

// MARK: - Row enablement

/// Applies an enabled/disabled appearance to a form row's control and the label
/// beside it, for a row whose enablement is decided per-refresh rather than by
/// the pane's read-only lock.
///
/// `isEnabled` alone is not enough: AppKit draws a disabled `NSSwitch` that is
/// **on** at its full accent fill (measured on macOS 27 developer beta 4), so
/// the row reads as live while it is inert. Dimming the control is what makes
/// it read as disabled, and graying the label keeps the pair consistent —
/// AppKit never fades a plain `NSTextField` for a neighboring control.
@MainActor
func applyGroupedFormRowEnabled(
    _ isEnabled: Bool, control: NSControl, label: NSTextField?
) {
    control.isEnabled = isEnabled
    control.alphaValue = isEnabled ? 1 : Alpha.disabled
    label?.textColor = isEnabled ? .labelColor : .disabledControlTextColor
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

/// A section-header hint marking the rows below as locked while the VM runs.
@MainActor
func makeGroupedFormLockHint() -> NSView {
    let icon = NSImageView(
        image: .systemSymbol("lock.fill", accessibilityDescription: groupedFormLockHintText))
    icon.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
    icon.contentTintColor = .secondaryLabelColor

    let label = NSTextField(labelWithString: groupedFormLockHintText)
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabelColor
    label.isSelectable = false

    let hint = NSStackView(views: [icon, label])
    hint.orientation = .horizontal
    hint.alignment = .centerY
    hint.spacing = Spacing.tight
    hint.toolTip = groupedFormLockHintText
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
func makeGroupedFormCaption(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .preferredFont(forTextStyle: .caption1)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 0
    label.isSelectable = false
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
}

/// A borderless button that reads as a link.
///
/// `.linkColor` barely desaturates when AppKit disables a borderless button, so
/// the tint is driven from `isEnabled` — otherwise a disabled link reads as
/// clickable and clicking it does nothing.
@MainActor
final class LinkButton: NSButton {
    override var isEnabled: Bool {
        didSet { contentTintColor = isEnabled ? .linkColor : .disabledControlTextColor }
    }
}

@MainActor
func makeLinkButton(_ title: String, target: AnyObject, action: Selector) -> NSButton {
    let button = LinkButton(frame: .zero)
    button.setButtonType(.momentaryPushIn)
    button.title = title
    button.target = target
    button.action = action
    button.isBordered = false
    button.bezelStyle = .badge
    button.font = .preferredFont(forTextStyle: .caption1)
    button.contentTintColor = .linkColor
    button.setContentHuggingPriority(.required, for: .horizontal)
    return button
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

@MainActor
func makeGroupedFormBanner(
    symbolName: String,
    tint: NSColor,
    message: String,
    trailingButtons: [NSButton] = []
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

    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Spacing.standard

    return makeGroupedFormBox(
        content: row,
        fill: tint.withAlphaComponent(0.1),
        border: tint.withAlphaComponent(0.3),
        borderWidth: 1,
        cornerRadius: 8,
        padding: 10
    )
}

// MARK: - Form atoms shared by the settings panels

/// Stacks a section's header, card and captions.
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

/// An info affordance for a section header, or for a panel header that states a
/// single-section category's name in its place.
@MainActor
func makeGroupedFormInfoButton(label: String, paragraphs: [InfoPopoverParagraph]) -> NSView {
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

/// Builds a toggle row: title, info button, and a trailing control.
///
/// `titleLabel` hands the freshly-built label back to the caller, for rows whose
/// text has to be restyled later.
@MainActor
func makeGroupedFormToggleRowWithInfo(
    _ title: String, control: NSControl, paragraphs: [InfoPopoverParagraph],
    titleLabel: ((NSTextField) -> Void)? = nil
) -> NSView {
    let label = NSTextField(labelWithString: title)
    label.font = Typography.body
    label.isSelectable = false
    label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    titleLabel?(label)

    let info = InfoButtonView()
    info.configure(label: title, paragraphs: paragraphs)

    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [label, info, spacer, control])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Spacing.small
    return row
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

@MainActor
func configureGroupedFormNumeric(
    field: NSTextField, stepper: NSStepper, min: Int, max: Int, value: Int,
    delegate: any NSTextFieldDelegate, target: AnyObject, stepperAction: Selector
) {
    let clamped = Swift.min(Swift.max(value, min), max)
    field.alignment = .right
    field.delegate = delegate
    field.integerValue = clamped
    field.widthAnchor.constraint(equalToConstant: 44).isActive = true

    stepper.controlSize = .small
    stepper.minValue = Double(min)
    stepper.maxValue = Double(max)
    stepper.increment = 1
    stepper.valueWraps = false
    stepper.integerValue = clamped
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

/// One attachment/share row: icon, title over subtitle, the read-only switch and
/// the eject button.
@MainActor
func makeGroupedFormListRow(
    icon: NSView, title: String, subtitle: NSTextField, id: UUID, readOnly: Bool,
    controlsEnabled: Bool, target: AnyObject, readOnlySelector: Selector,
    deleteSelector: Selector
) -> NSView {
    let titleLabel = NSTextField(labelWithString: title)
    titleLabel.font = Typography.body
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.maximumNumberOfLines = 1
    titleLabel.isSelectable = false

    let textStack = NSStackView(views: [titleLabel, subtitle])
    textStack.orientation = .vertical
    textStack.alignment = .leading
    textStack.spacing = Spacing.hairline

    let readOnlyToggle = makeGroupedFormReadOnlySwitch(
        id: id, isOn: readOnly, enabled: controlsEnabled, target: target,
        action: readOnlySelector)
    let readOnlyCaption = makeGroupedFormReadOnlyCaption()

    let eject = makeGroupedFormEjectButton(
        id: id, enabled: controlsEnabled, target: target, action: deleteSelector)

    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [icon, textStack, spacer, readOnlyToggle, readOnlyCaption, eject])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = Spacing.standard
    return row
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
