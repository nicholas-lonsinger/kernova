import AppKit
import Foundation
import KernovaFileTree
import UniformTypeIdentifiers

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
    /// What ``resolve(filesAt:sizeOf:)`` made of the files it was handed.
    public struct FileIntake: Sendable {
        /// One representation per readable item, in the order the URLs came in.
        public let representations: [ClipboardContent.Representation]

        /// How many of the URLs produced no representation.
        public let skipped: Int

        /// Creates a resolve outcome.
        public init(representations: [ClipboardContent.Representation], skipped: Int) {
            self.representations = representations
            self.skipped = skipped
        }
    }

    // MARK: - Resolving files

    /// Resolves copied/dropped files **and folders** into representations, one
    /// per URL in the order they came in.
    ///
    /// Synchronous and payload-scaled — every `resourceValues` call is a
    /// `stat(2)` and a folder's estimate walks its whole tree — so the caller
    /// runs it off the main actor. A directory, including an OS package such as
    /// `.app`/`.rtfd`, becomes a `.directory` source representation carrying
    /// `sizeOf`'s estimate, or `0` when `sizeOf` is `nil` and nothing inside the
    /// folder is read. A folder is checked at its root only.
    ///
    /// The item is named from the URL that was copied or dragged while its
    /// bytes come from ``readableSource(for:opening:)``, so a symlink crosses as
    /// its target's content under the name the user acted on — what copying one
    /// in Finder delivers. Nothing here downloads a dataless file
    /// (``DatalessMaterialization/off``), so a dataless folder's estimate counts
    /// only what is on this Mac.
    nonisolated public static func resolve(
        filesAt urls: [URL],
        sizeOf: (@Sendable (URL) -> Int)? = { ClipboardDirectory.estimatedByteCount(at: $0) }
    ) -> FileIntake {
        DatalessMaterialization.off.during { resolveLocally(filesAt: urls, sizeOf: sizeOf) }
    }

    /// ``resolve(filesAt:sizeOf:)``'s work, downloading nothing.
    nonisolated private static func resolveLocally(
        filesAt urls: [URL], sizeOf: (@Sendable (URL) -> Int)?
    ) -> FileIntake {
        var representations: [ClipboardContent.Representation] = []
        var skipped = 0
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
                        directorySourceURL: source, estimatedByteCount: sizeOf?(source) ?? 0,
                        filename: filename,
                        uti: values.contentType?.identifier ?? ClipboardDirectory.uti))
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
    /// from one that never named a file.
    ///
    /// `.vanished` needs a `public.file-url` that *decoded* and then missed:
    /// declaring the type is not enough, because a lazy provider may vend no
    /// URL at all while the item's inline flavors remain readable.
    static func fileURLResolution(
        in item: any ClipboardPasteboardItemReading
    ) -> FileURLResolution {
        let candidates: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"),
        ]
        var missedConcreteURL = false
        // Only a declared type is read, so an item naming no file is never read at all.
        let declared = Set(item.types)
        for type in candidates where declared.contains(type) {
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
