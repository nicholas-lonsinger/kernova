import AppKit

/// The clipboard window's command row: icon buttons for host-pasteboard
/// transfers and clearing the buffer.
///
/// Leading-aligned `Paste from Mac` / `Copy to Mac` / `Clear` buttons, each an
/// SF Symbol plus a short label and a tooltip. The content-type indicator and
/// transient-status surface live in the status row (`ClipboardIndicatorView`),
/// so this row is actions only. The owner hides the whole bar (via `isHidden`)
/// while automatic passthrough is on — the manual transfer/clear actions are
/// redundant once the host and guest clipboards sync automatically; it carries
/// its own hairline so it self-delineates from the content area below, the same
/// pattern `ClipboardPassthroughBanner` uses.
@MainActor
final class ClipboardCommandBarView: NSView {
    // RATIONALE: No keyEquivalent on any button — a Cmd+V / Cmd+C equivalent
    // would intercept performKeyEquivalent before a focused NSTextView ever
    // sees the keystroke, breaking normal text editing. Keyboard access flows
    // through the responder chain (`paste(_:)` / `copy(_:)`) instead.
    let pasteButton: NSButton
    let copyButton: NSButton
    let clearButton: NSButton

    init() {
        pasteButton = Self.makeButton(
            title: "Paste from Mac", symbol: "square.and.arrow.down",
            tooltip: "Paste the Mac clipboard into the buffer")
        copyButton = Self.makeButton(
            title: "Copy to Mac", symbol: "square.and.arrow.up",
            tooltip: "Copy the buffer to the Mac clipboard")
        clearButton = Self.makeButton(
            title: "Clear", symbol: "trash",
            tooltip: "Empty the clipboard buffer")

        super.init(frame: .zero)

        // Trailing spacer with low hugging so the stack grows it rather than a
        // button — keeps the buttons leading-aligned.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [pasteButton, copyButton, clearButton, spacer])
        stack.orientation = .horizontal
        stack.spacing = Spacing.small
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.alignment = .centerY
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

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private static func makeButton(title: String, symbol: String, tooltip: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .accessoryBarAction
        button.controlSize = .small
        button.image = .systemSymbol(symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.toolTip = tooltip
        return button
    }
}
