import AppKit

/// Leaf-row cell for an arrival — a create, clone or import still writing its
/// bundle: a spinner in the icon slot, the name, and the arrival's label as the
/// tooltip, which follows its stage ("Cancelling…").
@MainActor
final class SidebarArrivalRowCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarArrivalRowCell")

    private weak var arrival: VMArrival?
    private var observation: ObservationLoop?

    private let spinner = NSProgressIndicator()
    private let nameLabel = NSTextField(labelWithString: "")

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

        let row = NSStackView(views: [spinner, nameLabel])
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

    func configure(arrival: VMArrival) {
        self.arrival = arrival
        nameLabel.stringValue = arrival.name
        spinner.startAnimation(nil)
        applyLabel()
        observation?.cancel()
        observation = observeRecurring(
            track: { [weak self] in _ = self?.arrival?.displayLabel },
            apply: { [weak self] in self?.applyLabel() })
    }

    private func applyLabel() {
        toolTip = arrival?.displayLabel
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        observation?.cancel()
        observation = nil
        arrival = nil
        spinner.stopAnimation(nil)
        toolTip = nil
    }
}
