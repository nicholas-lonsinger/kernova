import AppKit

/// Puts `string` on `pasteboard`, for a panel's copy affordance; `false` when
/// the pasteboard refuses the write.
@MainActor
@discardableResult
func copyToPasteboard(_ string: String, to pasteboard: NSPasteboard = .general) -> Bool {
    pasteboard.clearContents()
    return pasteboard.setString(string, forType: .string)
}

/// A copy button carrying the text it writes, so the value travels with the
/// control; it is hidden while there is nothing to copy.
///
/// A copy that lands swaps the glyph for a checkmark until `confirmationHold`
/// passes.
@MainActor
final class CopyValueButton: NSButton {
    var value: String? {
        didSet {
            isHidden = value == nil
            showGlyph()
        }
    }

    /// Whether the checkmark shows: a copy landed within the hold, and the value
    /// it wrote is still the one shown.
    var showsConfirmation: Bool { confirmed != nil && confirmed == value }

    private static let copyGlyph = NSImage.systemSymbol("doc.on.doc", accessibilityDescription: "")
    private static let confirmedGlyph = NSImage.systemSymbol("checkmark", accessibilityDescription: "")

    private let pasteboard: NSPasteboard
    private let confirmationHold: Duration
    /// The copy glyph's size, which the narrower checkmark keeps so the value
    /// beside it stays put.
    private var restingSize = NSSize.zero
    /// The value the last landed copy wrote, until its hold passes.
    private var confirmed: String? { didSet { showGlyph() } }
    private var holdTask: Task<Void, Never>?

    /// `name` titles the copy for its tooltip and accessibility label, e.g.
    /// "Copy IP Address".
    init(
        name: String, value: String? = nil, pasteboard: NSPasteboard = .general,
        confirmationHold: Duration = .seconds(1.5)
    ) {
        self.value = value
        self.pasteboard = pasteboard
        self.confirmationHold = confirmationHold
        super.init(frame: .zero)
        isHidden = value == nil
        image = Self.copyGlyph
        symbolConfiguration = NSImage.SymbolConfiguration(scale: .small)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .secondaryLabelColor
        wantsLayer = true
        restingSize = super.intrinsicContentSize
        toolTip = name
        setAccessibilityLabel(name)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        target = self
        action = #selector(copyValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CopyValueButton does not support NSCoder")
    }

    override var intrinsicContentSize: NSSize { restingSize }

    @objc private func copyValue() {
        guard let value, copyToPasteboard(value, to: pasteboard) else { return }
        confirmed = value
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: "Copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        holdTask?.cancel()
        holdTask = Task { [weak self, confirmationHold] in
            do {
                try await Task.sleep(for: confirmationHold)
            } catch {
                return  // a later copy restarted the hold
            }
            self?.confirmed = nil
        }
    }

    private func showGlyph() {
        let glyph = showsConfirmation ? Self.confirmedGlyph : Self.copyGlyph
        guard image !== glyph else { return }
        // Apple documents CATransition for layers but not that AppKit fades an
        // NSButton's image change through one added to the layer it manages;
        // where it doesn't, the swap is instant.
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.15
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer?.add(fade, forKey: "glyph")
        image = glyph
    }
}
