import AppKit
import Symbols

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
/// A copy that lands turns the glyph into a checkmark until `confirmationHold`
/// passes. The glyph is an image view because AppKit runs symbol transitions
/// only in `NSImageView`.
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

    private static let copyGlyph = smallSymbol("doc.on.doc")
    private static let confirmedGlyph = smallSymbol("checkmark")

    private let pasteboard: NSPasteboard
    private let confirmationHold: Duration
    private let glyphView: NSImageView
    /// The copy glyph's metrics, kept while the smaller checkmark shows.
    private let glyphSize: NSSize
    private let glyphInsets: NSEdgeInsets
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
        let glyphView = NSImageView(image: Self.copyGlyph)
        glyphView.contentTintColor = .secondaryLabelColor
        glyphView.setAccessibilityElement(false)
        glyphView.translatesAutoresizingMaskIntoConstraints = false
        self.glyphView = glyphView
        glyphSize = glyphView.intrinsicContentSize
        glyphInsets = glyphView.alignmentRectInsets
        super.init(frame: .zero)
        isHidden = value == nil
        title = ""
        imagePosition = .noImage
        isBordered = false
        toolTip = name
        setAccessibilityLabel(name)
        addSubview(glyphView)
        NSLayoutConstraint.activate([
            glyphView.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyphView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        target = self
        action = #selector(copyValue)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CopyValueButton does not support NSCoder")
    }

    override var intrinsicContentSize: NSSize { glyphSize }

    override var alignmentRectInsets: NSEdgeInsets { glyphInsets }

    // NSView's hit-test answers with the deepest view under the point, which
    // here is the glyph.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        glyphView.contentTintColor =
            flag ? .secondaryLabelColor.withSystemEffect(.pressed) : .secondaryLabelColor
    }

    // AppKit rings a borderless image button along its glyph's outline.
    override var focusRingMaskBounds: NSRect { glyphView.frame }

    override func drawFocusRingMask() {
        glyphView.image?.draw(in: glyphView.frame)
    }

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

    /// Transitions the glyph to the one `showsConfirmation` calls for.
    private func showGlyph() {
        let glyph = showsConfirmation ? Self.confirmedGlyph : Self.copyGlyph
        guard glyphView.image !== glyph else { return }
        glyphView.setSymbolImage(glyph, contentTransition: .replace)
        noteFocusRingMaskChanged()
    }

    private static func smallSymbol(_ name: String) -> NSImage {
        let symbol = NSImage.systemSymbol(name, accessibilityDescription: "")
        guard let small = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .small))
        else {
            assertionFailure("\(name) is not a symbol image")
            return symbol
        }
        return small
    }
}
