import AppKit

/// Leading icon for a storage / removable-media row.
///
/// When the file backing the row is missing, the icon swaps to a red
/// triangle button that opens an ``NSPopover`` containing the full
/// untruncated path. Otherwise the icon renders the supplied SF Symbol
/// in secondary label color.
///
/// Replaces the SwiftUI `AttachmentIcon` from
/// `Kernova/Views/Detail/AttachmentIcon.swift`.
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
            plainIcon.image = .systemSymbol(systemName, accessibilityDescription: nil ?? "")
        }
    }

    @objc private func showMissingPopover(_ sender: Any?) {
        guard let path = currentPath else { return }
        let content = makeMissingPopoverContent(path: path)
        popoverPresenter.show(content: content, from: warningButton, preferredEdge: .maxY)
    }

    private func makeMissingPopoverContent(path: String) -> NSViewController {
        let vc = CalloutContentViewController()

        let headerStack = NSStackView()
        headerStack.orientation = .horizontal
        headerStack.spacing = 6
        headerStack.alignment = .centerY
        let icon = NSImageView(
            image: .systemSymbol("exclamationmark.triangle.fill", accessibilityDescription: "")
        )
        icon.contentTintColor = .systemRed
        let title = NSTextField(labelWithString: "File Missing")
        title.font = .preferredFont(forTextStyle: .headline)
        headerStack.setViews([icon, title], in: .leading)
        vc.addArrangedContent(headerStack)

        vc.addBody("Kernova can't find:", color: .labelColor)

        let pathLabel = NSTextField(wrappingLabelWithString: path)
        pathLabel.font = .monospacedSystemFont(
            ofSize: NSFont.systemSize - 1, weight: .regular
        )
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.preferredMaxLayoutWidth = vc.bodyWidth
        pathLabel.maximumNumberOfLines = 0
        pathLabel.lineBreakMode = .byCharWrapping
        pathLabel.isSelectable = true
        vc.addArrangedContent(pathLabel)

        vc.addBody("It may have been moved, renamed, or its volume unmounted.")
        return vc
    }
}

/// Builds a caption-sized attachment-subtitle label.
///
/// Prefixes "Missing —" in bold red when the file is missing.
@MainActor
func makeAttachmentSubtitleLabel(path: String, isMissing: Bool) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = .preferredFont(forTextStyle: .caption1)
    label.lineBreakMode = .byTruncatingMiddle
    label.maximumNumberOfLines = 1
    label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    if isMissing {
        let attributed = NSMutableAttributedString(
            string: "Missing — ",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.systemRed,
            ]
        )
        attributed.append(
            NSAttributedString(
                string: path,
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.systemRed,
                ]
            )
        )
        label.attributedStringValue = attributed
    } else {
        label.stringValue = path
        label.textColor = .secondaryLabelColor
    }
    return label
}

extension NSFont {
    /// Convenience to mirror SwiftUI's `NSFont.systemFontSize` callsite when
    /// computing slightly-smaller monospaced fonts.
    nonisolated static var systemSize: CGFloat { NSFont.systemFontSize }
}
