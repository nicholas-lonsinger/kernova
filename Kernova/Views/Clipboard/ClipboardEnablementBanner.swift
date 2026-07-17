import AppKit

/// Action-needed banner shown at the top of the clipboard window when the host
/// "Copy to Mac" File Provider extension needs attention — either registered
/// but not enabled in System Settings (`.needsEnabling`), or a registration/
/// install failure with no user toggle to flip (`.unavailable`, #591).
///
/// Large guest→host file pastes go lazy through the File Provider; while the
/// extension is disabled or unavailable, they fall back to a size-capped
/// synchronous copy (and over-cap files drop). `present(_:)` switches the
/// banner's copy and whether the "Enable…" button shows (`.needsEnabling` has
/// a one-toggle fix; `.unavailable` doesn't). The owner toggles visibility via
/// `isHidden`; it carries its own hairline so it self-delineates from the
/// command bar below.
@MainActor
final class ClipboardEnablementBanner: NSView {
    /// The two File Provider states the banner has copy for — see the type doc.
    enum Mode {
        case needsEnabling
        case unavailable
    }

    /// Invoked when the user clicks "Enable…" — the owner opens System Settings.
    var onEnable: (() -> Void)?

    private let label: NSTextField
    private let button: NSButton

    init() {
        let icon = NSImageView()
        icon.image = NSImage.systemSymbol(
            "exclamationmark.triangle.fill", accessibilityDescription: "File Provider disabled")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.contentTintColor = StatusColor.warning
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .labelColor
        label.isSelectable = false
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        self.label = label

        let button = NSButton(title: "Enable…", target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        self.button = button

        let stack = NSStackView(views: [icon, label, button])
        stack.orientation = .horizontal
        stack.spacing = Spacing.small
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(
            top: Spacing.small, left: Spacing.medium, bottom: Spacing.small, right: Spacing.medium)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let hairline = NSBox()
        hairline.boxType = .separator
        hairline.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)

        button.target = self
        button.action = #selector(enableClicked)
        addSubview(stack)
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

        present(.needsEnabling)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the banner's copy and button visibility for `mode`.
    ///
    /// `.needsEnabling` has a one-toggle fix, so it keeps the "Enable…"
    /// button; `.unavailable` has no user toggle to flip, so the button is
    /// hidden and the explanatory line is the correction (mirrors the
    /// status-item menu's `.unavailable` line — #591).
    func present(_ mode: Mode) {
        switch mode {
        case .needsEnabling:
            label.stringValue =
                "Enable 'File Provider' in System Settings to paste large files to your Mac."
            button.isHidden = false
        case .unavailable:
            label.stringValue =
                "File sharing is unavailable. Reopen Kernova to restore pasting large files to your Mac."
            button.isHidden = true
        }
    }

    @objc private func enableClicked() {
        onEnable?()
    }
}
