import AppKit

/// The clipboard window's transient-status slot, at the trailing end of the
/// status line.
///
/// Shows send failures, size-cap skips, copy confirmations and drop notes for a
/// few seconds, then clears. The buffer's content type is stated by the buffer
/// card's chip, not here.
@MainActor
final class ClipboardStatusMessageView: NSTextField {
    /// Tone of a transient message.
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

    /// Horizontal compression resistance: one step above the `.defaultLow` the
    /// status bar's other label carries, so that label yields its width first.
    private static let horizontalCompressionResistance = NSLayoutConstraint.Priority(
        rawValue: NSLayoutConstraint.Priority.defaultLow.rawValue + 1)

    private var clearTask: Task<Void, Never>?

    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        textColor = .secondaryLabelColor
        lineBreakMode = .byTruncatingTail
        alignment = .right
        // Truncate rather than dictate the window width through Auto Layout, but
        // above the agent-status label it shares the row with: at equal priority
        // the split is ambiguous, and a message here is transient and complete
        // where that label is persistent and re-readable.
        setContentCompressionResistancePriority(
            Self.horizontalCompressionResistance, for: .horizontal)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows `text` in the status slot for a few seconds, then clears it.
    ///
    /// A newer message replaces the current one and restarts the clock.
    func showTransientMessage(_ text: String, style: TransientStyle) {
        clearTask?.cancel()
        stringValue = text
        textColor = style.color
        clearTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.transientDuration)
            } catch {
                return  // superseded by a newer message
            }
            self?.clear()
        }
    }

    private func clear() {
        clearTask = nil
        stringValue = ""
        textColor = .secondaryLabelColor
    }
}
