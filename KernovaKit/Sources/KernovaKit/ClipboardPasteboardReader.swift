import AppKit
import Foundation
import UniformTypeIdentifiers

/// The one place a local gesture — a Mac copy, a guest copy, a drag onto a VM
/// display — becomes outbound `ClipboardContent`, on either side of the wire.
///
/// Two stages, because a pasteboard read is cheap and main-thread-bound while
/// resolving what it named is `stat(2)`-scaled (docs/CLIPBOARD.md §8):
/// ``readSnapshot(from:allowsBinary:)`` classifies the snapshot, and
/// ``resolve(filesAt:unresolved:sizeOf:)`` reads the files it deferred. Each
/// caller runs the second stage on whatever hop it already has and reports the
/// outcome on the surface owning its gesture, so nothing here is user-facing
/// copy: an outcome names a cause and a count, never a message.
///
/// There is **no size cap**: a copied file becomes a disk-backed representation
/// whose bytes stream on demand.
@MainActor
public enum ClipboardPasteboardReader {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardPasteboardReader")

    /// What a pasteboard snapshot turned out to be.
    public enum Outcome: Sendable {
        /// The pasteboard holds no item at all.
        case empty

        /// An `org.nspasteboard.*` marker dropped the whole snapshot; nothing
        /// was lost because nothing was ever a deliberate copy.
        case suppressed(ClipboardSnapshotPolicy.SkipReason)

        /// A transport that carries text only was handed a file copy, or a
        /// snapshot with no text in it. Nothing was lost: it is a policy verdict.
        case textOnlyRefusal

        /// Files on disk, in pasteboard order, whose bytes
        /// ``resolve(filesAt:unresolved:sizeOf:)`` still has to read off the
        /// caller's actor.
        ///
        /// `unresolved` counts the copied files that no longer exist, so the
        /// resolve stage reports them alongside the ones it fails itself.
        case pendingFiles([URL], unresolved: Int)

        /// Content to offer, with `skipped` counting what the same gesture
        /// carried and this content leaves out.
        case content(ClipboardContent, skipped: Int)

        /// The snapshot held items but yielded nothing offerable.
        ///
        /// `lost` counts the files the copy named that are gone; `unreadable`
        /// is `true` when representations were present and could not be read —
        /// a loss, unlike a snapshot that never had anything shareable in it.
        case nothingOfferable(lost: Int, unreadable: Bool)
    }

    /// What the resolve stage made of the files a snapshot deferred.
    public struct FileIntake: Sendable {
        /// One representation per readable item, in the order the URLs came in.
        public let representations: [ClipboardContent.Representation]

        /// How many items of the same gesture produced no representation —
        /// those the snapshot already knew were gone, plus those this stage
        /// could not read.
        public let skipped: Int

        /// Creates a resolve outcome.
        public init(representations: [ClipboardContent.Representation], skipped: Int) {
            self.representations = representations
            self.skipped = skipped
        }
    }

    // MARK: - Stage 1: the snapshot

    /// Classifies what is standing on `pasteboard`, reading no file bytes.
    ///
    /// Files already on disk are enumerated across *every* item and deferred to
    /// the resolve stage; the inline snapshot reads item 0 and is taken only
    /// when no item resolved to a file on disk.
    ///
    /// When a file URL or promise is present but no file survives, the URL/path
    /// text representations are only the file's descriptor and are never
    /// returned as content.
    ///
    /// `allowsBinary` is `false` for a transport that carries plain text alone,
    /// which refuses a file copy by policy rather than sending its path.
    public static func readSnapshot(
        from pasteboard: any ClipboardReadPasteboard, allowsBinary: Bool
    ) -> Outcome {
        let items = pasteboard.items
        guard let item = items.first else { return .empty }

        // Decided from the unfiltered type list, before any representation is
        // dropped or read. A concealed snapshot (a password) still crosses so it
        // can be pasted into the peer, but is flagged so a display hides it.
        let disposition = ClipboardSnapshotPolicy.disposition(forTypes: item.types.map(\.rawValue))
        if case .suppress(let reason) = disposition { return .suppressed(reason) }
        let isConcealed = disposition == .conceal

        // Only file enumeration spans items; the inline snapshot below stays
        // item-0-scoped.
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
        // inline flavor to be served from — a publisher pairs an image UTI with
        // `.fileURL` for exactly that fallback. So a vanished count travels
        // *through* the inline read below rather than short-circuiting it.

        guard allowsBinary else {
            // A file copy's path text is the file's descriptor, not content, and
            // a text-only transport refuses file copies by policy either way.
            guard unresolvedFiles == 0, let text = item.string(forType: .string), !text.isEmpty
            else { return .textOnlyRefusal }
            return .content(ClipboardContent(text: text, isConcealed: isConcealed), skipped: 0)
        }

        let isFileOrPromiseDrag = item.types.contains { isFileOrPromiseType($0.rawValue) }

        // Identity-based skips run before any data is read. A file/promise copy
        // additionally drops the URL/path text fallbacks, so one can never
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
            logger.info("Pasteboard snapshot skipped: \(summary, privacy: .public)")
        }

        guard !outcome.content.isEmpty else {
            // A qualifying type whose `data(forType:)` came back nil is content
            // the pasteboard held and would not hand over — a loss, unlike a
            // snapshot that never had anything shareable in it.
            return .nothingOfferable(
                lost: unresolvedFiles, unreadable: unresolvedFiles > 0 || raw.count < qualified.count
            )
        }

        // The inline snapshot is item-0-scoped, so surviving content stands in
        // for item 0's own vanished file — the dual-flavor image is that case.
        // Files on the *other* items had nothing to stand in for them.
        let reportedLosses = unresolvedFiles - (firstItemVanished ? 1 : 0)

        // `evaluate` builds non-concealed content; re-stamp the concealed flag
        // when the marker called for it.
        return .content(outcome.content.withConcealed(isConcealed), skipped: reportedLosses)
    }

    // MARK: - Stage 2: resolving the files

    /// Resolves copied/dropped files **and folders** into representations, one
    /// per URL in the order they came in.
    ///
    /// Synchronous and payload-scaled — every `resourceValues` call is a
    /// `stat(2)` and a folder's estimate walks its whole tree — so the caller
    /// runs it off the main actor (docs/CLIPBOARD.md §8). A directory,
    /// including an OS package such as `.app`/`.rtfd`, becomes a `.directory`
    /// source representation carrying a stat-walk estimate; no archive is built
    /// until the peer requests the rep. A folder is checked at its root only:
    /// AppleArchive's directory encoder has no per-entry skip, so an entry
    /// inside one that cannot be read fails that folder's own transfer, which
    /// the batch then leaves out the way it leaves out any other unreadable
    /// item.
    ///
    /// The item is named from the URL that was copied or dragged while its
    /// bytes come from ``readableSource(for:)``, so a symlink crosses as its
    /// target's content under the name the user acted on — what copying one in
    /// Finder delivers.
    ///
    /// `unresolved` is what the snapshot stage already dropped for having no
    /// file left on disk, folded into the same count so one report covers every
    /// item the gesture lost on either side of the hop. `sizeOf` is injected so
    /// a test can size a folder without building one.
    nonisolated public static func resolve(
        filesAt urls: [URL], unresolved: Int = 0,
        sizeOf: @Sendable (URL) -> Int = { ClipboardArchive.estimatedByteCount(at: $0) }
    ) -> FileIntake {
        var representations: [ClipboardContent.Representation] = []
        var skipped = unresolved
        for url in urls {
            guard let source = readableSource(for: url),
                let values = try? source.resourceValues(forKeys: [
                    .contentTypeKey, .isDirectoryKey, .fileSizeKey,
                ])
            else {
                skipped += 1
                continue
            }
            // The name the user copied or dragged, whatever the bytes are read
            // from.
            let filename = url.lastPathComponent
            if values.isDirectory == true {
                representations.append(
                    ClipboardContent.Representation(
                        directorySourceURL: source, estimatedByteCount: sizeOf(source),
                        filename: filename,
                        uti: values.contentType?.identifier ?? ClipboardArchive.directoryUTI))
            } else if let type = values.contentType, let size = values.fileSize {
                // Size gates nothing: native macOS copies a zero-byte file, so
                // one crosses at `byteCount == 0`.
                representations.append(
                    ClipboardContent.Representation(
                        uti: type.identifier, fileURL: source, byteCount: size, filename: filename))
            } else {
                skipped += 1
            }
        }
        return FileIntake(representations: representations, skipped: skipped)
    }

    /// Where one item's bytes are read from, or `nil` when there are none to
    /// read: a link with nothing at the end of it, an item this process cannot
    /// open, one deleted since the gesture began.
    ///
    /// `stat(2)` alone answers none of this — a mode-`000` file stats exactly
    /// like a readable one — so the open permission is asked for separately.
    nonisolated private static func readableSource(for url: URL) -> URL? {
        let isSymbolicLink =
            (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
        let source = isSymbolicLink ? url.resolvingSymlinksInPath() : url
        guard (try? source.checkResourceIsReachable()) == true,
            FileManager.default.isReadableFile(atPath: source.path)
        else { return nil }
        return source
    }

    // MARK: - Classifying one item

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
    private static func fileURLResolution(
        in item: any ClipboardPasteboardItemReading
    ) -> FileURLResolution {
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
    private static func promisesFile(_ item: any ClipboardPasteboardItemReading) -> Bool {
        item.types.contains {
            $0.rawValue.hasPrefix("com.apple.pasteboard.promised-file")
                || $0.rawValue.hasPrefix("com.apple.NSFilePromise")
        }
    }

    /// `true` for the types that mark a snapshot as a file or file promise.
    private static func isFileOrPromiseType(_ uti: String) -> Bool {
        uti == "public.file-url" || uti == "NSFilenamesPboardType"
            || uti.hasPrefix("com.apple.pasteboard.promised-file")
            || uti.hasPrefix("com.apple.NSFilePromise")
    }

    /// `true` for text/URL types that, in a file/promise snapshot, merely
    /// describe the file's path or name rather than being real content.
    private static func isPathFallbackType(_ uti: String) -> Bool {
        uti == "public.url" || uti == "public.utf8-plain-text"
            || uti == "Apple URL pasteboard type"
    }
}
