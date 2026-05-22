import AppKit

/// Shared row layout for the Storage Disks, Removable Media, and Shared
/// Directories sections in ``VMSettingsViewController``.
///
/// The row owns a leading icon (whatever ``NSView`` the caller hands in —
/// typically an ``AttachmentIconButton`` for attachment-style rows or a
/// plain ``NSImageView`` for folders), a vertical title/subtitle stack, a
/// trailing "Read Only" `NSSwitch`, and a trash button. Actions are
/// dispatched through closures so the row doesn't need a model lookup at
/// the call site.
@MainActor
final class AttachmentRowView: NSStackView {
    /// Build a row.
    ///
    /// - Parameters:
    ///   - icon: Leading icon view. Sized by its own constraints.
    ///   - title: Primary label text.
    ///   - subtitle: Subtitle view (e.g. ``makeAttachmentSubtitleLabel`` or
    ///     a plain path `NSTextField`).
    ///   - readOnly: Initial state for the Read Only switch.
    ///   - isReadOnlyEnabled: Whether the user can toggle Read Only.
    ///   - isRemoveEnabled: Whether the trash button is enabled.
    ///   - onToggleReadOnly: Fired when the switch changes; receives the
    ///     new state.
    ///   - onRemove: Fired when the trash button is clicked.
    init(
        icon: NSView,
        title: String,
        subtitle: NSView,
        readOnly: Bool,
        isReadOnlyEnabled: Bool = true,
        isRemoveEnabled: Bool = true,
        onToggleReadOnly: @escaping (Bool) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.toggleHandler = onToggleReadOnly
        self.removeHandler = onRemove

        super.init(frame: .zero)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .preferredFont(forTextStyle: .body)

        let textStack = NSStackView(views: [titleLabel, subtitle])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        toggle.state = readOnly ? .on : .off
        toggle.isEnabled = isReadOnlyEnabled
        toggle.target = self
        toggle.action = #selector(handleToggle(_:))

        let toggleLabel = NSTextField(labelWithString: "Read Only")
        toggleLabel.font = .preferredFont(forTextStyle: .caption1)
        toggleLabel.textColor = .secondaryLabelColor

        removeButton.image = .systemSymbol(
            "minus.circle.fill", accessibilityDescription: "Remove"
        )
        removeButton.isBordered = false
        removeButton.contentTintColor = .systemRed
        removeButton.isEnabled = isRemoveEnabled
        removeButton.target = self
        removeButton.action = #selector(handleRemove(_:))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        setViews([icon, textStack, spacer, toggle, toggleLabel, removeButton], in: .leading)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentRowView does not support NSCoder")
    }

    // MARK: - Internals

    private let toggle = NSSwitch()
    private let removeButton = NSButton()
    private let toggleHandler: (Bool) -> Void
    private let removeHandler: () -> Void

    @objc private func handleToggle(_ sender: NSSwitch) {
        toggleHandler(sender.state == .on)
    }

    @objc private func handleRemove(_ sender: Any?) {
        removeHandler()
    }
}
