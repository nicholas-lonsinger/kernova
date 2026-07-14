import AppKit

/// Banner shown at the top of the clipboard window while automatic passthrough
/// is on, indicating the editor is no longer the primary pathway.
///
/// While passthrough is on, the host clipboard syncs with the guest
/// automatically in both directions, so the window's Paste / Copy-to-Mac / editor
/// gestures are no longer required. The banner makes that state legible and
/// offers a one-click runtime "Turn Off" (turning off needs no confirmation —
/// unlike turning on, which the settings toggle gates). The owner toggles it via
/// `isHidden`; it carries its own hairline so it self-delineates from the command
/// bar below.
@MainActor
final class ClipboardPassthroughBanner: NSView {
    /// Invoked when the user clicks "Turn Off" — the owner disables passthrough.
    var onTurnOff: (() -> Void)?

    init() {
        super.init(frame: .zero)

        let icon = NSImageView()
        icon.image = NSImage.systemSymbol(
            "arrow.left.arrow.right", accessibilityDescription: "Automatic passthrough on")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(
            wrappingLabelWithString:
                "Automatic passthrough is on — this Mac's clipboard syncs with the guest automatically.")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.isSelectable = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: "Turn Off", target: self, action: #selector(turnOffClicked))
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

    @objc private func turnOffClicked() {
        onTurnOff?()
    }
}
