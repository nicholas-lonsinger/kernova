import AppKit
import Foundation
import KernovaFileTree

/// The one place a local gesture — a Mac copy, a guest copy, a drag onto a VM
/// display — becomes what is offered for it, on either side of the wire.
///
/// A pasteboard read is cheap and main-thread-bound while resolving what it
/// named is `stat(2)`-scaled, so the stat-ing runs off the main actor. Each
/// caller reports the outcome on the surface owning its gesture, so nothing
/// here is user-facing copy: an outcome names a cause and a count, never a
/// message.
@MainActor
public enum ClipboardPasteboardReader {
    // MARK: - Sizing files

    /// The size a pull of the file or folder at `url` reads: a file's own size;
    /// a folder's — an OS package such as `.app`/`.rtfd` included — `sizeOf`
    /// estimate, or `0` when `sizeOf` is `nil` and nothing inside the folder is
    /// read; `nil` when there is nothing to read (``readableSource(for:opening:)``)
    /// or the system names no type or size for a file.
    ///
    /// Synchronous and payload-scaled — a `stat(2)`, and for a folder a walk of
    /// its whole tree — so the caller runs it off the main actor. A symlink is
    /// sized as what it resolves to. Nothing here downloads a dataless file
    /// (``DatalessMaterialization/off``), so a dataless folder's estimate counts
    /// only what is on this Mac.
    nonisolated public static func byteCount(
        ofItemAt url: URL,
        sizeOf: (@Sendable (URL) -> Int)? = { ClipboardDirectory.estimatedByteCount(at: $0) }
    ) -> Int? {
        DatalessMaterialization.off.during {
            guard let source = readableSource(for: url),
                let values = try? source.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .fileSizeKey])
            else { return nil }
            if values.isDirectory == true { return sizeOf?(source) ?? 0 }
            guard values.contentType != nil else { return nil }
            return values.fileSize
        }
    }

    /// Where one item's bytes are read from, or `nil` when there are none to
    /// read: a link with nothing at the end of it, an item this process may not
    /// open, one deleted since the gesture began.
    ///
    /// The item is opened for reading, as a pull of it opens it, by `open`,
    /// which answers `0` or the `errno` it failed with: neither `stat(2)` nor
    /// `access(2)` answers whether that open succeeds. A file in a guest's
    /// Photos library, mode `0644`, passed `isReadableFile(atPath:)` at a copy
    /// and failed the agent's open `EPERM` at its paste (macOS 27.2 guest,
    /// 2026-11-04), the privacy system refusing a process with no grant.
    ///
    /// The open runs with ``DatalessMaterialization/off``, so it never
    /// downloads a dataless file: one fails `EDEADLK`, which says only that its
    /// bytes are not on this Mac yet, and it is offered, its pull downloading
    /// it. Whether an open downloads one otherwise depends on the policy the
    /// process inherited, which a process started from a shell on macOS 27.2
    /// read as on (`getiopolicy_np`, 2026-11-04).
    nonisolated static func readableSource(
        for url: URL, opening open: (String) -> Int32 = ClipboardPasteboardReader.openForReading
    ) -> URL? {
        DatalessMaterialization.off.during {
            let isSymbolicLink =
                (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
            let source = isSymbolicLink ? url.resolvingSymlinksInPath() : url
            switch open(source.path) {
            case 0, EDEADLK: return source
            default: return nil
            }
        }
    }

    /// Opens `path` for reading and closes it: `0`, or the `errno` the open
    /// failed with.
    nonisolated static func openForReading(_ path: String) -> Int32 {
        let descriptor = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return errno }
        close(descriptor)
        return 0
    }

    // MARK: - Classifying one item

    /// What one pasteboard item contributes to the file enumeration.
    enum FileURLResolution {
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
    /// from one that never named a file. Its `public.file-url` is read by
    /// `fileURL`.
    ///
    /// `.vanished` needs a `public.file-url` that *decoded* and then missed:
    /// declaring the type is not enough, because a lazy provider may vend no
    /// URL at all while the item's inline flavors remain readable.
    static func fileURLResolution(
        in item: any ClipboardPasteboardItemReading, readingFileURL fileURL: () -> String?
    ) -> FileURLResolution {
        let candidates: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        ]
        var missedConcreteURL = false
        // Only a declared type is read, so an item naming no file is never read at all.
        let declared = Set(item.types)
        for type in candidates where declared.contains(type) {
            guard let string = type == .fileURL ? fileURL() : item.string(forType: type),
                let url = URL(string: string), url.isFileURL
            else { continue }
            if FileManager.default.fileExists(atPath: url.path) { return .resolved(url) }
            // Only `public.file-url` asserts the file exists now; a promise's is
            // an address for a file still to be written.
            if type == .fileURL { missedConcreteURL = true }
        }
        // A promise can still deliver through `NSFilePromiseReceiver`, so a
        // missed URL is not a loss while one is advertised.
        guard missedConcreteURL, !carriesPromiseReceiver(item) else { return .notAFile }
        return .vanished
    }

    /// `true` when `readObjects(forClasses: [NSFilePromiseReceiver.self])`
    /// yields a receiver for the item, whose asynchronous receipt can still
    /// produce the file: exactly when it declares one of the receiver's
    /// readable types.
    static func carriesPromiseReceiver(_ item: any ClipboardPasteboardItemReading) -> Bool {
        let readable = Set(NSFilePromiseReceiver.readableDraggedTypes)
        return item.types.contains { readable.contains($0.rawValue) }
    }
}
