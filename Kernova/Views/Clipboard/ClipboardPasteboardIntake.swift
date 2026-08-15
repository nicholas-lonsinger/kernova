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
    ///
    /// `unreadable` is `true` only when representations were present and could
    /// not be read — a loss the user is owed a report for. A policy verdict (an
    /// empty clipboard, a privacy marker, a text-only transport refusing a file)
    /// is `false`: nothing was there to lose.
    case rejected(message: String, unreadable: Bool)
    /// Files whose bytes still have to be read off the main actor via
    /// `read(filesAt:)` before they become `.content`.
    ///
    /// Several URLs, in pasteboard order, for a multi-select copy/drag.
    /// `unresolved` counts the copied files that no longer exist, so
    /// `read(filesAt:)` can report them alongside the ones it fails itself.
    /// Never applied directly.
    case pendingFiles([URL], unresolved: Int)
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
    /// taken only when no item resolved to a file on disk.
    ///
    /// When a file URL or promise is present but no file is readable, the URL/path
    /// text representations are only the file's descriptor and are never returned.
    static func read(from pasteboard: NSPasteboard, allowsBinary: Bool) -> ClipboardIntakeResult {
        guard let items = pasteboard.pasteboardItems, let item = items.first else {
            return .rejected(message: "The Mac clipboard is empty", unreadable: false)
        }

        // Decided from the unfiltered type list, before any representation is
        // dropped or read. A concealed snapshot (a password) is still shared so it
        // can be pasted into the guest, but flagged so the window hides it.
        let disposition = ClipboardSnapshotPolicy.disposition(forTypes: item.types.map(\.rawValue))
        if case .suppress(let reason) = disposition {
            return .rejected(message: Self.suppressionMessage(for: reason), unreadable: false)
        }
        let isConcealed = disposition == .conceal

        // Defer files so the caller reads each off the main actor via
        // `read(filesAt:)` — a large file mustn't block the UI. Only file
        // enumeration spans items; the inline snapshot below stays item-0-scoped.
        var fileURLs: [URL] = []
        var unresolvedFiles = 0
        var firstItemVanished = false
        for (index, candidate) in items.enumerated() {
            switch fileURLResolution(in: candidate) {
            case .resolved(let url): fileURLs.append(url)
            case .vanished:
                unresolvedFiles += 1
                if index == 0 { firstItemVanished = true }
            case .notAFile: break
            }
        }
        if !fileURLs.isEmpty {
            return .pendingFiles(fileURLs, unresolved: unresolvedFiles)
        }
        // No file survived, but an item that lost its file can still carry an
        // inline flavor to be served from — `HostClipboardPublisher` pairs an
        // image UTI with `.fileURL` for exactly that fallback. So a vanished
        // count travels *through* the inline read below rather than
        // short-circuiting it.

        guard allowsBinary else {
            // A file copy's path text is the file's descriptor, not content, and
            // a text-only transport refuses file copies by policy either way.
            guard unresolvedFiles == 0, let text = item.string(forType: .string), !text.isEmpty
            else {
                return .rejected(message: Self.textOnlyTransportMessage, unreadable: false)
            }
            return .content(ClipboardContent(text: text, isConcealed: isConcealed), note: nil)
        }

        let isFileOrPromiseDrag = item.types.contains { isFileOrPromiseType($0.rawValue) }

        // Identity-based skips run before any data is read. A file/promise drag
        // additionally drops the URL/path text fallbacks, so a file drag can never
        // surface its path as text content.
        let qualified = item.types.filter { type in
            guard !ClipboardSnapshotPolicy.shouldSkipBeforeReading(uti: type.rawValue) else {
                return false
            }
            return !(isFileOrPromiseDrag && isPathFallbackType(type.rawValue))
        }
        let raw: [(uti: String, data: Data)] = qualified.compactMap { type in
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
            guard unresolvedFiles == 0 else {
                // Every file the copy named is gone and no inline flavor stood in
                // for one — the same total loss `read(filesAt:)` reports.
                return .rejected(
                    message: Self.unreadableItemsMessage(count: unresolvedFiles), unreadable: true)
            }
            // A qualifying type whose `data(forType:)` came back nil is content
            // the pasteboard held and would not hand over — a loss, unlike a
            // snapshot that never had anything shareable in it.
            return .rejected(
                message: "The Mac clipboard has no shareable content",
                unreadable: raw.count < qualified.count)
        }

        // The inline snapshot is item-0-scoped, so surviving content stands in
        // for item 0's own vanished file — the dual-flavor image is that case.
        // Files on the *other* items had nothing to stand in for them.
        let reportedLosses = unresolvedFiles - (firstItemVanished ? 1 : 0)

        // `evaluate` builds non-concealed content; re-stamp the concealed flag
        // when the marker called for it.
        return .content(
            outcome.content.withConcealed(isConcealed),
            note: Self.skipNote(forSkipped: reportedLosses))
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

    /// What one pasteboard item contributes to the file enumeration.
    private enum FileURLResolution {
        /// A concrete `public.file-url` or a `promised-file-url` that already
        /// points at an on-disk file.
        case resolved(URL)
        /// The item handed over a concrete `public.file-url` that resolves to
        /// nothing today — a copy whose file was deleted, renamed, or unmounted
        /// since. The bytes are gone, so the item is a loss the caller counts.
        case vanished
        /// No concrete file URL: a plain snapshot, a promise whose file hasn't
        /// been written yet and which the caller receives asynchronously, or an
        /// item whose file-URL provider declined to vend one.
        case notAFile
    }

    /// Classifies an item's file URLs, separating a copy that lost its file
    /// from one that never named a file.
    ///
    /// `.vanished` needs a `public.file-url` that *decoded* and then missed:
    /// declaring the type is not enough, because a lazy provider may vend no
    /// URL at all while the item's inline flavors remain readable.
    private static func fileURLResolution(in item: NSPasteboardItem) -> FileURLResolution {
        let candidates: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        ]
        var missedConcreteURL = false
        for type in candidates {
            guard let string = item.string(forType: type),
                let url = URL(string: string), url.isFileURL
            else { continue }
            if FileManager.default.fileExists(atPath: url.path) { return .resolved(url) }
            // Only `public.file-url` asserts the file exists now; a promise's is
            // an address for a file still to be written.
            if type == .fileURL { missedConcreteURL = true }
        }
        // A promise can still deliver through `NSFilePromiseReceiver`, so a
        // missed URL is not a loss while one is advertised.
        guard missedConcreteURL, !promisesFile(item) else { return .notAFile }
        return .vanished
    }

    /// `true` when the item advertises a file promise, whose asynchronous
    /// receipt can still produce the file.
    private static func promisesFile(_ item: NSPasteboardItem) -> Bool {
        item.types.contains {
            $0.rawValue.hasPrefix("com.apple.pasteboard.promised-file")
                || $0.rawValue.hasPrefix("com.apple.NSFilePromise")
        }
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
    ///
    /// `unresolved` is the count `read(from:)` already dropped for having no
    /// file left on disk, folded into the same note so one report covers every
    /// item the copy lost on either side of the actor hop.
    nonisolated static func read(
        filesAt urls: [URL], unresolved: Int = 0, allowsBinary: Bool
    ) async -> ClipboardIntakeResult {
        guard allowsBinary else {
            return .rejected(message: Self.textOnlyTransportMessage, unreadable: false)
        }
        var representations: [ClipboardContent.Representation] = []
        var skipped = unresolved
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
                message: Self.unreadableItemsMessage(count: skipped), unreadable: true)
        }
        return .content(
            ClipboardContent(representations: representations),
            note: Self.skipNote(forSkipped: skipped))
    }

    /// The note shown when a copy went through with `count` of its items lost,
    /// or `nil` when none were.
    nonisolated private static func skipNote(forSkipped count: Int) -> String? {
        guard count > 0 else { return nil }
        return "Skipped \(count) unreadable item\(count == 1 ? "" : "s")"
    }

    /// The rejection shown when *every* item of a copy was lost.
    nonisolated private static func unreadableItemsMessage(count: Int) -> String {
        count > 1 ? "Couldn't read the dropped items" : "Couldn't read the dropped item"
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
            ?? ClipboardArchive.directoryUTI
        return ClipboardContent.Representation(
            directorySourceURL: url,
            estimatedByteCount: ClipboardArchive.estimatedByteCount(at: url),
            filename: url.lastPathComponent, uti: uti)
    }
}
