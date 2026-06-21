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
    /// One or more files resolved on disk whose bytes still have to be read —
    /// `read(from:)` returns this so the caller can read them asynchronously
    /// (off the main actor) via `read(filesAt:)` before they become `.content`.
    /// A multi-select copy/drag carries several URLs, in pasteboard order. Never
    /// applied directly.
    case pendingFiles([URL])
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

    /// Reads `pasteboard` into clipboard content.
    ///
    /// Files already on disk — whether concrete `public.file-url`s (Finder
    /// drag/copy) or a `promised-file-url` whose file the source has already
    /// written (the floating screenshot thumbnail) — are expanded across *every*
    /// item: each becomes its own filename-tagged representation (a multi-select
    /// copy yields several). The inline snapshot, taken only when no item is a
    /// file, reads item 0. With `allowsBinary == false` (text-only transports)
    /// only the plain-text representation is taken.
    ///
    /// When the drag is clearly a file/image (a file URL or file promise is
    /// present) but no file is readable, the URL/path text representations are
    /// just the file's descriptor and are never returned as content — the
    /// caller falls through to asynchronous promise receipt instead of showing
    /// a path string.
    static func read(from pasteboard: NSPasteboard, allowsBinary: Bool) -> ClipboardIntakeResult {
        guard let items = pasteboard.pasteboardItems, let item = items.first else {
            return .rejected(message: "The Mac clipboard is empty")
        }

        // A concrete-or-promised file already on disk carries a URL, not the
        // file's bytes. File enumeration spans every item (a multi-select copy
        // puts one file per item); defer them so the caller reads each off the
        // main actor via `read(filesAt:)` (a large file mustn't block the UI).
        // Only file *enumeration* spans items — the inline snapshot below stays
        // item-0-scoped, since inline content is genuinely one item.
        let fileURLs = items.compactMap { existingFileURL(in: $0) }
        if !fileURLs.isEmpty {
            return .pendingFiles(fileURLs)
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
    /// the drag-and-drop file-promise receipt path (screenshot thumbnail,
    /// Photos, browsers), which delivers one file per completion.
    ///
    /// A thin wrapper over `read(filesAt:)`; multi-file pasteboard reads go
    /// through that directly.
    static func read(fileAt url: URL, allowsBinary: Bool) -> ClipboardIntakeResult {
        read(filesAt: [url], allowsBinary: allowsBinary)
    }

    /// Resolves dropped/copied files into disk-backed representations, one per
    /// URL in pasteboard order — the expansion for a multi-select
    /// `public.file-url` copy or drag.
    ///
    /// Each file crosses as a disk-backed `.file` representation: only a stat
    /// runs here (name + size + content UTI), and the bytes stream on demand
    /// when the peer requests them, so there is no size cap and the UI never
    /// blocks on a read. The other side materializes a real file — a Finder
    /// paste creates it, matching how macOS pastes a copied file — and an image
    /// additionally pastes inline (the receiver decides per UTI). The file's
    /// path never crosses, only its name. A file that fails to stat (or is
    /// empty) is skipped and noted; if *every* file fails the result is
    /// `.rejected`. Text-only transports (Linux/SPICE) can't carry files at all.
    static func read(filesAt urls: [URL], allowsBinary: Bool) -> ClipboardIntakeResult {
        guard allowsBinary else {
            return .rejected(message: Self.textOnlyTransportMessage)
        }
        var representations: [ClipboardContent.Representation] = []
        var skipped = 0
        for url in urls {
            guard
                let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
                let type = values.contentType,
                let fileSize = values.fileSize, fileSize > 0
            else {
                skipped += 1
                continue
            }
            representations.append(
                .init(
                    uti: type.identifier, fileURL: url, byteCount: fileSize,
                    filename: url.lastPathComponent))
        }
        guard !representations.isEmpty else {
            return .rejected(
                message: urls.count > 1
                    ? "Couldn't read the dropped files" : "Couldn't read the dropped file")
        }
        let note =
            skipped > 0 ? "Skipped \(skipped) unreadable file\(skipped == 1 ? "" : "s")" : nil
        return .content(ClipboardContent(representations: representations), note: note)
    }
}
