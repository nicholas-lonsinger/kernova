import AppKit
import os

/// One overview card: a header row naming the category and offering the
/// drill-in, the category's current facts as key-value rows, any live switches
/// it carries, and a closing full-width line.
///
/// The card holds no state of its own — every value comes from
/// ``configure(rows:toggles:note:showsLockHint:warning:)``, and a flipped switch
/// is reported to the owner rather than written here.
@MainActor
final class VMOverviewCardView: NSView {
    private static let logger = Logger(subsystem: "app.kernova", category: "VMOverviewCardView")

    /// Fires when the header row or its chevron is activated.
    var onShow: (() -> Void)?
    /// Fires when one of the card's switches is flipped.
    var onToggle: ((VMOverviewToggle, Bool) -> Void)?

    let category: VMSettingsCategory

    private let headerRow: NSStackView
    private let lockHint: NSView
    private let warningGlyph: NSImageView
    /// The switch rows this card can show, built once so a rebuild of the card's
    /// values never drops a control mid-interaction.
    private var toggleRows: [VMOverviewToggle: ToggleRow] = [:]
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
    }

    init(category: VMSettingsCategory, toggles: [VMOverviewToggle]) {
        self.category = category
        lockHint = makeGroupedFormLockHint()
        warningGlyph = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: ""))
        let title = NSTextField(labelWithString: category.title)
        title.font = .preferredFont(forTextStyle: .headline)
        title.isSelectable = false
        let icon = NSImageView(
            image: .systemSymbol(category.symbolName, accessibilityDescription: ""))
        icon.contentTintColor = .secondaryLabelColor
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let chevron = NSButton()
        chevron.image = .systemSymbol("chevron.right", accessibilityDescription: "")
        chevron.imagePosition = .imageOnly
        chevron.isBordered = false
        chevron.contentTintColor = .secondaryLabelColor
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headerRow = NSStackView(views: [icon, title, spacer, warningGlyph, lockHint, chevron])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = Spacing.small
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        warningGlyph.contentTintColor = .systemYellow
        warningGlyph.symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
        warningGlyph.setContentHuggingPriority(.required, for: .horizontal)
        warningGlyph.isHidden = true
        lockHint.isHidden = true

        // The chevron is the affordance; the whole header row takes the click so
        // the target is not a 12pt glyph. It names the destination rather than
        // an action — a locked category is viewable, not editable.
        let showLabel = "Show \(category.title)"
        chevron.toolTip = showLabel
        chevron.setAccessibilityLabel(showLabel)
        chevron.target = self
        chevron.action = #selector(showTapped)
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

    /// Renders `rows`, `toggles` and `note`, rebuilding the card body only when
    /// the set of lines it shows changed.
    func configure(
        rows: [VMOverviewSummary.Row], toggles: [VMOverviewSummary.ToggleState], note: String?,
        showsLockHint: Bool, warning: String?
    ) {
        lockHint.isHidden = !showsLockHint
        warningGlyph.isHidden = warning == nil
        warningGlyph.toolTip = warning
        warningGlyph.setAccessibilityLabel(warning)

        let snapshot = Rendered(rows: rows, toggles: toggles.map(\.toggle), note: note)
        if snapshot != rendered {
            rendered = snapshot
            rebuild(rows: rows, toggles: snapshot.toggles, note: note)
        }
        for state in toggles {
            guard let entry = toggleRows[state.toggle] else { continue }
            entry.control.state = state.isOn ? .on : .off
            applyGroupedFormRowEnabled(state.isEnabled, control: entry.control, label: entry.label)
        }
    }

    private func rebuild(rows: [VMOverviewSummary.Row], toggles: [VMOverviewToggle], note: String?) {
        let valueRows = rows.map {
            makeGroupedFormCardRow($0.label, control: makeGroupedFormValueLabel($0.value))
        }
        let toggleViews = toggles.compactMap { toggleRows[$0]?.row }
        let noteRows = note.map { [Self.makeNoteRow($0)] } ?? []
        let built = makeGroupedFormCard(rows: [headerRow] + valueRows + toggleViews + noteRows)
        card?.removeFromSuperview()
        addFullSizeSubview(built)
        card = built
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
}
