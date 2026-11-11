import AppKit

/// Group-row cell for a sidebar section header (e.g. "Virtual Machines") or a
/// group header within a section.
///
/// `NSOutlineView` in `.sourceList` style draws the group-row background and the
/// hover disclosure control; this cell supplies the title, and for a section
/// that filters, how many VMs it shows and the button opening its menu.
///
/// A smart group's or folder's title is renamed in place: the controller opens
/// the box with ``beginRename(holding:)`` and ends it with ``endRename()``, and
/// the shared ``InlineEditableLabel`` commits on Return/focus-loss and cancels
/// on Escape.
@MainActor
final class SidebarGroupHeaderCellView: NSTableCellView {
    /// What a filtering section's header shows beside its title.
    struct Filtering: Equatable {
        /// How many VMs the section lists — "3 of 7" while a filter or the
        /// search narrows it — or `nil` to show none.
        let countText: String?
        /// Whether any filter is on, which fills the button's symbol.
        let isActive: Bool
        /// The active filters, named for VoiceOver; `nil` when none is.
        let activeDescription: String?
        /// The button's name, for its tooltip and VoiceOver.
        var buttonLabel = SidebarViewMenu.accessibilityLabel
    }

    /// What committing and cancelling a rename of the title run.
    struct Renaming {
        /// Runs with the typed text; the `Bool` is `true` when Return ended
        /// the edit.
        let commit: (String, Bool) -> Void
        let cancel: () -> Void
    }

    /// The title, and the rename box it becomes.
    ///
    /// Clicks belong to the enclosing outline view, as a VM row's name
    /// label's do.
    private let label = InlineEditableLabel(
        text: "", font: .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold),
        textColor: .secondaryLabelColor, placeholder: "", controlsEnabled: false,
        clickHandling: .delegatedToEnclosingView)
    private let countLabel = NSTextField(labelWithString: "")
    private var renaming: Renaming?
    private(set) var filterButton: NSButton?
    private var filterButtonAction: ((NSButton) -> Void)?
    private var filterButtonTrailing: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)

        label.onEditCommitted = { [weak self] text, endedByReturn in self?.renaming?.commit(text, endedByReturn) }
        label.onEditCancelled = { [weak self] in self?.renaming?.cancel() }
        addSubview(label)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isSelectable = false
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .tertiaryLabelColor
        addSubview(countLabel)
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        countLabel.isHidden = true
        textField = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            countLabel.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarGroupHeaderCellView does not support NSCoder")
    }

    /// Shows `title` — disabled, with `notice` on hover, for a section that
    /// lists nothing and says why — renamed in place through `renaming`, and,
    /// for a section that filters, `filtering`, with `onFilterButton` called
    /// with the button when it is clicked.
    func configure(
        title: String, notice: String? = nil, renaming: Renaming? = nil, filtering: Filtering? = nil,
        onFilterButton: ((NSButton) -> Void)? = nil
    ) {
        // Self-guards mid-rename, leaving the open box's text alone.
        label.update(text: title, controlsEnabled: renaming != nil)
        self.renaming = renaming
        label.textColor = notice == nil ? .secondaryLabelColor : .disabledControlTextColor
        toolTip = notice
        countLabel.stringValue = filtering?.countText ?? ""
        countLabel.isHidden = filtering?.countText == nil
        filterButtonAction = onFilterButton
        guard let filtering else {
            filterButton?.isHidden = true
            return
        }
        let button = filterButton ?? makeFilterButton()
        button.isHidden = false
        let symbol =
            filtering.isActive
            ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
        button.image = NSImage.systemSymbol(symbol, accessibilityDescription: filtering.buttonLabel)
        button.contentTintColor = filtering.isActive ? .controlAccentColor : .secondaryLabelColor
        button.toolTip = filtering.buttonLabel
        button.setAccessibilityLabel(filtering.buttonLabel)
        button.setAccessibilityValue(filtering.activeDescription ?? "No filters")
    }

    private func makeFilterButton() -> NSButton {
        let button = NSButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        button.target = self
        button.action = #selector(filterButtonClicked(_:))
        addSubview(button)
        let trailing = button.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -(trailingReserve + Self.filterButtonGap))
        filterButtonTrailing = trailing
        NSLayoutConstraint.activate([
            trailing,
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            countLabel.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -4),
        ])
        filterButton = button
        return button
    }

    /// How far the row's Show/Hide control reaches in from this cell's
    /// trailing edge, which the filter button stays clear of.
    ///
    /// The source list lays the cell out under that control rather than beside
    /// it, so the row view, which positions both, reports it
    /// (``SidebarTableRowView``).
    var trailingReserve: CGFloat = 0 {
        didSet {
            guard trailingReserve != oldValue else { return }
            filterButtonTrailing?.constant = -(trailingReserve + Self.filterButtonGap)
        }
    }

    private static let filterButtonGap: CGFloat = 4

    @objc private func filterButtonClicked(_ sender: NSButton) {
        filterButtonAction?(sender)
    }

    // MARK: - Inline rename

    /// `true` while the title is in its editable rename state.
    var isRenaming: Bool { label.isEditing }

    /// Opens the rename box on the title, holding `draft` in place of it when
    /// one is given.
    func beginRename(holding draft: String? = nil) {
        label.beginEditing(holding: draft)
    }

    /// Ends a live rename through the commit path, so the in-flight text lands.
    func endRename() {
        label.endEditing()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Silently: the typed name belongs to the section the cell used to
        // show.
        label.abandonEditing()
        renaming = nil
    }
}
