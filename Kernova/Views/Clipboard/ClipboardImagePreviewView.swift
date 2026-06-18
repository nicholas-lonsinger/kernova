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

        // The preview must never dictate the window's size: NSImageView's
        // intrinsic size is the (thumbnail) image size, and required
        // compression resistance would force the window to grow to fit a
        // large paste through Auto Layout. Floor the priorities and pin the
        // image view to the container instead — `scaleProportionallyDown`
        // then aspect-fits the displayed image into whatever space the
        // window currently has (and never upscales).
        imageView.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        imageView.setContentCompressionResistancePriority(.init(1), for: .vertical)
        imageView.setContentHuggingPriority(.init(1), for: .horizontal)
        imageView.setContentHuggingPriority(.init(1), for: .vertical)

        // NSImageView registers itself as a drag destination, so a drag over
        // the image is consumed here (and silently rejected, since it isn't
        // editable) instead of bubbling to the window's drop container. This
        // read-only preview has no drag behavior of its own — unregister it so
        // the whole content area, image included, is one drop target.
        imageView.unregisterDraggedTypes()

        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.medium),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.medium),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.medium),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.medium),
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

    /// Decodes resident `data` into the preview.
    ///
    /// Returns `false` when the bytes are not a decodable image — the
    /// caller falls back to the summary view. Runtime data, so failure is a
    /// logged condition, not a programming error.
    func configure(data: Data, uti: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            Self.logger.warning(
                "Could not read image preview (uti=\(uti, privacy: .public), \(data.count, privacy: .public) bytes)"
            )
            imageView.image = nil
            return false
        }
        return setThumbnail(from: source, uti: uti)
    }

    /// Decodes a thumbnail straight from a file-backed image at `url`.
    ///
    /// The whole file is never loaded into memory — ImageIO memory-maps it and
    /// only materializes the downsampled thumbnail. The on-disk counterpart of
    /// `configure(data:uti:)` for a copied/streamed image file. Returns `false`
    /// when the file is missing or not a decodable image — the caller falls back
    /// to a file chip.
    func configure(url: URL, uti: String) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            Self.logger.warning(
                "Could not read image preview from file (uti=\(uti, privacy: .public))")
            imageView.image = nil
            return false
        }
        return setThumbnail(from: source, uti: uti)
    }

    /// Renders a downsampled thumbnail from an image source into the view.
    private func setThumbnail(from source: CGImageSource, uti: String) -> Bool {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailMaxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            Self.logger.warning(
                "Could not decode image preview (uti=\(uti, privacy: .public))")
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
