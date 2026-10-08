import AppKit

/// Group-row cell for a sidebar section header (e.g. "Virtual Machines") or a
/// group header within a section.
///
/// `NSOutlineView` in `.sourceList` style draws the group-row background and the
/// hover disclosure control; this cell supplies the title, and for a section
/// that filters, how many VMs it shows and the button opening its menu.
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

    private let label = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private(set) var filterButton: NSButton?
    private var filterButtonAction: ((NSButton) -> Void)?
    private var filterButtonTrailing: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)

        for field in [label, countLabel] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.isSelectable = false
            field.lineBreakMode = .byTruncatingTail
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            field.textColor = .secondaryLabelColor
            addSubview(field)
        }
        countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        countLabel.textColor = .tertiaryLabelColor
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
    /// lists nothing and says why — and, for a section that filters,
    /// `filtering`, with `onFilterButton` called with the button when it is
    /// clicked.
    func configure(
        title: String, notice: String? = nil, filtering: Filtering? = nil,
        onFilterButton: ((NSButton) -> Void)? = nil
    ) {
        label.stringValue = title
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
}
