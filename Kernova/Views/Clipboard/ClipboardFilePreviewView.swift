import AppKit
import UniformTypeIdentifiers

/// A copied or dropped file shown as a chip: the file-type icon, its name, and
/// a "Type · size" subtitle.
///
/// This is the visual cue that the buffer holds a *file* (which pastes as a
/// file on the other side — Finder creates it, Notes attaches it) rather than
/// inline content. Images get their own pixel preview; every other file lands
/// here.
@MainActor
final class ClipboardFilePreviewView: NSView {
    private let iconView: NSImageView
    private let nameLabel: NSTextField
    private let detailLabel: NSTextField

    init() {
        let iconView = NSImageView()
        iconView.imageScaling = .scaleProportionallyDown
        // See ClipboardImagePreviewView: keep this read-only view's image view
        // from intercepting drags so the whole area bubbles to the container.
        iconView.unregisterDraggedTypes()
        self.iconView = iconView

        let nameLabel = NSTextField(labelWithString: "")
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingMiddle
        // Truncate rather than dictate window width through Auto Layout.
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.nameLabel = nameLabel

        let detailLabel = NSTextField(labelWithString: "")
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.alignment = .center
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.detailLabel = detailLabel

        super.init(frame: .zero)
        wantsLayer = true

        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 64),
            iconView.heightAnchor.constraint(equalToConstant: 64),
        ])

        let stack = NSStackView(views: [iconView, nameLabel, detailLabel])
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
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Matches the text editor's background — see `ClipboardImagePreviewView`.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    func configure(filename: String, uti: String, byteCount: Int) {
        let type = UTType(uti)
        iconView.image = NSWorkspace.shared.icon(for: type ?? .data)
        nameLabel.stringValue = filename
        let typeName = type?.localizedDescription ?? uti
        detailLabel.stringValue = "\(typeName) · \(DataFormatters.formatBytes(UInt64(byteCount)))"
    }
}
