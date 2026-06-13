import AppKit

/// The clipboard window's command row.
///
/// Explicit host-pasteboard transfer buttons sit on the leading edge and a
/// content-type indicator on the trailing edge. The indicator doubles as the
/// surface for transient status messages (send failures, size-cap skips,
/// copy confirmations).
@MainActor
final class ClipboardCommandBarView: NSView {
    enum TransientStyle {
        case info
        case warning
        case error

        var color: NSColor {
            switch self {
            case .info: return .secondaryLabelColor
            case .warning: return .systemOrange
            case .error: return .systemRed
            }
        }
    }

    private static let transientDuration: Duration = .seconds(4)

    // RATIONALE: No keyEquivalent on either button — a Cmd+V equivalent
    // would intercept performKeyEquivalent before a focused NSTextView ever
    // sees the keystroke, breaking normal text editing. Keyboard access
    // flows through the responder chain (`paste(_:)`/`copy(_:)` on the view
    // controller) instead.
    let pasteButton: NSButton
    let copyButton: NSButton

    private let indicatorLabel: NSTextField

    /// The persistent indicator text a transient message reverts to.
    private var indicatorText = ""
    private var revertTask: Task<Void, Never>?

    init() {
        let pasteButton = NSButton(title: "Paste from Mac", target: nil, action: nil)
        pasteButton.bezelStyle = .accessoryBarAction
        pasteButton.controlSize = .small
        self.pasteButton = pasteButton

        let copyButton = NSButton(title: "Copy to Mac", target: nil, action: nil)
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.controlSize = .small
        self.copyButton = copyButton

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .right
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.indicatorLabel = label

        super.init(frame: .zero)

        // Spacer with explicit low hugging so the stack grows it rather than
        // the label — same trick as the agent status bar.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [pasteButton, copyButton, spacer, label])
        stack.orientation = .horizontal
        stack.spacing = Spacing.small
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Updates the persistent content-type indicator.
    ///
    /// While a transient message is showing, the new text takes over once
    /// the transient reverts.
    func setIndicatorText(_ text: String) {
        indicatorText = text
        guard revertTask == nil else { return }
        indicatorLabel.stringValue = text
        indicatorLabel.textColor = .secondaryLabelColor
    }

    /// Shows `text` in the indicator slot for a few seconds.
    ///
    /// Reverts to the persistent indicator text afterwards. A newer message
    /// replaces the current one and restarts the clock.
    func showTransientMessage(_ text: String, style: TransientStyle) {
        revertTask?.cancel()
        indicatorLabel.stringValue = text
        indicatorLabel.textColor = style.color
        revertTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.transientDuration)
            } catch {
                return  // superseded by a newer message
            }
            self?.revertToIndicator()
        }
    }

    private func revertToIndicator() {
        revertTask = nil
        indicatorLabel.stringValue = indicatorText
        indicatorLabel.textColor = .secondaryLabelColor
    }
}
