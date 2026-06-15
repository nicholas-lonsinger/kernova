import Foundation

/// Materializes filename-bearing clipboard representations to real local temp
/// files so a receiver can put a concrete `public.file-url` on the pasteboard
/// — the only mechanism by which a Finder **Paste** creates a file (a pasteboard
/// `NSFilePromiseProvider` is a drag-session API and is not fulfilled by paste).
///
/// One *generation* directory per `stage(_:)` call. The previous generation is
/// deleted as soon as the next one is materialized, bounding disk use to a
/// single payload per instance. `sweep()` clears everything (crash orphans and
/// the current generation).
///
/// `@unchecked Sendable` with an internal lock: a host window controller and a
/// guest agent each own one instance and call it from a single
/// queue/actor, but the lock makes concurrent use safe regardless.
public final class ClipboardFileStaging: @unchecked Sendable {
    /// One staged file: the originating representation's UTI and the local URL
    /// the bytes were written to.
    public struct Staged: Equatable, Sendable {
        /// The originating representation's UTI.
        public let uti: String

        /// The local file the bytes were written to.
        public let url: URL

        /// Creates a staged-file record.
        public init(uti: String, url: URL) {
            self.uti = uti
            self.url = url
        }
    }

    private let root: URL
    private let lock = NSLock()
    private var lastGenerationDir: URL?

    /// - Parameter label: distinguishes co-resident roots (e.g. `"agent"` vs
    ///   `"host"`); the host app and guest agent run in different processes and
    ///   filesystems, but the label keeps multiple roots from colliding.
    public init(label: String) {
        root =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaClipboardStaging-\(label)", isDirectory: true)
    }

    /// Writes every filename-bearing representation to a fresh generation directory.
    ///
    /// Returns the staged files in order and supersedes (deletes) the previous
    /// generation. Best-effort: a directory or write failure drops that file
    /// (the caller falls back to inline-only), never throws.
    public func stage(_ representations: [ClipboardContent.Representation]) -> [Staged] {
        let fileReps = representations.filter { !$0.filename.isEmpty }
        guard !fileReps.isEmpty else { return [] }

        lock.lock()
        defer { lock.unlock() }

        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard
            (try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)) != nil
        else { return [] }

        var staged: [Staged] = []
        for representation in fileReps {
            let url = dir.appendingPathComponent(Self.sanitize(representation.filename))
            if (try? representation.data.write(to: url)) != nil {
                staged.append(Staged(uti: representation.uti, url: url))
            }
        }

        if staged.isEmpty {
            try? FileManager.default.removeItem(at: dir)
            return []
        }

        // Supersede the previous generation now that the new one is live.
        if let previous = lastGenerationDir {
            try? FileManager.default.removeItem(at: previous)
        }
        lastGenerationDir = dir
        return staged
    }

    /// Off-actor variant of `stage(_:)` for large payloads.
    ///
    /// `stage` writes every filename-bearing representation to disk on the
    /// calling actor/queue — a multi-hundred-millisecond stall for a 100 MiB
    /// file on the `@MainActor` or the guest run loop. This `async` wrapper is
    /// not actor-isolated, so awaiting it runs the writes on the cooperative
    /// executor. Identical best-effort semantics and generation supersession.
    public func stageAsync(
        _ representations: [ClipboardContent.Representation]
    ) async -> [Staged] {
        stage(representations)
    }

    /// Removes the entire staging root — crash orphans and the current generation.
    ///
    /// Call on agent start/stop and capability disable.
    public func sweep() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root)
        lastGenerationDir = nil
    }

    /// Reduces a suggested filename to a single safe path component so a
    /// crafted name (`"../escape"`, `"a/b"`) can't write outside the
    /// generation directory.
    private static func sanitize(_ filename: String) -> String {
        let base = (filename as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "clipboard-file" : cleaned
    }
}
