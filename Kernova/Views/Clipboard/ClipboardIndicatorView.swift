import AppKit

/// The clipboard window's content-type indicator and transient-status surface.
///
/// Shows the persistent content-type text (e.g. "PNG image · 1920 × 1080 ·
/// 3.4 MB") and temporarily takes over to show transient messages — send
/// failures, size-cap skips, copy confirmations — reverting after a few seconds.
@MainActor
final class ClipboardIndicatorView: NSTextField {
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

    /// The persistent indicator text a transient message reverts to.
    private var persistentText = ""
    private var revertTask: Task<Void, Never>?

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

    /// Updates the persistent content-type indicator.
    ///
    /// While a transient message is showing, the new text takes over once the
    /// transient reverts.
    func setText(_ text: String) {
        persistentText = text
        guard revertTask == nil else { return }
        stringValue = text
        textColor = .secondaryLabelColor
    }

    /// Shows `text` in the indicator slot for a few seconds.
    ///
    /// Reverts to the persistent text afterwards. A newer message replaces the
    /// current one and restarts the clock.
    func showTransientMessage(_ text: String, style: TransientStyle) {
        revertTask?.cancel()
        stringValue = text
        textColor = style.color
        revertTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.transientDuration)
            } catch {
                return  // superseded by a newer message
            }
            self?.revertToPersistent()
        }
    }

    private func revertToPersistent() {
        revertTask = nil
        stringValue = persistentText
        textColor = .secondaryLabelColor
    }
}
