import Foundation

/// Materializes streamed file representations to real local temp files so a
/// receiver can put a concrete `public.file-url` on the pasteboard — the only
/// mechanism by which a Finder **Paste** creates a file (a pasteboard
/// `NSFilePromiseProvider` is a drag-session API and is not fulfilled by paste).
///
/// Bytes are appended through a `Sink` as chunks arrive off the wire — the whole
/// file is never resident in memory. A `Sink` is opened with `makeSink(...)`,
/// fed via `write(_:)`, and finalized with `commit()` (keep) or `abort()`
/// (delete the partial).
///
/// One *generation* directory per offer generation. To protect a large paste
/// still being copied out by Finder, the **last `maxGenerations` (3)** generation
/// directories are retained; a new generation evicts only the oldest beyond that
/// window. `sweep()` clears everything (crash orphans and all live generations).
///
/// `@unchecked Sendable` with an internal lock: a host window controller and a
/// guest agent each own one instance and call it from a single queue/actor, but
/// the lock makes concurrent use safe regardless.
public final class ClipboardFileStaging: @unchecked Sendable {
    /// Queries free capacity (in bytes) for important, user-initiated writes at
    /// the given directory.
    ///
    /// Injected so tests can simulate a full disk.
    public typealias FreeSpaceProvider = @Sendable (URL) -> Int64?

    /// Number of recent generation directories kept alive.
    ///
    /// A large paste copied
    /// out by Finder survives until this many newer generations exist, so a
    /// rapid sequence of copies can't delete a directory mid-copy.
    public static let maxGenerations = 3

    /// An open append-only sink for one streamed file representation.
    ///
    /// `@unchecked Sendable`: the receiver writes from one transfer queue at a
    /// time; the internal lock makes concurrent `write`/`commit`/`abort` safe.
    public final class Sink: @unchecked Sendable {
        /// The local file the bytes are being written to.
        public let url: URL

        private let handle: FileHandle
        private let lock = NSLock()
        private var finished = false

        init(url: URL, handle: FileHandle) {
            self.url = url
            self.handle = handle
        }

        /// Appends a chunk to the file.
        ///
        /// - Throws: any error from `FileHandle.write(contentsOf:)` (e.g. the
        ///   volume filling mid-stream). On a throw the caller aborts the
        ///   transfer, which calls `abort()` to delete the partial.
        public func write(_ data: Data) throws {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            try handle.write(contentsOf: data)
        }

        /// Closes the file and keeps it; the bytes are complete.
        ///
        /// Returns the final URL. Idempotent.
        ///
        /// - Throws: an error from `FileHandle.close()`. With `F_NOCACHE` and no
        ///   `fsync`, the kernel can defer a write failure (e.g. the volume
        ///   filling on the final extent) to `close()`; propagating it lets the
        ///   receiver fail the transfer rather than deliver a truncated file that
        ///   still passed the in-flight digest check. The partial is deleted on a
        ///   close failure. [L3]
        @discardableResult
        public func commit() throws -> URL {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return url }
            finished = true
            do {
                try handle.close()
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            return url
        }

        /// Closes the file and deletes the partial.
        ///
        /// Idempotent.
        public func abort() {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            try? handle.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private let root: URL
    private let freeSpaceProvider: FreeSpaceProvider
    private let lock = NSLock()

    /// Generation directories in arrival order (oldest first), each tagged with
    /// the offer generation it belongs to.
    ///
    /// Bounded to `maxGenerations`.
    private var generationDirs: [(generation: UInt64, dir: URL)] = []

    /// - Parameters:
    ///   - label: distinguishes co-resident roots (e.g. `"agent"` vs `"host"`);
    ///     the host app and guest agent run in different processes and
    ///     filesystems, but the label keeps multiple roots from colliding.
    ///   - tempRoot: parent directory for the staging root. Defaults to the
    ///     system temporary directory; injected in tests.
    ///   - freeSpaceProvider: queries available capacity; injected in tests to
    ///     simulate a full disk. Defaults to
    ///     `volumeAvailableCapacityForImportantUsageKey`.
    public init(
        label: String,
        tempRoot: URL = FileManager.default.temporaryDirectory,
        freeSpaceProvider: FreeSpaceProvider? = nil
    ) {
        root = tempRoot.appendingPathComponent(
            "KernovaClipboardStaging-\(label)", isDirectory: true)
        self.freeSpaceProvider = freeSpaceProvider ?? Self.defaultFreeSpace
    }

    /// Available capacity for important writes at the staging root's volume, in
    /// bytes, or `nil` if it can't be determined.
    public func availableCapacity() -> Int64? {
        freeSpaceProvider(root)
    }

    /// Whether `url` points inside this staging root.
    ///
    /// The outbound pasteboard poll uses this to skip a `public.file-url` that we
    /// materialized ourselves on a prior inbound paste, so a received file can
    /// never be offered back to the peer (echo suppression for file payloads).
    public func isInStagingRoot(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path)
    }

    /// Whether `byteCount` bytes (plus `margin`) fit on the staging volume.
    ///
    /// `RATIONALE:` `volumeAvailableCapacityForImportantUsageKey` **includes
    /// purgeable space**, so it can exceed raw free bytes (WWDC17 "What's New in
    /// Foundation"); the margin keeps a transfer from filling the volume to the
    /// last byte. An unknown capacity is treated as "fits" — we don't block a
    /// transfer on a failed query.
    public func hasCapacity(
        forByteCount byteCount: Int, margin: Int = ClipboardStreamTuning.freeSpaceMargin
    ) -> Bool {
        guard let available = availableCapacity() else { return true }
        return Int64(byteCount) + Int64(margin) <= available
    }

    /// Opens an append-only sink for a streamed file representation, creating
    /// (or reusing) the directory for `generation` and evicting generations
    /// older than the `maxGenerations` window.
    ///
    /// - Throws: a filesystem error if the directory or file can't be created.
    public func makeSink(generation: UInt64, filename: String) throws -> Sink {
        lock.lock()
        defer { lock.unlock() }

        let dir = try directory(for: generation)
        // Uniquify within the generation so two same-named payloads in one copy
        // don't collapse onto one path. createFile below claims the name, so a
        // later sink/adopt in this generation sees it taken.
        let url = Self.uniqueDestination(in: dir, filename: filename)
        // Create an empty file, then open it for writing. `F_NOCACHE` keeps a
        // multi-GB transfer from evicting the page cache (the DTS-preferred
        // behaviour for streaming large files).
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        return Sink(url: url, handle: handle)
    }

    /// Reserves an empty child directory named exactly `name` under the
    /// generation directory, for the receiver to extract a directory tree into.
    ///
    /// `makeSink`/`adopt` are per-file (a `Sink` appends bytes, `adopt`
    /// hardlinks a single file); neither materializes a tree. This creates an
    /// empty directory for `ClipboardDirectoryArchive.extract(...)` to populate.
    /// The directory is nested under a fresh UUID parent so it keeps the *exact*
    /// folder name — a sibling staged `.aar` of the same name (the streamed
    /// archive lands beside it) can't force a Finder-style ` (n)` suffix, which
    /// would rename the pasted folder. `name` is sanitized to a single path
    /// component so a crafted offer can't escape the generation dir (defense in
    /// depth alongside AppleArchive's own confinement). The extracted tree rides
    /// generation rotation + the teardown sweep, and `isInStagingRoot` (a prefix
    /// check) echo-suppresses it.
    ///
    /// - Throws: a filesystem error if the directory can't be created.
    public func reserveDirectory(generation: UInt64, name: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let dir = try directory(for: generation)
        let parent = dir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = parent.appendingPathComponent(Self.sanitize(name), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Reserves a unique destination URL under the generation directory for the
    /// sender's directory archive before it is offered.
    ///
    /// Unlike `makeSink`, no `Sink` is returned: the caller writes the bytes
    /// itself (AppleArchive opens its own stream at the returned URL). An empty
    /// placeholder claims the name so a later reserve/sink/adopt in the same
    /// generation can't collide on it, and the file rides generation rotation +
    /// the teardown sweep.
    ///
    /// - Throws: a filesystem error if the directory can't be created.
    public func reserveURL(generation: UInt64, filename: String) throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        let dir = try directory(for: generation)
        let url = Self.uniqueDestination(in: dir, filename: filename)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    /// Removes the entire staging root — crash orphans and all live generations.
    ///
    /// Call on agent start/stop and capability disable.
    public func sweep() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: root)
        generationDirs.removeAll()
    }

    // MARK: - Private

    /// Returns the directory for `generation`, creating it on first use and
    /// evicting the oldest directories beyond `maxGenerations`.
    ///
    /// Caller holds the
    /// lock.
    private func directory(for generation: UInt64) throws -> URL {
        if let existing = generationDirs.first(where: { $0.generation == generation }) {
            return existing.dir
        }
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        generationDirs.append((generation: generation, dir: dir))
        while generationDirs.count > Self.maxGenerations {
            let oldest = generationDirs.removeFirst()
            try? FileManager.default.removeItem(at: oldest.dir)
        }
        return dir
    }

    /// A destination URL under `dir` named `filename` (sanitized), uniquified
    /// with a ` (n)` suffix before the extension when that name is already
    /// taken.
    ///
    /// A single multi-file copy can carry two payloads that share a name (a
    /// crafted offer, or files gathered from different folders); without this
    /// the second `makeSink`/`adopt` in the generation would reuse the first's
    /// path and the two files would collapse into one. Finder applies the same
    /// ` (n)` disambiguation when pasting. Caller holds the lock.
    private static func uniqueDestination(in dir: URL, filename: String) -> URL {
        let sanitized = sanitize(filename)
        let candidate = dir.appendingPathComponent(sanitized)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let name = sanitized as NSString
        let base = name.deletingPathExtension
        let ext = name.pathExtension
        var counter = 2
        while true {
            let suffixed = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            let url = dir.appendingPathComponent(suffixed)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            counter += 1
        }
    }

    /// Reduces a suggested filename to a single safe path component so a
    /// crafted name (`"../escape"`, `"a/b"`) can't write outside the
    /// generation directory.
    private static func sanitize(_ filename: String) -> String {
        let base = (filename as NSString).lastPathComponent
        let cleaned = base.replacingOccurrences(of: "/", with: "_")
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "clipboard-file" : cleaned
    }

    /// Default free-space query: `volumeAvailableCapacityForImportantUsageKey`
    /// (Apple's documented key for user-initiated/important writes, vs. the
    /// opportunistic key for predictive downloads).
    ///
    /// Falls back to the
    /// parent-of-root volume when the root doesn't exist yet.
    private static let defaultFreeSpace: FreeSpaceProvider = { url in
        // The root may not exist yet; query its parent, which does.
        let probe = FileManager.default.fileExists(atPath: url.path) ? url : url.deletingLastPathComponent()
        guard
            let values = try? probe.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey
            ]),
            let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return capacity
    }
}
