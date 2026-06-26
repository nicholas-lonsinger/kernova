import AppKit
import KernovaKit
import UniformTypeIdentifiers

/// Several copied or dropped files shown as a count + total-size header above a
/// scrollable list of file rows (icon · name · type · size).
///
/// The multi-file counterpart of `ClipboardFilePreviewView`: the cue that the
/// buffer holds *several* files, each of which pastes as a real file on the
/// other side. Drives the `.files` preview mode.
@MainActor
final class ClipboardFilesPreviewView: NSView {
    /// Document view whose flipped coordinate space keeps the row list anchored
    /// to the top of the scroll area (an unflipped doc view would stick the rows
    /// to the bottom).
    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private let headerLabel: NSTextField
    private let rowsStack: NSStackView
    private let scrollView: NSScrollView

    init() {
        let header = NSTextField(labelWithString: "")
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.lineBreakMode = .byTruncatingTail
        // Truncate rather than dictate window width through Auto Layout.
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.headerLabel = header

        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = Spacing.small
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        self.rowsStack = rowsStack

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(rowsStack)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = documentView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        self.scrollView = scrollView

        super.init(frame: .zero)
        wantsLayer = true

        let headerRow = NSStackView(views: [
            NSImageView(image: .systemSymbol("doc.on.doc", accessibilityDescription: "Files")),
            header,
        ])
        headerRow.orientation = .horizontal
        headerRow.alignment = .firstBaseline
        headerRow.spacing = Spacing.small
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(headerRow)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.medium),
            headerRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.large),
            headerRow.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Spacing.large),

            scrollView.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: Spacing.small),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.large),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.large),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.medium),

            // Pin the document view to the clip view; its width tracks the clip
            // (no horizontal scroll) while its height grows with the row stack.
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            rowsStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            rowsStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            rowsStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
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

    /// Renders the buffer's file payloads as a header plus one row per file.
    ///
    /// The header reuses `ClipboardContentDescriber.indicatorText` so it stays
    /// identical to the command-bar indicator ("3 files · 4.2 MB").
    func configure(content: ClipboardContent) {
        headerLabel.stringValue = ClipboardContentDescriber.indicatorText(for: content)
        rowsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for payload in content.filePayloads {
            let row = makeRow(
                filename: payload.filename, uti: payload.uti, byteCount: payload.byteCount)
            rowsStack.addArrangedSubview(row)
            // Activate the width match only once the row shares an ancestor with
            // the stack (after it's added), so the row fills the stack's width and
            // its labels truncate instead of forcing horizontal scroll.
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
    }

    /// One file row: type icon, name, and a "type · size" detail line.
    private func makeRow(filename: String, uti: String, byteCount: Int) -> NSView {
        let type = UTType(uti)

        let icon = NSImageView(image: NSWorkspace.shared.icon(for: type ?? .data))
        icon.imageScaling = .scaleProportionallyDown
        // See ClipboardImagePreviewView: keep the icon from intercepting drags.
        icon.unregisterDraggedTypes()
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
        ])

        let nameLabel = NSTextField(labelWithString: filename)
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailLabel = NSTextField(
            labelWithString: ClipboardContentDescriber.fileDetail(uti: uti, byteCount: byteCount))
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = Spacing.hairline

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Spacing.small
        row.translatesAutoresizingMaskIntoConstraints = false
        // The width match to the stack is activated by the caller once the row is
        // in the hierarchy (see `configure`).
        return row
    }
}
