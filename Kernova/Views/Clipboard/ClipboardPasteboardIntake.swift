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
    /// A file resolved on disk whose bytes still have to be read — `read(from:)`
    /// returns this so the caller can read them asynchronously (off the main
    /// actor) via `read(fileAt:)` before they become `.content`. Never applied
    /// directly.
    case pendingFile(URL)
}

/// The single intake path for every host-side gesture that feeds the
/// clipboard buffer — the Paste button, responder-chain `paste:`, and
/// drag-and-drop — so all of them filter and reject identically.
///
/// Filtering comes from `ClipboardSnapshotPolicy`, the same policy the guest
/// agent applies to its pasteboard poll. There is no size cap: a copied file
/// becomes a disk-backed representation whose bytes stream on demand.
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
        // file's bytes. Defer it: the caller reads the bytes off the main actor
        // via `read(fileAt:)` (a large file mustn't block the UI here).
        if let url = existingFileURL(in: item) {
            return .pendingFile(url)
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
            return .rejected(message: "The Mac clipboard has no shareable content")
        }

        return .content(outcome.content, note: nil)
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

    /// Resolves a single dropped/copied file into a disk-backed representation —
    /// the expansion used for dragged/copied `public.file-url` items and for
    /// files received from drag-and-drop file promises (screenshot thumbnail,
    /// Photos, browsers).
    ///
    /// The file crosses as a disk-backed `.file` representation: only a stat
    /// runs here (name + size + content UTI), and the bytes stream on demand
    /// when the guest requests them, so there is no size cap and the UI never
    /// blocks on a read. The other side materializes a real file — a Finder
    /// paste creates it, matching how macOS pastes a copied file — and an image
    /// additionally pastes inline (the receiver decides per UTI). The file's
    /// path never crosses, only its name. Text-only transports (Linux/SPICE)
    /// can't carry files at all.
    static func read(fileAt url: URL, allowsBinary: Bool) -> ClipboardIntakeResult {
        guard
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
            let type = values.contentType
        else {
            return .rejected(message: "Couldn't read the dropped file")
        }

        guard allowsBinary else {
            return .rejected(message: Self.textOnlyTransportMessage)
        }
        let fileSize = values.fileSize ?? 0
        guard fileSize > 0 else {
            return .rejected(message: "Couldn't read the dropped file")
        }
        return .content(
            ClipboardContent(representations: [
                .init(
                    uti: type.identifier, fileURL: url, byteCount: fileSize,
                    filename: url.lastPathComponent)
            ]),
            note: nil
        )
    }
}
