import AppKit
import KernovaKit
import UniformTypeIdentifiers
import os

/// Result of reading a pasteboard into the clipboard buffer.
enum ClipboardIntakeResult: Equatable, Sendable {
    /// Usable content. `note` carries a user-visible caveat when some
    /// representations were skipped (e.g. an oversized TIFF dropped while
    /// its PNG sibling survived).
    case content(ClipboardContent, note: String?)
    /// Nothing usable; `message` says why in user-facing terms.
    case rejected(message: String)
    /// One or more files resolved on disk whose bytes still have to be read off
    /// the main actor via `read(filesAt:)` before they become `.content`.
    ///
    /// Several URLs, in pasteboard order, for a multi-select copy/drag. Never
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
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "ClipboardPasteboardIntake")

    nonisolated static let textOnlyTransportMessage = "Only text can be shared with Linux guests"

    /// Reads `pasteboard` into clipboard content.
    ///
    /// Files already on disk are expanded across *every* item, each becoming its
    /// own filename-tagged representation; the inline snapshot reads item 0 and is
    /// taken only when no item is a file.
    ///
    /// When a file URL or promise is present but no file is readable, the URL/path
    /// text representations are only the file's descriptor and are never returned.
    static func read(from pasteboard: NSPasteboard, allowsBinary: Bool) -> ClipboardIntakeResult {
        guard let items = pasteboard.pasteboardItems, let item = items.first else {
            return .rejected(message: "The Mac clipboard is empty")
        }

        // Decided from the unfiltered type list, before any representation is
        // dropped or read. A concealed snapshot (a password) is still shared so it
        // can be pasted into the guest, but flagged so the window hides it.
        let disposition = ClipboardSnapshotPolicy.disposition(forTypes: item.types.map(\.rawValue))
        if case .suppress(let reason) = disposition {
            return .rejected(message: Self.suppressionMessage(for: reason))
        }
        let isConcealed = disposition == .conceal

        // Defer files so the caller reads each off the main actor via
        // `read(filesAt:)` — a large file mustn't block the UI. Only file
        // enumeration spans items; the inline snapshot below stays item-0-scoped.
        let fileURLs = items.compactMap { existingFileURL(in: $0) }
        if !fileURLs.isEmpty {
            return .pendingFiles(fileURLs)
        }

        guard allowsBinary else {
            guard let text = item.string(forType: .string), !text.isEmpty else {
                return .rejected(message: Self.textOnlyTransportMessage)
            }
            return .content(ClipboardContent(text: text, isConcealed: isConcealed), note: nil)
        }

        let isFileOrPromiseDrag = item.types.contains { isFileOrPromiseType($0.rawValue) }

        // Identity-based skips run before any data is read. A file/promise drag
        // additionally drops the URL/path text fallbacks, so a file drag can never
        // surface its path as text content.
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

        // `evaluate` builds non-concealed content; re-stamp the concealed flag
        // when the marker called for it.
        return .content(outcome.content.withConcealed(isConcealed), note: nil)
    }

    /// The user-facing reason a snapshot was dropped wholesale by an
    /// `org.nspasteboard.*` privacy marker.
    private static func suppressionMessage(
        for reason: ClipboardSnapshotPolicy.SkipReason
    ) -> String {
        switch reason {
        case .transientSnapshot:
            return "Transient clipboard content isn't shared"
        case .autoGeneratedSnapshot:
            return "Auto-generated clipboard content isn't shared"
        case .transientMarkerType, .fileReferenceType, .emptyData:
            // `disposition(forTypes:)` only ever suppresses with the two
            // snapshot reasons above; the rest are per-representation skips.
            return "This clipboard content isn't shared"
        }
    }

    /// A concrete `public.file-url` or a `promised-file-url` that already
    /// points at an on-disk file.
    ///
    /// `nil` when neither resolves to an existing file — e.g. a promise whose
    /// file hasn't been written yet, which the caller receives asynchronously.
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

    /// Resolves copied/dropped files **and folders** into representations, one
    /// per URL in pasteboard order.
    ///
    /// Runs off the main actor (the stat and the folder estimate walk are I/O).
    /// A directory — including an OS package such as `.app`/`.rtfd` — becomes a
    /// `.directory` source representation carrying a stat-walk size estimate; no
    /// archive is built until a paste requests the rep. An item that fails is
    /// skipped and noted; if *every* item fails, `.rejected`.
    nonisolated static func read(
        filesAt urls: [URL], allowsBinary: Bool
    ) async -> ClipboardIntakeResult {
        guard allowsBinary else {
            return .rejected(message: Self.textOnlyTransportMessage)
        }
        var representations: [ClipboardContent.Representation] = []
        var skipped = 0
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                skipped += 1
                continue
            }
            let rep =
                isDirectory.boolValue
                ? directorySourceRepresentation(at: url)
                : fileRepresentation(at: url)
            if let rep {
                representations.append(rep)
            } else {
                skipped += 1
            }
        }
        guard !representations.isEmpty else {
            return .rejected(
                message: urls.count > 1
                    ? "Couldn't read the dropped items" : "Couldn't read the dropped item")
        }
        let note =
            skipped > 0 ? "Skipped \(skipped) unreadable item\(skipped == 1 ? "" : "s")" : nil
        return .content(ClipboardContent(representations: representations), note: note)
    }

    /// Builds a disk-backed `.file` representation from a single file URL via a
    /// stat (name + size + content UTI), or `nil` when it can't be read (a
    /// directory has no `.fileSize`, so it returns `nil` here — the folder path
    /// builds a source rep instead).
    ///
    /// Size gates nothing: native macOS copies a zero-byte file, so one crosses
    /// at `byteCount == 0`.
    nonisolated private static func fileRepresentation(
        at url: URL
    ) -> ClipboardContent.Representation? {
        guard
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
            let type = values.contentType,
            let fileSize = values.fileSize
        else { return nil }
        return ClipboardContent.Representation(
            uti: type.identifier, fileURL: url, byteCount: fileSize,
            filename: url.lastPathComponent)
    }

    /// Builds a `.directory` **source** representation for a folder — no archive,
    /// a stat-walk size estimate, and the folder's content UTI.
    nonisolated private static func directorySourceRepresentation(
        at url: URL
    ) -> ClipboardContent.Representation? {
        let uti =
            (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.identifier
            ?? ClipboardDirectoryArchive.directoryUTI
        return ClipboardContent.Representation(
            directorySourceURL: url,
            estimatedByteCount: ClipboardDirectoryArchive.estimatedByteCount(at: url),
            filename: url.lastPathComponent, uti: uti)
    }
}
