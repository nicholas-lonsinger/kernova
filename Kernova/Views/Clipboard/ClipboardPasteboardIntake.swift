import AppKit
import KernovaProtocol
import UniformTypeIdentifiers
import os

/// Result of reading a pasteboard into the clipboard buffer.
///
/// `Sendable` so the off-main folder-archive resolve can return it across the
/// actor boundary back to the `@MainActor` controller.
enum ClipboardIntakeResult: Equatable, Sendable {
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
    // `nonisolated` so the off-main folder-archive resolve (`read(filesAt:…
    // staging:generation:)` and its `fileRepresentation`/`directoryRepresentation`
    // helpers) can log and reuse the transport message; both are `Sendable`.
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "ClipboardPasteboardIntake")

    nonisolated static let textOnlyTransportMessage = "Only text can be shared with Linux guests"

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

        // Snapshot-level `org.nspasteboard.*` marker handling, decided from the
        // unfiltered type list before any representation is dropped or read. A
        // transient or auto-generated snapshot is throwaway/unintended and never
        // shared; a concealed snapshot (a password) is still shared so it can be
        // pasted into the guest, but flagged so the window hides it.
        let disposition = ClipboardSnapshotPolicy.disposition(forTypes: item.types.map(\.rawValue))
        if case .suppress(let reason) = disposition {
            return .rejected(message: Self.suppressionMessage(for: reason))
        }
        let isConcealed = disposition == .conceal

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
            return .content(ClipboardContent(text: text, isConcealed: isConcealed), note: nil)
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

        // `evaluate` builds non-concealed content; re-stamp the concealed flag
        // when the marker called for it (cheap — inline snapshots are small).
        let content =
            isConcealed
            ? ClipboardContent(
                representations: outcome.content.representations, isConcealed: true)
            : outcome.content
        return .content(content, note: nil)
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

    /// Resolves dropped/copied *files* into disk-backed representations, one per
    /// URL in pasteboard order.
    ///
    /// Files only: a folder URL is skipped here. Each file crosses as a
    /// disk-backed `.file` representation built by `fileRepresentation(at:)`. A
    /// file that fails to stat (or is empty) is skipped and noted; if *every*
    /// file fails the result is `.rejected`. Every gesture that can carry a
    /// folder (a multi-select copy/drag, the file-promise receipt path) uses the
    /// `staging`/`generation` overload below instead.
    static func read(filesAt urls: [URL], allowsBinary: Bool) -> ClipboardIntakeResult {
        guard allowsBinary else {
            return .rejected(message: Self.textOnlyTransportMessage)
        }
        var representations: [ClipboardContent.Representation] = []
        var skipped = 0
        for url in urls {
            if let rep = fileRepresentation(at: url) {
                representations.append(rep)
            } else {
                skipped += 1
            }
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

    /// Resolves copied/dropped files **and folders** into representations, one
    /// per URL in pasteboard order — the multi-select `public.file-url`
    /// expansion that can mix the two.
    ///
    /// Runs off the main actor (stat + archive are I/O). A plain file is stat'd
    /// into a `.file` representation (name + size + content UTI), its bytes
    /// streamed on demand. A directory — including an OS package such as
    /// `.app`/`.rtfd` — is packed *eagerly* into a single AppleArchive (`.aar`,
    /// LZFSE) under `staging`/`generation` and crosses as one directory
    /// representation (`uti = public.folder`, `isDirectory = true`, the folder
    /// name in `filename`); the receiver extracts it back into a real folder so
    /// a Finder paste recreates the tree. Eager archiving is required because the
    /// offer needs the archive's size up front and the stream its SHA-256.
    /// An item that fails to stat/archive is skipped and noted; if *every* item
    /// fails the result is `.rejected`. Text-only transports can't carry files.
    nonisolated static func read(
        filesAt urls: [URL], allowsBinary: Bool, staging: ClipboardFileStaging, generation: UInt64
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
                ? directoryRepresentation(at: url, staging: staging, generation: generation)
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
    /// stat (name + size + content UTI), or `nil` when it can't be read or is
    /// empty (a directory has no `.fileSize`, so it returns `nil` here — the
    /// folder path archives it instead).
    nonisolated private static func fileRepresentation(
        at url: URL
    ) -> ClipboardContent.Representation? {
        guard
            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey]),
            let type = values.contentType,
            let fileSize = values.fileSize, fileSize > 0
        else { return nil }
        return ClipboardContent.Representation(
            uti: type.identifier, fileURL: url, byteCount: fileSize,
            filename: url.lastPathComponent)
    }

    /// Archives the directory at `url` into a staged directory representation, or
    /// `nil` if archiving fails (skipped + noted by callers).
    ///
    /// A thin logging wrapper over the shared
    /// `ClipboardDirectoryArchive.archivedRepresentation`, which the guest agent
    /// also calls so the archive/UTI/sizing rules stay identical on both ends.
    nonisolated private static func directoryRepresentation(
        at url: URL, staging: ClipboardFileStaging, generation: UInt64
    ) -> ClipboardContent.Representation? {
        let folderName = url.lastPathComponent
        do {
            return try ClipboardDirectoryArchive.archivedRepresentation(
                ofDirectoryAt: url, named: folderName, into: staging, generation: generation)
        } catch {
            logger.error(
                "Failed to archive folder '\(folderName, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
