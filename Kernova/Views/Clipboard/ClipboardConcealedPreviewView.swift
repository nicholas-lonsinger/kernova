import AppKit

/// Placeholder shown for confidential clipboard content
/// (`org.nspasteboard.ConcealedType`, the convention password managers use).
///
/// The window deliberately never renders the secret bytes — whatever the source
/// marked as concealed (a password copied on the host, or one copied inside a
/// macOS guest) is replaced here by a lock icon and a short explanation. The
/// content still crosses the channel and pastes into the peer; only its on-screen
/// display is suppressed. Static, read-only, and parameterless — there is nothing
/// to configure.
@MainActor
final class ClipboardConcealedPreviewView: NSView {
    init() {
        let iconView = NSImageView()
        iconView.image = NSImage.systemSymbol(
            "lock.fill", accessibilityDescription: "Confidential content")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 36, weight: .regular)
        iconView.contentTintColor = .secondaryLabelColor
        // A read-only decorative image must not intercept drags — let the whole
        // area bubble to the container (see ClipboardFilePreviewView).
        iconView.unregisterDraggedTypes()

        let headlineLabel = NSTextField(labelWithString: "Confidential content")
        headlineLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        headlineLabel.alignment = .center

        let detailLabel = NSTextField(
            wrappingLabelWithString:
                "This item is marked confidential and isn't shown here. It will still paste into the VM."
        )
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.isSelectable = false
        // A wrapping label computes its intrinsic *height* at this width, so the
        // stack lays it out at the correct multi-line height rather than a
        // single-line guess (the width constraint below alone forces wrapping but
        // not the matching height). Matches the codebase's wrapping-label idiom.
        detailLabel.preferredMaxLayoutWidth = Self.detailWidth

        super.init(frame: .zero)
        wantsLayer = true

        let stack = NSStackView(views: [iconView, headlineLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Spacing.tight
        stack.setCustomSpacing(Spacing.small, after: iconView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Spacing.large),
            stack.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Spacing.large),
            // Cap the explanation's width so it wraps to a few lines rather than
            // dictating the window width (paired with `preferredMaxLayoutWidth`
            // above, which gives the wrapped text its correct height).
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.detailWidth),
        ])
    }

    /// The wrapped explanation's max width — shared by the width constraint and
    /// `preferredMaxLayoutWidth` so the two can't drift.
    private static let detailWidth: CGFloat = 260

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Matches the text editor's background — see `ClipboardImagePreviewView`.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}
