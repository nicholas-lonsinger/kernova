import AppKit

/// A shell command shown as selectable monospaced text beside a button that
/// copies it to the pasteboard.
///
/// Built for `NSAlert.accessoryView`, which neither sizes nor lays out its
/// accessory, so the view gives itself a concrete frame at the requested width.
@MainActor
final class CopyableCommandView: NSView {
    private static let copySymbol = "doc.on.doc"
    private static let copiedSymbol = "checkmark"
    private static let spacing: CGFloat = 8
    private static let buttonWidth: CGFloat = 20
    /// How long the button shows a checkmark after a copy.
    private static let confirmationDuration: Duration = .milliseconds(1500)

    private let command: String
    private let pasteboard: NSPasteboard
    private let copyButton = NSButton()
    private var revertTask: Task<Void, Never>?

    init(
        command: String,
        width: CGFloat = CalloutStyle.width,
        pasteboard: NSPasteboard = .general
    ) {
        self.command = command
        self.pasteboard = pasteboard
        super.init(frame: .zero)

        // `NSAlert` sets its informative text at the small system size; the
        // command reads as a peer of that prose rather than a heading.
        let label = makeCalloutCode(command, size: NSFont.smallSystemFontSize)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.preferredMaxLayoutWidth = width - Self.buttonWidth - Self.spacing

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.isBordered = false
        copyButton.image = .systemSymbol(Self.copySymbol, accessibilityDescription: "Copy command")
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.toolTip = "Copy"
        copyButton.target = self
        copyButton.action = #selector(copyCommand)

        addSubview(label)
        addSubview(copyButton)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            copyButton.leadingAnchor.constraint(
                equalTo: label.trailingAnchor, constant: Self.spacing),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: Self.buttonWidth),
            copyButton.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
        ])

        frame = NSRect(x: 0, y: 0, width: width, height: fittingSize.height)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Puts the command on the pasteboard and confirms it on the button.
    @objc func copyCommand() {
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        revertTask?.cancel()
        copyButton.image = .systemSymbol(
            Self.copiedSymbol, accessibilityDescription: "Command copied")
        revertTask = Task { [weak self] in
            try? await Task.sleep(for: Self.confirmationDuration)
            guard !Task.isCancelled, let self else { return }
            copyButton.image = .systemSymbol(
                Self.copySymbol, accessibilityDescription: "Copy command")
        }
    }

    #if DEBUG
    /// The button's current symbol, so tests can observe the copy confirmation.
    var copyButtonImageForTesting: NSImage? { copyButton.image }
    #endif
}
