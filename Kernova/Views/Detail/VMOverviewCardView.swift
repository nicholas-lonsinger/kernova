import AppKit
import os

/// One overview card: a header row naming the category and offering the
/// drill-in, the category's current facts as key-value rows, any live switches
/// it carries, a closing full-width line, and the command it offers at its foot.
///
/// The card holds no state of its own — every value comes from
/// ``configure(rows:toggles:note:action:headerSummary:showsLockHint:warning:)``,
/// and a flipped switch is reported to the owner rather than written here.
@MainActor
final class VMOverviewCardView: NSView {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMOverviewCardView")

    /// Fires when the header row or its Edit button is activated.
    var onShow: (() -> Void)?
    /// Fires when one of the card's switches is flipped.
    var onToggle: ((VMOverviewToggle, Bool) -> Void)?
    /// Fires when the card's foot command is run.
    var onAction: ((VMOverviewAction) -> Void)?

    let category: VMSettingsCategory

    private let headerRow: NSStackView
    /// The count and footprint beside the title, hidden while the category has
    /// none to state.
    private let headerSummaryLabel: NSTextField
    /// The lock claim: a glyph beside the scoped text naming what actually
    /// locks, so it stands beside live controls without contradicting them.
    private let lockHint: NSView
    private let warningGlyph: NSImageView
    /// The switch rows this card can show, built once so a rebuild of the card's
    /// values never drops a control mid-interaction.
    private var toggleRows: [VMOverviewToggle: ToggleRow] = [:]
    /// The foot command's button, built on first use and reused after.
    private var actionButton: NSButton?
    private var card: NSView?
    private var rendered: Rendered?

    private struct ToggleRow {
        let row: NSView
        let control: NSSwitch
        let label: NSTextField
    }

    /// What the card's rows were last built from; the values themselves are
    /// painted into freshly built rows, so a change to either rebuilds.
    private struct Rendered: Equatable {
        let rows: [VMOverviewSummary.Row]
        let toggles: [VMOverviewToggle]
        let note: String?
        let action: VMOverviewAction?
    }

    init(category: VMSettingsCategory, toggles: [VMOverviewToggle]) {
        self.category = category
        lockHint = Self.makeLockHint(category.lockHint)
        warningGlyph = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: ""))
        headerSummaryLabel = NSTextField(labelWithString: "")
        let title = NSTextField(labelWithString: category.title)
        title.font = .preferredFont(forTextStyle: .headline)
        title.isSelectable = false
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let icon = NSImageView(
            image: .systemSymbol(category.symbolName, accessibilityDescription: ""))
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow = NSStackView(views: [
            icon, title, headerSummaryLabel, spacer, warningGlyph, lockHint,
        ])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Spacing.small
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        headerSummaryLabel.font = .preferredFont(forTextStyle: .caption1)
        headerSummaryLabel.textColor = .secondaryLabelColor
        headerSummaryLabel.lineBreakMode = .byTruncatingTail
        headerSummaryLabel.isSelectable = false
        // A squeezed card gives up the summary before the title it follows.
        headerSummaryLabel.setContentCompressionResistancePriority(
            .defaultLow, for: .horizontal)
        headerSummaryLabel.isHidden = true
        warningGlyph.contentTintColor = .systemYellow
        warningGlyph.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
        warningGlyph.setContentHuggingPriority(.required, for: .horizontal)
        warningGlyph.isHidden = true
        lockHint.isHidden = true

        // The Edit button is the affordance; the whole header row takes the
        // click so the target is not a caption-sized label. It names the
        // destination rather than an action — a locked category is viewable,
        // not editable.
        let edit = makeTintedButton(
            "Edit", tint: .controlAccentColor, font: Typography.body,
            trailingSymbolName: "chevron.right", target: self,
            action: #selector(showTapped))
        let showLabel = "Show \(category.title)"
        edit.toolTip = showLabel
        edit.setAccessibilityLabel(showLabel)
        headerRow.addArrangedSubview(edit)
        let click = NSClickGestureRecognizer(target: self, action: #selector(showTapped))
        headerRow.addGestureRecognizer(click)

        for toggle in toggles {
            var label = NSTextField()
            let control = NSSwitch()
            control.controlSize = .small
            control.identifier = NSUserInterfaceItemIdentifier(toggle.rawValue)
            control.target = self
            control.action = #selector(toggleFlipped(_:))
            let row = makeGroupedFormCardRow(
                toggle.title, control: control, titleLabel: { label = $0 })
            toggleRows[toggle] = ToggleRow(row: row, control: control, label: label)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("VMOverviewCardView does not support NSCoder")
    }

    /// Renders everything the card states, rebuilding its body only when the set
    /// of lines it shows changed.
    func configure(
        rows: [VMOverviewSummary.Row], toggles: [VMOverviewSummary.ToggleState], note: String?,
        action: VMOverviewSummary.ActionState?, headerSummary: String?, showsLockHint: Bool,
        warning: String?
    ) {
        headerSummaryLabel.stringValue = headerSummary ?? ""
        headerSummaryLabel.isHidden = headerSummary == nil
        lockHint.isHidden = !showsLockHint
        warningGlyph.isHidden = warning == nil
        warningGlyph.toolTip = warning
        warningGlyph.setAccessibilityLabel(warning)

        let snapshot = Rendered(
            rows: rows, toggles: toggles.map(\.toggle), note: note, action: action?.action)
        if snapshot != rendered {
            rendered = snapshot
            rebuild(rows: rows, toggles: snapshot.toggles, note: note, action: action?.action)
        }
        for state in toggles {
            guard let entry = toggleRows[state.toggle] else { continue }
            entry.control.state = state.isOn ? .on : .off
            applyGroupedFormRowEnabled(state.isEnabled, control: entry.control, label: entry.label)
        }
        actionButton?.isEnabled = action?.isEnabled ?? false
    }

    private func rebuild(
        rows: [VMOverviewSummary.Row], toggles: [VMOverviewToggle], note: String?,
        action: VMOverviewAction?
    ) {
        actionButton = nil
        let valueRows = rows.map { makeValueRow($0) }
        let toggleViews = toggles.compactMap { toggleRows[$0]?.row }
        let noteRows = note.map { [Self.makeNoteRow($0)] } ?? []
        let actionRows = action.map { [makeActionRow($0)] } ?? []
        let built = makeGroupedFormCard(
            rows: [headerRow] + valueRows + toggleViews + noteRows + actionRows)
        card?.removeFromSuperview()
        addFullSizeSubview(built)
        card = built
    }

    /// One key-value line, with the copy affordance its value carries.
    ///
    /// A key here can be model-supplied and unbounded — the Network row is named
    /// by the mode, which carries a host interface's name. So the key gives up
    /// its width first (keeping the whole of it in its tooltip) and the value,
    /// which is what the row was read for, stays whole.
    private func makeValueRow(_ row: VMOverviewSummary.Row) -> NSView {
        let value = makeGroupedFormValueLabel(row.value)
        let yieldFirst: (NSTextField) -> Void = { label in
            label.maximumNumberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = row.label
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        guard let copy = row.copy else {
            return makeGroupedFormCardRow(row.label, control: value, titleLabel: yieldFirst)
        }
        let button = CopyValueButton(value: copy.value)
        button.image = .systemSymbol("doc.on.doc", accessibilityDescription: copy.name)
        button.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = copy.name
        button.setAccessibilityLabel(copy.name)
        button.target = self
        button.action = #selector(copyTapped(_:))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        let control = NSStackView(views: [value, button])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = Spacing.tight
        return makeGroupedFormCardRow(row.label, control: control, titleLabel: yieldFirst)
    }

    /// The card's foot command: a borderless accent-tinted button on a row of
    /// its own.
    private func makeActionRow(_ action: VMOverviewAction) -> NSView {
        let button = makeTintedButton(
            action.title, tint: .controlAccentColor, font: Typography.body, target: self,
            action: #selector(actionTapped))
        button.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        actionButton = button
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [button, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.standard
        return row
    }

    /// The card's lock claim: a `lock.fill` beside the scoped text, or an empty
    /// placeholder for a category nothing locks.
    private static func makeLockHint(_ text: String?) -> NSView {
        guard let text else { return NSView() }
        let icon = NSImageView(image: .systemSymbol("lock.fill", accessibilityDescription: text))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

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
        return hint
    }

    /// The card's closing line: one secondary sentence spanning the row, with no
    /// key column of its own.
    private static func makeNoteRow(_ text: String) -> NSView {
        let label = makeGroupedFormValueLabel(text)
        label.lineBreakMode = .byTruncatingTail
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.standard
        return row
    }

    @objc private func showTapped() {
        onShow?()
    }

    @objc private func toggleFlipped(_ sender: NSSwitch) {
        guard let raw = sender.identifier?.rawValue, let toggle = VMOverviewToggle(rawValue: raw)
        else {
            Self.logger.fault("Overview switch carries no toggle identity")
            assertionFailure("Overview switch carries no toggle identity")
            return
        }
        onToggle?(toggle, sender.state == .on)
    }

    @objc private func actionTapped(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let action = VMOverviewAction(rawValue: raw)
        else {
            Self.logger.fault("Overview action button carries no action identity")
            assertionFailure("Overview action button carries no action identity")
            return
        }
        onAction?(action)
    }

    @objc private func copyTapped(_ sender: NSButton) {
        guard let button = sender as? CopyValueButton else {
            Self.logger.fault("Overview copy button carries no value")
            assertionFailure("Overview copy button carries no value")
            return
        }
        copyToPasteboard(button.value)
    }
}

/// A copy button carrying the text it writes, so the row's value travels with
/// the control rather than being looked up again at click time.
@MainActor
final class CopyValueButton: NSButton {
    let value: String

    init(value: String) {
        self.value = value
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CopyValueButton does not support NSCoder")
    }
}
