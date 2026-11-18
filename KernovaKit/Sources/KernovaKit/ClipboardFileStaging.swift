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
/// One directory per offer generation; the newest ``maxGenerations`` are kept,
/// so a pasteboard URL a newer offer replaced survives while Finder copies it
/// out, and the generation past them deletes the oldest, retracting nothing
/// from the pasteboard. An eviction deletes no file a write of this side names,
/// or an offer can still serve: a far-side offer's pulls land in its own
/// generation only while this side's write of it stands, and every later
/// offer's write replaces what an earlier one left, a pasted file kept
/// included; this side's own offer calls its promises in to a generation of
/// its own, which only the far side's pulls of that offer read, and only while
/// it is this side's one open offer.
///
/// Each instance owns a private root (the label plus a per-instance component)
/// under its process's ``ProcessStagingRoot``. What it keeps stays for as long
/// as the process runs, and goes with the whole process root at the next
/// launch's ``ProcessStagingRoot/reclaimAbandonedRoots()``.
public final class ClipboardFileStaging: Sendable {
    /// Number of recent generation directories kept alive.
    public static let maxGenerations = 3

    private let processRoot: ProcessStagingRoot
    private let root: URL

    /// The lock also serializes every filesystem change under ``root``, so the
    /// I/O each method does stays inside its `withLock`.
    private struct State: Sendable {
        /// Generation directories in arrival order (oldest first).
        var generationDirs: [GenerationDir] = []

        /// Returns the directory for `generation` under `root`, creating it on
        /// first use and evicting the oldest past ``maxGenerations``.
        ///
        /// - Throws: a filesystem error if the directory can't be created.
        mutating func directory(for generation: UInt64, root: URL, processRoot: ProcessStagingRoot) throws -> URL {
            if let existing = generationDirs.first(where: { $0.generation == generation }) {
                return existing.dir
            }
            let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try processRoot.createDirectory(at: dir)
            generationDirs.append(GenerationDir(generation: generation, dir: dir))
            while generationDirs.count > ClipboardFileStaging.maxGenerations {
                ProcessStagingRoot.discard(generationDirs.removeFirst().dir)
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
    /// agent's alike, whose process end and next launch withdraw every item of
    /// the general pasteboard naming a file in what they leave or remove
    /// (``ClipboardStagingRetirement``).
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
    public init(label: String, root: ProcessStagingRoot) {
        processRoot = root
        self.root =
            root.url
            .appendingPathComponent(label, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
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
    /// - Throws: a filesystem error if the directory can't be created.
    public func reserveScratchDirectory(generation: UInt64) throws -> URL {
        try state.withLock { state in
            let directory = try state.directory(for: generation, root: root, processRoot: processRoot)
            let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try processRoot.createDirectory(at: url)
            return url
        }
    }
}
