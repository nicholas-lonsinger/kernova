import Foundation
import KernovaLogging
import KernovaSynchronization
import System

/// Materializes streamed file representations to real local temp files so a
/// receiver can put a concrete `public.file-url` on the pasteboard — the only
/// mechanism by which a Finder **Paste** creates a file. Verified 2026-08-15
/// (macOS 26): an `NSFilePromiseProvider` written to `NSPasteboard.general`
/// advertises its promise types, but ⌘V in Finder creates nothing and TextEdit
/// pastes nothing, and neither calls the provider's delegate; a `public.file-url`
/// on the same pasteboard pastes in both.
///
/// One directory per offer generation, kept for as long as its ``Retention``
/// says; `sweep()` clears everything.
///
/// Each instance owns a private root (the label plus a per-instance component)
/// under its process's ``ProcessStagingRoot``, so no instance's `sweep()` can
/// delete files another instance staged — a URL vended to a pasteboard outlives
/// the session that staged it. Roots left behind by the same process's earlier
/// instances are reclaimed by `reclaimSiblingRoots()` once nothing can be serving
/// from them; an exited process's whole root, by the next launch's
/// ``ProcessStagingRoot/reclaimAbandonedRoots()``.
public final class ClipboardFileStaging: Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardFileStaging")

    /// Queries free capacity (in bytes) for important, user-initiated writes at
    /// the given directory.
    public typealias FreeSpaceProvider = @Sendable (URL) -> Int64?

    /// Number of recent generation directories ``Retention/newest(_:)`` keeps
    /// alive for staging that replaces what it last vended.
    public static let maxGenerations = 3

    /// How long a generation's directory lives.
    enum Retention: Equatable, Sendable {
        /// The newest `count` generations are kept, so a pasteboard URL a newer
        /// offer replaced survives while Finder copies it out; the generation
        /// past `count` deletes the oldest.
        case newest(Int)
        /// A generation's directory lives until ``discardGeneration(_:)``,
        /// which its owner calls once nothing can read it, and nothing else
        /// deletes it. A discarded generation is never created again.
        case untilDiscarded
    }

    /// An open append-only sink for one streamed file representation.
    ///
    /// Concurrent `write`/`commit`/`abort` are serialized: each does its I/O
    /// under the lock the handle lives in.
    public final class Sink: Sendable {
        private struct State: Sendable {
            let handle: FileHandle
            var finished = false
        }

        /// The local file the bytes are being written to.
        let url: URL

        private let state: Locked<State>

        init(url: URL, handle: FileHandle) {
            self.url = url
            self.state = Locked(State(handle: handle))
        }

        /// Appends a chunk to the file.
        ///
        /// - Throws: any error from `FileHandle.write(contentsOf:)` (e.g. the
        ///   volume filling mid-stream).
        public func write(_ data: Data) throws {
            try state.withLock { state in
                guard !state.finished else { return }
                try state.handle.write(contentsOf: data)
            }
        }

        /// Closes the file and keeps it; the bytes are complete.
        ///
        /// Returns the final URL. Idempotent.
        ///
        /// - Throws: an error from `FileHandle.close()`. With `F_NOCACHE` and no
        ///   `fsync` the kernel can defer a write failure to `close()`, so
        ///   swallowing it delivers a truncated file that still passed the
        ///   in-flight digest check. The partial is deleted on a close failure.
        @discardableResult
        public func commit() throws -> URL {
            try state.withLock { state in
                guard !state.finished else { return url }
                state.finished = true
                do {
                    try state.handle.close()
                } catch {
                    ClipboardFileStaging.discard(url)
                    throw error
                }
                return url
            }
        }

        /// Closes the file and deletes the partial.
        ///
        /// Idempotent.
        public func abort() {
            state.withLock { state in
                guard !state.finished else { return }
                state.finished = true
                try? state.handle.close()
                ClipboardFileStaging.discard(url)
            }
        }
    }

    private let processRoot: ProcessStagingRoot
    private let root: URL
    private let retention: Retention
    private let freeSpaceProvider: FreeSpaceProvider

    /// The lock also serializes every filesystem change under ``root``, so the
    /// I/O each method does stays inside its `withLock`.
    private struct State: Sendable {
        /// Generation directories in arrival order (oldest first).
        var generationDirs: [GenerationDir] = []

        /// The generations ``Retention/untilDiscarded`` has discarded.
        var discarded: Set<UInt64> = []

        /// Returns the directory for `generation` under `root`, creating it on
        /// first use and evicting whatever `retention` no longer keeps.
        ///
        /// - Throws: `CocoaError(.fileNoSuchFile)` for a generation already
        ///   discarded, or a filesystem error if the directory can't be created.
        mutating func directory(
            for generation: UInt64, root: URL, processRoot: ProcessStagingRoot,
            retention: Retention
        ) throws -> URL {
            if let existing = generationDirs.first(where: { $0.generation == generation }) {
                return existing.dir
            }
            guard !discarded.contains(generation) else { throw CocoaError(.fileNoSuchFile) }
            let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try processRoot.createDirectory(at: dir)
            generationDirs.append(GenerationDir(generation: generation, dir: dir))
            if case .newest(let count) = retention {
                while generationDirs.count > count {
                    let oldest = generationDirs.removeFirst()
                    ClipboardFileStaging.discard(oldest.dir)
                }
            }
            return dir
        }
    }

    private struct GenerationDir: Sendable {
        let generation: UInt64
        let dir: URL
    }

    private let state = Locked(State())

    /// This process's root for clipboard staging, the host's and the guest
    /// agent's alike.
    public static let processRoot = ProcessStagingRoot(
        parent: FileManager.default.temporaryDirectory.appendingPathComponent(
            "KernovaClipboardStaging", isDirectory: true))

    /// Staging that keeps the newest ``maxGenerations`` generations.
    ///
    /// - Parameters:
    ///   - label: distinguishes co-resident roots (e.g. `"agent"` vs `"host"`).
    ///     The root nests a unique per-instance component under the label, so two
    ///     same-label instances (a VM's next session) never share a root.
    ///   - root: the process root the label nests under — ``processRoot`` in
    ///     production.
    ///   - freeSpaceProvider: queries available capacity; defaults to
    ///     `volumeAvailableCapacityForImportantUsageKey`.
    public convenience init(
        label: String,
        root: ProcessStagingRoot,
        freeSpaceProvider: FreeSpaceProvider? = nil
    ) {
        self.init(
            label: label, root: root, retention: .newest(Self.maxGenerations),
            freeSpaceProvider: freeSpaceProvider)
    }

    /// Staging for what `role` pulls from its peer's offers on `kind`'s
    /// channel, kept for as long as that flow's discipline says.
    ///
    /// Parameters as ``init(label:root:freeSpaceProvider:)``.
    public convenience init(
        label: String,
        root: ProcessStagingRoot,
        receivingOn kind: ClipboardControlSession.Kind,
        as role: ClipboardControlSession.Role,
        freeSpaceProvider: FreeSpaceProvider? = nil
    ) {
        self.init(
            label: label, root: root,
            retention: ClipboardOfferDiscipline(kind: kind, receiver: role).stagingRetention,
            freeSpaceProvider: freeSpaceProvider)
    }

    init(
        label: String,
        root: ProcessStagingRoot,
        retention: Retention,
        freeSpaceProvider: FreeSpaceProvider?
    ) {
        processRoot = root
        self.retention = retention
        self.root =
            root.url
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.freeSpaceProvider = freeSpaceProvider ?? Self.defaultFreeSpace
    }

    /// Available capacity for important writes at the staging root's volume, in
    /// bytes, or `nil` if it can't be determined.
    public func availableCapacity() -> Int64? {
        freeSpaceProvider(root)
    }

    /// Whether `url` points inside this staging root.
    ///
    /// The outbound pasteboard poll skips these so a file received from the peer
    /// is never offered back to it.
    public func isInStagingRoot(_ url: URL) -> Bool {
        Self.isURL(url, inside: root)
    }

    /// Whether `url` is `directory` itself or something under it.
    ///
    /// The prefix is component-bounded, so a sibling whose name extends
    /// `directory`'s (`agent` vs `agent-send`) never matches.
    public static func isURL(_ url: URL, inside directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }

    /// Whether `byteCount` bytes (plus `margin`) fit on the staging volume.
    ///
    /// `volumeAvailableCapacityForImportantUsageKey` **includes purgeable
    /// space**, so it can exceed raw free bytes (WWDC17 "What's New in
    /// Foundation"); the margin keeps a transfer from filling the volume to the
    /// last byte. An unknown capacity is treated as "fits", and a size whose
    /// margined total leaves `Int64` as "does not fit" — the caller's `byteCount`
    /// can come from a peer-declared size.
    public func hasCapacity(
        forByteCount byteCount: Int, margin: Int = ClipboardStreamTuning.freeSpaceMargin
    ) -> Bool {
        guard let available = availableCapacity() else { return true }
        let (needed, overflow) = Int64(byteCount).addingReportingOverflow(Int64(margin))
        guard !overflow else { return false }
        return needed <= available
    }

    /// Opens an append-only sink for a streamed file representation, creating
    /// (or reusing) the directory for `generation` and evicting what the
    /// retention no longer keeps.
    ///
    /// - Throws: a filesystem error if the directory or file can't be created,
    ///   or `generation` was discarded.
    public func makeSink(generation: UInt64, filename: String) throws -> Sink {
        try state.withLock { state in
            let dir = try state.directory(
                for: generation, root: root, processRoot: processRoot, retention: retention)
            // One multi-file copy can carry two payloads that share a name;
            // reusing the first's path would collapse the two files into one.
            let url = NameUniquing.uniqueDestination(in: dir, filename: filename)
            // `F_NOCACHE` keeps a multi-GB transfer from evicting the page cache.
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
            return Sink(url: url, handle: handle)
        }
    }

    /// Reserves an empty child directory named exactly `name` under the
    /// generation directory, for the receiver to extract a directory tree into.
    ///
    /// Nested under a fresh UUID parent so the folder keeps its *exact* name: a
    /// same-named sibling in the generation directory would otherwise force a
    /// ` 2` suffix onto it. `name` is sanitized to one path component so a
    /// crafted offer can't escape the generation directory.
    ///
    /// - Throws: a filesystem error if the directory can't be created, or
    ///   `generation` was discarded.
    public func reserveDirectory(generation: UInt64, name: String) throws -> URL {
        try state.withLock { state in
            let dir = try state.directory(
                for: generation, root: root, processRoot: processRoot, retention: retention)
            let parent = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let url = parent.appendingPathComponent(
                NameUniquing.sanitizedComponent(name), isDirectory: true)
            try processRoot.createDirectory(at: url)
            return url
        }
    }

    /// Reserves a fresh empty directory under the generation directory for a
    /// caller that materializes files it does not name — a window drop whose
    /// promised files arrive with the source app's own names.
    ///
    /// - Throws: a filesystem error if the directory can't be created, or
    ///   `generation` was discarded.
    public func reserveScratchDirectory(generation: UInt64) throws -> URL {
        try state.withLock { state in
            let directory = try state.directory(
                for: generation, root: root, processRoot: processRoot, retention: retention)
            let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try processRoot.createDirectory(at: url)
            return url
        }
    }

    /// Removes this instance's entire staging root — every live generation at
    /// once.
    ///
    /// A previous instance's root is out of reach by construction;
    /// `reclaimSiblingRoots` reclaims those.
    public func sweep() {
        state.withLock { state in
            Self.discard(root)
            state.generationDirs.removeAll()
        }
    }

    /// Removes the directory for `generation`, once the caller knows nothing
    /// can still read from it.
    ///
    /// Under ``Retention/newest(_:)`` this retires a generation early, and one
    /// already evicted is a no-op; under ``Retention/untilDiscarded`` it is the
    /// only deletion, and the generation is never created again.
    public func discardGeneration(_ generation: UInt64) {
        state.withLock { state in
            if retention == .untilDiscarded { state.discarded.insert(generation) }
            guard let index = state.generationDirs.firstIndex(where: { $0.generation == generation })
            else { return }
            let dir = state.generationDirs.remove(at: index).dir
            Self.discard(dir)
        }
    }

    /// Removes every sibling root under this instance's label — staging left
    /// behind by the same label's earlier instances in this process — leaving
    /// this instance's own root untouched. Another process's staging is under
    /// another process root, out of reach.
    ///
    /// Call only when nothing can still be serving from those roots: for a
    /// receive root, once the host pasteboard no longer holds (or has just
    /// retracted) the write those files backed.
    public func reclaimSiblingRoots() {
        state.withLock { _ in
            let labelDir = root.deletingLastPathComponent()
            guard
                let siblings = try? FileManager.default.contentsOfDirectory(
                    at: labelDir, includingPropertiesForKeys: nil)
            else { return }
            for sibling in siblings where sibling.lastPathComponent != root.lastPathComponent {
                Self.discard(sibling)
            }
        }
    }

    // MARK: - Private

    /// Removes staged content outright, whatever its depth or modes.
    ///
    /// Nothing is left to notice the failure but the log: every caller is
    /// already giving the content up. What is already gone is not a failure.
    fileprivate static func discard(_ url: URL) {
        do {
            try StagedItemRemoval.remove(at: url)
        } catch Errno.noSuchFileOrDirectory {
            // Already gone.
        } catch {
            logger.log(
                .error,
                "Could not remove staged clipboard content: \(String(describing: error), privacy: .public)")
        }
    }

    /// Default free-space query: `volumeAvailableCapacityForImportantUsageKey`
    /// (Apple's documented key for user-initiated/important writes, vs. the
    /// opportunistic key for predictive downloads).
    private static let defaultFreeSpace: FreeSpaceProvider = { url in
        // The root and any of its parents may not exist yet; a volume query
        // needs a path that does.
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        guard
            let values = try? probe.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity
    }
}
