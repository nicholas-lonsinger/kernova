import AppKit

/// Popover content shown by an attachment row's "Get Info" context-menu item
/// (storage disks and removable media alike).
///
/// Built bottom-up in `loadView()` from `CalloutStyle` tokens and the callout
/// atom factories — no shared container base class (mirrors
/// ``MissingAttachmentPopoverContentViewController``). Takes a value snapshot,
/// not the live `VMInstance`, so it stays dumb and is trivial to construct.
@MainActor
final class AttachmentInfoPopoverContentViewController: NSViewController {
    private let label: String
    private let fileName: String
    private let fullPath: String
    private let onDiskText: String
    private let allocatedText: String
    private let readOnly: Bool
    private let busText: String
    private let createdText: String

    init(
        label: String,
        fileName: String,
        fullPath: String,
        onDiskText: String,
        allocatedText: String,
        readOnly: Bool,
        busText: String,
        createdText: String
    ) {
        self.label = label
        self.fileName = fileName
        self.fullPath = fullPath
        self.onDiskText = onDiskText
        self.allocatedText = allocatedText
        self.readOnly = readOnly
        self.busText = busText
        self.createdText = createdText
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentInfoPopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeCalloutHeadline(label))
        stack.addArrangedSubview(makeFactsGrid())
        stack.addArrangedSubview(keyLabel("Location"))
        stack.addArrangedSubview(makeCalloutCode(fullPath))

        container.addSubview(stack)
        let padding = CalloutStyle.padding
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding),
            container.widthAnchor.constraint(equalToConstant: CalloutStyle.width),
        ])

        view = container
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Re-pin so `NSPopover` resizes its frame to the measured stack height.
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
    }

    /// Two-column key/value grid of the disk's short facts.
    private func makeFactsGrid() -> NSGridView {
        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = Spacing.hairline
        grid.columnSpacing = Spacing.standard
        grid.addRow(with: [keyLabel("File"), valueLabel(fileName)])
        grid.addRow(with: [keyLabel("On disk"), valueLabel(onDiskText)])
        grid.addRow(with: [keyLabel("Allocated"), valueLabel(allocatedText)])
        grid.addRow(with: [keyLabel("Read only"), valueLabel(readOnly ? "Yes" : "No")])
        grid.addRow(with: [keyLabel("Bus"), valueLabel(busText)])
        grid.addRow(with: [keyLabel("Created"), valueLabel(createdText)])
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 1).xPlacement = .leading
        return grid
    }

    private func keyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = CalloutStyle.bodyFont
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func valueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = CalloutStyle.bodyFont
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.isSelectable = true
        return label
    }
}
