import AppKit

/// Popover content shown when the user clicks a missing-attachment warning
/// icon in a storage / removable-media row.
///
/// Built bottom-up in `loadView()` using `CalloutStyle` tokens and the
/// `makeCalloutHeadline` / `makeCalloutBody` atom factories — no shared
/// container base class.
@MainActor
final class MissingAttachmentPopoverContentViewController: NSViewController {
    private let path: String

    init(path: String) {
        self.path = path
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("MissingAttachmentPopoverContentViewController does not support NSCoder")
    }

    override func loadView() {
        let container = NSView()

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CalloutStyle.verticalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeHeader())
        stack.addArrangedSubview(makeCalloutBody("Kernova can't find:", color: .labelColor))
        stack.addArrangedSubview(makePathLabel())
        stack.addArrangedSubview(
            makeCalloutBody("It may have been moved, renamed, or its volume unmounted.")
        )

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
        // Re-pin so `NSPopover` resizes its frame to the measured stack
        // height under the configured width.
        let fittingSize = view.fittingSize
        if preferredContentSize != fittingSize {
            preferredContentSize = fittingSize
        }
    }

    /// Header row: red warning icon + "File Missing" headline.
    private func makeHeader() -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY

        let icon = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: "")
        )
        icon.contentTintColor = .systemRed

        let title = makeCalloutHeadline("File Missing")

        header.setViews([icon, title], in: .leading)
        return header
    }

    /// Monospaced, selectable, character-wrapping path label.
    ///
    /// Uses `.byCharWrapping` so long path components break mid-word at the
    /// popover's edge without truncating or being mutated (the alternative,
    /// injecting zero-width spaces, would corrupt copy-to-clipboard).
    private func makePathLabel() -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: path)
        label.font = .monospacedSystemFont(
            ofSize: NSFont.systemFontSize - 1, weight: .regular
        )
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = CalloutStyle.bodyWidth
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.isSelectable = true
        return label
    }
}
