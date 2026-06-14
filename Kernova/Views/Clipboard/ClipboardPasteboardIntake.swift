import AppKit
import KernovaProtocol
import UniformTypeIdentifiers
import os

/// Result of reading a pasteboard into the clipboard buffer.
enum ClipboardIntakeResult: Equatable {
    /// Usable content. `note` carries a user-visible caveat when some
    /// representations were skipped (e.g. an oversized TIFF dropped while
    /// its PNG sibling survived).
    case content(ClipboardContent, note: String?)
    /// Nothing usable; `message` says why in user-facing terms.
    case rejected(message: String)
}

/// The single intake path for every host-side gesture that feeds the
/// clipboard buffer — the Paste button, responder-chain `paste:`, and
/// drag-and-drop — so all of them filter, cap, and reject identically.
///
/// Filtering and size caps come from `ClipboardSnapshotPolicy`, the same
/// policy the guest agent applies to its pasteboard poll.
@MainActor
enum ClipboardPasteboardIntake {
    private static let logger = Logger(subsystem: "app.kernova", category: "ClipboardPasteboardIntake")

    static let textOnlyTransportMessage = "Only text can be shared with Linux guests"

    /// Reads the first item of `pasteboard` into clipboard content.
    ///
    /// A file already on disk — whether a concrete `public.file-url` (Finder
    /// drag/copy) or a `promised-file-url` whose file the source has already
    /// written (the floating screenshot thumbnail) — is expanded: image files
    /// become an image representation, other files become their name. With
    /// `allowsBinary == false` (text-only transports) only the plain-text
    /// representation is taken.
    ///
    /// When the drag is clearly a file/image (a file URL or file promise is
    /// present) but no file is readable, the URL/path text representations are
    /// just the file's descriptor and are never returned as content — the
    /// caller falls through to asynchronous promise receipt instead of showing
    /// a path string.
    static func read(from pasteboard: NSPasteboard, allowsBinary: Bool) -> ClipboardIntakeResult {
        guard let item = pasteboard.pasteboardItems?.first else {
            return .rejected(message: "The Mac clipboard is empty")
        }

        // A concrete-or-promised file already on disk carries a URL, not the
        // file's bytes — expand it before the generic path.
        if let url = existingFileURL(in: item) {
            return read(fileAt: url, allowsBinary: allowsBinary)
        }

        guard allowsBinary else {
            guard let text = item.string(forType: .string), !text.isEmpty else {
                return .rejected(message: Self.textOnlyTransportMessage)
            }
            return .content(ClipboardContent(text: text), note: nil)
        }

        let isFileOrPromiseDrag = item.types.contains { isFileOrPromiseType($0.rawValue) }

        // Identity-based skips run before any data is read, mirroring the
        // guest agent's poll. For a file/promise drag we additionally drop the
        // URL/path text fallbacks so a screenshot thumbnail (or any file drag)
        // can never surface its path as text content.
        let raw: [(uti: String, data: Data)] = item.types.compactMap { type in
            guard !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: type.rawValue) else {
                return nil
            }
            if isFileOrPromiseDrag && isPathFallbackType(type.rawValue) {
                return nil
            }
            guard let data = item.data(forType: type) else { return nil }
            return (uti: type.rawValue, data: data)
        }
        let outcome = ClipboardSnapshotPolicy.evaluate(raw)

        if !outcome.skipped.isEmpty {
            let summary = outcome.skipped
                .map { "\($0.uti): \(String(describing: $0.reason))" }
                .joined(separator: ", ")
            logger.info("Pasteboard intake skipped: \(summary, privacy: .public)")
        }

        guard !outcome.content.isEmpty else {
            if outcome.skipped.contains(where: {
                if case .oversized = $0.reason { return true }
                if case .totalBudgetExceeded = $0.reason { return true }
                return false
            }) {
                return .rejected(
                    message:
                        "Clipboard content is too large to share (over \(DataFormatters.formatBytes(UInt64(ClipboardSnapshotPolicy.maxTotalByteCount))))"
                )
            }
            return .rejected(message: "The Mac clipboard has no shareable content")
        }

        let note: String? =
            outcome.skipped.contains(where: {
                if case .oversized = $0.reason { return true }
                if case .totalBudgetExceeded = $0.reason { return true }
                return false
            })
            ? "Some formats were too large to include" : nil

        return .content(outcome.content, note: note)
    }

    /// A concrete `public.file-url` or a `promised-file-url` that already
    /// points at an on-disk file.
    ///
    /// Returns nil when neither resolves to an existing file (e.g. a promise
    /// whose file hasn't been written yet — the caller receives it
    /// asynchronously instead). The floating screenshot thumbnail's temp file
    /// *is* already on disk during the drag, so its `promised-file-url`
    /// resolves here and is read as an image.
    private static func existingFileURL(in item: NSPasteboardItem) -> URL? {
        let candidates: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        ]
        for type in candidates {
            guard let string = item.string(forType: type),
                let url = URL(string: string), url.isFileURL,
                FileManager.default.fileExists(atPath: url.path)
            else { continue }
            return url
        }
        return nil
    }

    /// `true` for the types that mark a drag as a file or file promise.
    private static func isFileOrPromiseType(_ uti: String) -> Bool {
        uti == "public.file-url" || uti == "NSFilenamesPboardType"
            || uti.hasPrefix("com.apple.pasteboard.promised-file")
            || uti.hasPrefix("com.apple.NSFilePromise")
    }

    /// `true` for text/URL types that, in a file/promise drag, merely describe
    /// the file's path or name rather than being real content.
    private static func isPathFallbackType(_ uti: String) -> Bool {
        uti == "public.url" || uti == "public.utf8-plain-text"
            || uti == "Apple URL pasteboard type"
    }

    /// Reads a single file into clipboard content — the expansion used for
    /// dragged/copied `public.file-url` items and for files received from
    /// drag-and-drop file promises (screenshot thumbnail, Photos, browsers).
    ///
    /// An image file becomes the image itself (so it pastes as an image on
    /// the other side, matching how macOS pastes a copied image file). Every
    /// other file type can't cross the VM boundary as a file, so only its
    /// name is conveyed — its contents are never inlined (a copied `.txt`
    /// behaves like the file, not its text).
    static func read(fileAt url: URL, allowsBinary: Bool) -> ClipboardIntakeResult {
        guard
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
            let type = values.contentType
        else {
            return .rejected(message: "Couldn't read the dropped file")
        }

        if type.conforms(to: .image) {
            guard allowsBinary else {
                return .rejected(message: Self.textOnlyTransportMessage)
            }
            let fileSize = values.fileSize ?? 0
            guard fileSize <= ClipboardSnapshotPolicy.maxRepresentationByteCount else {
                return .rejected(
                    message:
                        "File is too large to share (over \(DataFormatters.formatBytes(UInt64(ClipboardSnapshotPolicy.maxRepresentationByteCount))))"
                )
            }
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                return .rejected(message: "Couldn't read the dropped file")
            }
            return .content(
                ClipboardContent(representations: [
                    .init(uti: type.identifier, data: data)
                ]),
                note: nil
            )
        }

        // Non-image file: convey its name, not its contents.
        let name = url.lastPathComponent
        guard !name.isEmpty else {
            return .rejected(message: "Couldn't read the dropped file")
        }
        return .content(ClipboardContent(text: name), note: nil)
    }
}
