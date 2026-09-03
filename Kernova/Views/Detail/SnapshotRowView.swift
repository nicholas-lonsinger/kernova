import AppKit

/// Value snapshot of one snapshot row's rendered appearance, so a pass that
/// changed nothing about it skips the rebuild.
struct SnapshotRowModel: Identifiable, Equatable {
    let snapshot: VMSnapshot
    let isCurrent: Bool
    /// `true` for the snapshot Ephemeral Mode returns this VM to.
    let isBaseline: Bool
    let canRevert: Bool
    let canDelete: Bool

    var id: UUID { snapshot.id }

    /// The row's trailing marker — the two roles read as one caption when a
    /// snapshot holds both, which is where an ephemeral VM rests.
    var markerText: String {
        switch (isBaseline, isCurrent) {
        case (true, true): "Baseline \u{00B7} Current"
        case (true, false): "Baseline"
        case (false, true): "Current"
        case (false, false): ""
        }
    }

    /// What each marker role means, so the caption doesn't have to spell it out.
    var markerToolTip: String? {
        let current = "The state this VM was last taken from or reverted to"
        let baseline = "The snapshot this VM returns to at every shutdown"
        switch (isBaseline, isCurrent) {
        case (true, true): return "\(baseline). \(current)."
        case (true, false): return baseline
        case (false, true): return current
        case (false, false): return nil
        }
    }
}

/// A single snapshot list row: the icon, the editable name and note over the
/// date/size subtitle, the Baseline/Current marker, Revert, and the ••• menu.
///
/// The owner wires ``icon`` and ``titleView``'s callbacks and supplies the
/// target for the two buttons; everything the row displays arrives through
/// ``update(_:subtitle:)``.
@MainActor
final class SnapshotRowView: NSView {
    let snapshotID: UUID
    /// The leading icon, exposed so the owner can wire its click and anchor the
    /// Get Info popover to it.
    let icon = AttachmentIconButton()
    /// The name-and-note line, exposed so the owner can wire its edit callbacks
    /// and start an edit from a menu item.
    let titleView: EditableRowTitleView
    /// The date/size caption, exposed so a size read landing later can fill it
    /// in without a rebuild.
    let subtitleField = NSTextField(labelWithString: "")

    private let markerLabel = NSTextField(labelWithString: "")
    private let revertButton: NSButton

    init(snapshotID: UUID, target: AnyObject, revertAction: Selector, moreAction: Selector) {
        self.snapshotID = snapshotID
        self.titleView = EditableRowTitleView(itemID: snapshotID, name: "", controlsEnabled: true)
        self.revertButton = makeLinkButton("Revert", target: target, action: revertAction)
        super.init(frame: .zero)
        buildLayout(target: target, moreAction: moreAction)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SnapshotRowView does not support NSCoder")
    }

    /// Updates what the row displays in place, without a teardown/rebuild.
    func update(_ model: SnapshotRowModel, subtitle: String) {
        titleView.update(
            name: model.snapshot.name, notes: model.snapshot.notes, controlsEnabled: true)
        subtitleField.stringValue = subtitle
        markerLabel.stringValue = model.markerText
        markerLabel.toolTip = model.markerToolTip
        markerLabel.isHidden = model.markerText.isEmpty
        revertButton.isEnabled = model.canRevert
    }

    private func buildLayout(target: AnyObject, moreAction: Selector) {
        translatesAutoresizingMaskIntoConstraints = false

        icon.configure(systemName: "clock.arrow.circlepath", missingPath: nil)

        subtitleField.font = .preferredFont(forTextStyle: .caption1)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 1
        subtitleField.isSelectable = false
        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [titleView, subtitleField])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = Spacing.hairline
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            titleView.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            titleView.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
            subtitleField.leadingAnchor.constraint(equalTo: textStack.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: textStack.trailingAnchor),
        ])

        markerLabel.font = .preferredFont(forTextStyle: .caption1)
        markerLabel.textColor = .secondaryLabelColor
        markerLabel.isSelectable = false

        revertButton.font = Typography.body
        revertButton.identifier = NSUserInterfaceItemIdentifier(snapshotID.uuidString)

        let menuButton = NSButton()
        menuButton.image = .systemSymbol("ellipsis.circle", accessibilityDescription: "More")
        menuButton.imagePosition = .imageOnly
        menuButton.isBordered = false
        menuButton.contentTintColor = .secondaryLabelColor
        menuButton.toolTip = "More"
        menuButton.identifier = NSUserInterfaceItemIdentifier(snapshotID.uuidString)
        menuButton.target = target
        menuButton.action = moreAction

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for accessory in [icon, markerLabel, revertButton, menuButton] as [NSView] {
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let row = NSStackView(views: [
            icon, textStack, spacer, markerLabel, revertButton, menuButton,
        ])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = Spacing.standard
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}
