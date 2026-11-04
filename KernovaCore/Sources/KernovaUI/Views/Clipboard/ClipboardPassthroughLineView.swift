import AppKit

/// The one line shown in place of the buffer while passthrough is on and the guest holds the Mac's copy, which
/// the window never shows.
@MainActor
final class ClipboardPassthroughLineView: NSView {
    static let text = "Passthrough is on: the guest has the Mac's clipboard."

    init() {
        let label = NSTextField(labelWithString: Self.text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        wantsLayer = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: Spacing.large),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -Spacing.large),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}
