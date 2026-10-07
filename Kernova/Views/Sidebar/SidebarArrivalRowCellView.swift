import AppKit

/// Leaf-row cell for an arrival — a create, clone or import still writing its
/// bundle: a spinner in the icon slot, the name, the detail line Show Details
/// adds, and the arrival's label as the tooltip, which follows its stage
/// ("Cancelling…").
@MainActor
final class SidebarArrivalRowCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarArrivalRowCell")

    private weak var arrival: VMArrival?
    /// Reads the row's detail line, live, `nil` when rows show none.
    private var detail: (() -> String?)?
    private var observation: ObservationLoop?

    private let spinner = NSProgressIndicator()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        buildLayout()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SidebarArrivalRowCellView does not support NSCoder")
    }

    private func buildLayout() {
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.setContentHuggingPriority(.required, for: .horizontal)

        nameLabel.font = Typography.body
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Set like ``SidebarVMRowCellView``'s detail line.
        detailLabel.font = SidebarVMRowCellView.detailFont
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.isHidden = true

        let nameColumn = NSStackView(views: [nameLabel, detailLabel])
        nameColumn.orientation = .vertical
        nameColumn.alignment = .leading
        nameColumn.spacing = 0

        let row = NSStackView(views: [spinner, nameColumn])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        textField = nameLabel

        // The same insets and icon slot as ``SidebarVMRowCellView``, so the name
        // does not shift when the arrival becomes its VM's row.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 20),
        ])
    }

    func configure(arrival: VMArrival, detail: @escaping () -> String?) {
        self.arrival = arrival
        self.detail = detail
        nameLabel.stringValue = arrival.name
        spinner.startAnimation(nil)
        applyLiveState()
        observation?.cancel()
        observation = observeRecurring(
            track: { [weak self] in
                _ = self?.arrival?.displayLabel
                _ = self?.detail?()
            },
            apply: { [weak self] in self?.applyLiveState() })
    }

    private func applyLiveState() {
        toolTip = arrival?.displayLabel
        let detailText = detail?()
        detailLabel.stringValue = detailText ?? ""
        detailLabel.isHidden = detailText == nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
        observation = nil
        arrival = nil
        detail = nil
        detailLabel.isHidden = true
        spinner.stopAnimation(nil)
        toolTip = nil
    }
}
