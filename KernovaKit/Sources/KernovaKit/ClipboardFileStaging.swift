import Foundation

/// An append-only sink for one streamed file representation: bytes are fed with
/// `write(_:)` and finalized with `commit()` (keep) or `abort()` (delete the
/// partial).
public protocol StagingSink: Sendable {
    /// Appends a chunk to the file.
    func write(_ data: Data) throws

    /// Closes the file and keeps it; returns the final URL. Idempotent.
    @discardableResult
    func commit() throws -> URL

    /// Closes the file and deletes the partial. Idempotent.
    func abort()
}

/// Materializes streamed file representations to real local temp files so a
/// receiver can put a concrete `public.file-url` on the pasteboard — the only
/// mechanism by which a Finder **Paste** creates a file (a pasteboard
/// `NSFilePromiseProvider` is a drag-session API and is not fulfilled by paste).
///
/// One directory per offer generation; the last `maxGenerations` are retained so
/// a paste still being copied out by Finder survives, and `sweep()` clears
/// everything.
public final class ClipboardFileStaging: @unchecked Sendable {
    /// Queries free capacity (in bytes) for important, user-initiated writes at
    /// the given directory.
    public typealias FreeSpaceProvider = @Sendable (URL) -> Int64?

    /// Number of recent generation directories kept alive.
    public static let maxGenerations = 3

    /// An open append-only sink for one streamed file representation.
    ///
    /// `@unchecked Sendable`: an internal lock makes concurrent
    /// `write`/`commit`/`abort` safe.
    public final class Sink: StagingSink, @unchecked Sendable {
        /// The local file the bytes are being written to.
        let url: URL

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
        ///   volume filling mid-stream).
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
        ///   `fsync` the kernel can defer a write failure to `close()`, so
        ///   swallowing it delivers a truncated file that still passed the
        ///   in-flight digest check. The partial is deleted on a close failure.
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

    /// Generation directories in arrival order (oldest first), bounded to
    /// `maxGenerations`.
    private var generationDirs: [(generation: UInt64, dir: URL)] = []

    /// Directory under `tempRoot` that every staging root nests in, so a launch
    /// reclaim (`reclaimAll`) sweeps all co-resident label families at once.
    public static let parentDirectoryName = "KernovaClipboardStaging"

    /// - Parameters:
    ///   - label: distinguishes co-resident roots (e.g. `"agent"` vs `"host"`).
    ///   - tempRoot: parent directory for the shared staging parent.
    ///   - freeSpaceProvider: queries available capacity; defaults to
    ///     `volumeAvailableCapacityForImportantUsageKey`.
    public init(
        label: String,
        tempRoot: URL = FileManager.default.temporaryDirectory,
        freeSpaceProvider: FreeSpaceProvider? = nil
    ) {
        root =
            tempRoot
            .appendingPathComponent(Self.parentDirectoryName, isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
        self.freeSpaceProvider = freeSpaceProvider ?? Self.defaultFreeSpace
    }

    /// Removes the shared staging parent under `tempRoot` — every label
    /// family's root, crash orphans included.
    ///
    /// Call once at process launch, before any staging root is used; a live
    /// instance's `sweep()` still clears only its own root.
    public static func reclaimAll(tempRoot: URL = FileManager.default.temporaryDirectory) {
        try? FileManager.default.removeItem(
            at: tempRoot.appendingPathComponent(parentDirectoryName, isDirectory: true))
    }

    /// Available capacity for important writes at the staging root's volume, in
    /// bytes, or `nil` if it can't be determined.
    public func availableCapacity() -> Int64? {
        freeSpaceProvider(root)
    }

    /// Whether `url` points inside this staging root.
    ///
    /// The outbound pasteboard poll skips these so a file received from the peer
    /// is never offered back to it. The prefix is component-bounded so a sibling
    /// root whose label extends this one (`agent` vs `agent-send`) never matches.
    public func isInStagingRoot(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// Whether `byteCount` bytes (plus `margin`) fit on the staging volume.
    ///
    /// `volumeAvailableCapacityForImportantUsageKey` **includes purgeable
    /// space**, so it can exceed raw free bytes (WWDC17 "What's New in
    /// Foundation"); the margin keeps a transfer from filling the volume to the
    /// last byte. An unknown capacity is treated as "fits".
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
        let url = Self.uniqueDestination(in: dir, filename: filename)
        // `F_NOCACHE` keeps a multi-GB transfer from evicting the page cache —
        // the DTS-preferred behavior for streaming large files.
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        return Sink(url: url, handle: handle)
    }

    /// Reserves an empty child directory named exactly `name` under the
    /// generation directory, for the receiver to extract a directory tree into.
    ///
    /// Nested under a fresh UUID parent so the folder keeps its *exact* name: a
    /// sibling staged `.aar` of the same name would otherwise force a
    /// Finder-style ` (n)` suffix onto it. `name` is sanitized to one path
    /// component so a crafted offer can't escape the generation directory.
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
    /// itself. An empty placeholder claims the name so a later
    /// reserve/sink/adopt in the same generation can't collide on it.
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
    /// Caller holds the lock.
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
    /// One multi-file copy can carry two payloads that share a name; without
    /// this the second sink in the generation reuses the first's path and the
    /// two files collapse into one. Caller holds the lock.
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
