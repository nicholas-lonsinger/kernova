import AppKit
import UniformTypeIdentifiers
import os

/// Read-only styled preview of inline RTF.
///
/// Non-editable on purpose: editing rich content as plain text in place would
/// silently flatten its formatting.
@MainActor
final class ClipboardRichTextPreviewView: NSView {
    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardRichTextPreviewView")

    private let textView: NSTextView
    private let scrollView: NSScrollView

    init() {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.size = NSSize(
            width: 0,
            height: CGFloat.greatestFiniteMagnitude
        )
        // A read-only NSTextView still registers as a drag destination; keep it
        // from intercepting drops so the whole window is one drop target.
        textView.unregisterDraggedTypes()
        self.textView = textView

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        self.scrollView = scrollView

        super.init(frame: .zero)
        wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    /// Renders `data` as styled text.
    ///
    /// Decodes with the RTFD document type for an RTFD flavor (so an inline image
    /// renders in place) and plain RTF otherwise. Returns `false` when the bytes
    /// can't be decoded — the caller falls back to the summary.
    func configure(data: Data, uti: String) -> Bool {
        let documentType: NSAttributedString.DocumentType =
            UTType(uti)?.needsRTFDDocumentType == true ? .rtfd : .rtf
        guard
            let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: documentType],
                documentAttributes: nil)
        else {
            Self.logger.warning(
                "Could not decode rich-text preview (uti=\(uti, privacy: .public), \(data.count, privacy: .public) bytes)"
            )
            return false
        }
        textView.textStorage?.setAttributedString(attributed)
        textView.scroll(.zero)
        return true
    }
}
