import AppKit

/// Action-needed banner shown at the top of the clipboard window when the host
/// "Copy to Mac" File Provider extension is registered but the user hasn't
/// enabled it in System Settings (`availability == .needsEnabling`).
///
/// Large guest→host file pastes go lazy through the File Provider; while the
/// extension is disabled they fall back to a size-capped synchronous copy (and
/// over-cap files drop), so this nudges the user to flip the one toggle that
/// restores the full path. The owner toggles it via `isHidden`; it carries its
/// own hairline so it self-delineates from the command bar below.
@MainActor
final class ClipboardEnablementBanner: NSView {
    /// Invoked when the user clicks "Enable…" — the owner opens System Settings.
    var onEnable: (() -> Void)?

    init() {
        super.init(frame: .zero)

        let icon = NSImageView()
        icon.image = NSImage.systemSymbol(
            "exclamationmark.triangle.fill", accessibilityDescription: "File Provider disabled")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = StatusColor.warning
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(
            wrappingLabelWithString:
                "Enable 'File Provider' in System Settings to paste large files to your Mac.")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.isSelectable = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: "Enable…", target: self, action: #selector(enableClicked))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, label, button])
        stack.orientation = .horizontal
        stack.spacing = Spacing.small
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(
            top: Spacing.small, left: Spacing.medium, bottom: Spacing.small, right: Spacing.medium)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hairline)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: hairline.topAnchor),

            hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func enableClicked() {
        onEnable?()
    }
}
