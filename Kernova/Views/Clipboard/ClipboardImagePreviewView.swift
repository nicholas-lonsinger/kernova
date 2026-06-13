import AppKit
import ImageIO
import os

/// Centered, aspect-fit image preview for the clipboard window.
///
/// Decoding goes through `CGImageSourceCreateThumbnailAtIndex` capped at
/// 2048 px, so a pathological 100-megapixel paste cannot allocate a
/// full-size bitmap; the preview is a preview, the buffer keeps the
/// original bytes.
@MainActor
final class ClipboardImagePreviewView: NSView {
    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardImagePreviewView")
    private static let thumbnailMaxPixelSize = 2048

    private let imageView: NSImageView

    init() {
        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        self.imageView = imageView

        super.init(frame: .zero)
        wantsLayer = true

        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: Spacing.medium),
            imageView.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Spacing.medium),
            imageView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: Spacing.medium),
            imageView.bottomAnchor.constraint(
                lessThanOrEqualTo: bottomAnchor, constant: -Spacing.medium),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Matches the text editor's background so switching preview modes
    /// doesn't shift the window's tone. `updateLayer` re-resolves the
    /// dynamic color on appearance changes.
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }

    /// Decodes `data` into the preview.
    ///
    /// Returns `false` when the bytes are not a decodable image — the
    /// caller falls back to the summary view. Runtime data, so failure is a
    /// logged condition, not a programming error.
    func configure(data: Data, uti: String) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            Self.logger.warning(
                "Could not decode image preview (uti=\(uti, privacy: .public), \(data.count, privacy: .public) bytes)"
            )
            imageView.image = nil
            return false
        }
        imageView.image = NSImage(
            cgImage: thumbnail,
            size: NSSize(width: thumbnail.width, height: thumbnail.height)
        )
        return true
    }
}
