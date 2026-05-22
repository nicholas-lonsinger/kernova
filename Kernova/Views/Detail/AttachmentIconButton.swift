import AppKit

/// Leading icon for a storage / removable-media row.
///
/// When the file backing the row is missing, the icon swaps to a red
/// triangle button that opens an ``NSPopover`` containing the full
/// untruncated path. Otherwise the icon renders the supplied SF Symbol
/// in secondary label color.
@MainActor
final class AttachmentIconButton: NSView {
    private let warningButton = NSButton()
    private let plainIcon = NSImageView()
    private let popoverPresenter = PopoverPresenter()
    private var currentPath: String?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 20),
            heightAnchor.constraint(equalToConstant: 20),
        ])

        plainIcon.translatesAutoresizingMaskIntoConstraints = false
        plainIcon.contentTintColor = .secondaryLabelColor
        plainIcon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(plainIcon)
        NSLayoutConstraint.activate([
            plainIcon.leadingAnchor.constraint(equalTo: leadingAnchor),
            plainIcon.trailingAnchor.constraint(equalTo: trailingAnchor),
            plainIcon.topAnchor.constraint(equalTo: topAnchor),
            plainIcon.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        warningButton.translatesAutoresizingMaskIntoConstraints = false
        warningButton.bezelStyle = .accessoryBarAction
        warningButton.isBordered = false
        warningButton.image = .systemSymbol(
            "exclamationmark.triangle.fill", accessibilityDescription: "File missing — show details"
        )
        warningButton.contentTintColor = .systemRed
        warningButton.target = self
        warningButton.action = #selector(showMissingPopover(_:))
        warningButton.imageScaling = .scaleProportionallyUpOrDown
        warningButton.toolTip = "File missing"
        warningButton.setAccessibilityLabel("File missing — show details")
        warningButton.isHidden = true
        addSubview(warningButton)
        NSLayoutConstraint.activate([
            warningButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            warningButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            warningButton.topAnchor.constraint(equalTo: topAnchor),
            warningButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentIconButton does not support NSCoder")
    }

    /// Configure the icon.
    ///
    /// Pass `missingPath` to render the warning state.
    func configure(systemName: String, missingPath: String?) {
        currentPath = missingPath
        if missingPath != nil {
            warningButton.isHidden = false
            plainIcon.isHidden = true
        } else {
            warningButton.isHidden = true
            plainIcon.isHidden = false
            plainIcon.image = .systemSymbol(systemName, accessibilityDescription: systemName)
        }
    }

    @objc private func showMissingPopover(_ sender: Any?) {
        guard let path = currentPath else { return }
        let content = MissingAttachmentPopoverContentViewController(path: path)
        popoverPresenter.show(content: content, from: warningButton, preferredEdge: .minY)
    }
}
