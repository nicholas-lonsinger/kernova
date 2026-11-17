import Foundation
import KernovaSynchronization

/// The local temp directories streamed file representations land in, so a
/// receiver can put a concrete `public.file-url` on the pasteboard — the only
/// mechanism by which a Finder **Paste** creates a file. Verified 2026-08-15
/// (macOS 26): an `NSFilePromiseProvider` written to `NSPasteboard.general`
/// advertises its promise types, but ⌘V in Finder creates nothing and TextEdit
/// pastes nothing, and neither calls the provider's delegate; a `public.file-url`
/// on the same pasteboard pastes in both.
///
/// One directory per offer generation, kept for as long as its ``Retention``
/// says. Every removal goes through the process root
/// (``ProcessStagingRoot/remove(_:)``), so a pasteboard item naming a file in it
/// goes first.
///
/// Each instance owns a private root (the label plus a per-instance component)
/// under its process's ``ProcessStagingRoot``. What retention keeps of it stays
/// for as long as the process runs, and goes with the whole process root at the
/// next launch's ``ProcessStagingRoot/reclaimAbandonedRoots()``.
public final class ClipboardFileStaging: Sendable {
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

    private let processRoot: ProcessStagingRoot
    private let root: URL
    private let retention: Retention

    /// The lock also serializes every filesystem change under ``root``, so the
    /// I/O each method does stays inside its `withLock`.
    private struct State: Sendable {
        /// Generation directories in arrival order (oldest first).
        var generationDirs: [GenerationDir] = []

        /// The generations ``Retention/untilDiscarded`` has discarded.
        var discarded: Set<UInt64> = []

        /// The generation the next ``ClipboardFileStaging/lease()`` holds.
        var nextLease: UInt64 = 1

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
                    processRoot.remove(generationDirs.removeFirst().dir)
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
    /// agent's alike, whose removals first withdraw every item of the general
    /// pasteboard naming a file in what goes (``ClipboardStagingRetirement``).
    public static let processRoot = ProcessStagingRoot(
        parent: FileManager.default.temporaryDirectory.appendingPathComponent(
            "KernovaClipboardStaging", isDirectory: true),
        retirement: ClipboardStagingRetirement())

    /// Staging that keeps the newest ``maxGenerations`` generations.
    ///
    /// - Parameters:
    ///   - label: distinguishes co-resident roots (e.g. `"agent"` vs `"host"`).
    ///     The root nests a unique per-instance component under the label, so two
    ///     same-label instances never share a root.
    ///   - root: the process root the label nests under — ``processRoot`` in
    ///     production.
    public convenience init(label: String, root: ProcessStagingRoot) {
        self.init(label: label, root: root, retention: .newest(Self.maxGenerations))
    }

    /// Staging whose every generation is a ``lease()``'s, deleted once its last holder lets it go and by
    /// nothing else. Parameters as ``init(label:root:)``.
    public static func leased(label: String, root: ProcessStagingRoot) -> ClipboardFileStaging {
        ClipboardFileStaging(label: label, root: root, retention: .untilDiscarded)
    }

    init(label: String, root: ProcessStagingRoot, retention: Retention) {
        processRoot = root
        self.retention = retention
        self.root =
            root.url
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    /// Whether `url` lies in `generation`'s directory.
    func isURL(_ url: URL, inGeneration generation: UInt64) -> Bool {
        state.withLock { state in
            state.generationDirs.first { $0.generation == generation }.map { Self.isURL(url, inside: $0.dir) } ?? false
        }
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

    /// A generation of its own, deleted once the lease is let go: staging owned by whatever holds the lease.
    /// Only ``leased(label:root:)`` staging gives one.
    public func lease() -> ClipboardStagingLease {
        assert(retention == .untilDiscarded, "a lease of staging that deletes generations by retention")
        let generation = state.withLock { state in
            defer { state.nextLease += 1 }
            return state.nextLease
        }
        return ClipboardStagingLease(staging: self, generation: generation)
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
            processRoot.remove(state.generationDirs.remove(at: index).dir)
        }
    }
}

/// One generation of ``ClipboardFileStaging/leased(label:root:)`` staging, which lives as long as this lease:
/// its directory is deleted when the last holder lets the lease go.
public final class ClipboardStagingLease: Sendable {
    private let staging: ClipboardFileStaging
    private let generation: UInt64

    init(staging: ClipboardFileStaging, generation: UInt64) {
        self.staging = staging
        self.generation = generation
    }

    /// A fresh empty directory in the lease's generation, for a caller that materializes files it does not
    /// name.
    public func reserveScratchDirectory() throws -> URL {
        try staging.reserveScratchDirectory(generation: generation)
    }

    /// Whether `url` lies in this lease's generation.
    public func holds(_ url: URL) -> Bool {
        staging.isURL(url, inGeneration: generation)
    }

    deinit {
        staging.discardGeneration(generation)
    }
}
