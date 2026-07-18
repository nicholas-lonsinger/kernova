import Foundation

// Shared item-identity + offer-manifest machinery for the guest File Provider
// transport (issue #376).
//
// The File Provider extension owns the enumerator, but the agent (a separate
// process) knows the current clipboard offer. The framework has no "push items"
// API — the system learns items *only* by calling the extension's enumerator —
// so the two processes agree on the current item set through a small manifest
// the agent writes into the shared app-group container and the extension reads.
// After writing it the agent calls `signalEnumerator` to prompt re-enumeration.
//
// All types here are value types or stateless file helpers: synchronization
// across the two processes is the atomic manifest write, not shared memory, so
// none of this needs lock-based `@unchecked Sendable`.

/// Encodes and decodes a file representation's `(sessionSalt, generation,
/// repIndex)` as a `NSFileProviderItemIdentifier` string.
///
/// The string is carried as a plain `String` here (not `NSFileProviderItemIdentifier`)
/// so the encoding is unit-testable without importing `FileProvider`; the
/// extension wraps it. The `clipfile` prefix distinguishes a per-rep file item
/// from the framework's reserved container identifiers (root / working-set /
/// trash). Avoids `/` and `:`, which the framework reserves.
///
/// The identifier leads with a per-owner-session salt because the offer
/// `generation` counter restarts at 1 with every owner session, while
/// placeholder dirents survive teardown on disk (#541). Without the salt, a
/// new session's first offer reuses the previous session's item identifier and
/// fileproviderd treats it as an in-place *update* of the stale — possibly
/// already materialized — placeholder: it renames the old file, keeps its
/// bytes and size, and decides `shouldFetch:false`, so a paste serves the
/// previous offer's content. A salted identifier makes a new session's offer a
/// *different item*, so reconciliation deletes the stale placeholder and
/// creates a fresh dataless one with the correct metadata.
enum FileProviderItemIdentifier {
    private static let prefix = "clipfile"
    /// Prefix for a **tree node** of a directory rep's placeholder tree (folder
    /// D1b): the folder root and every descendant.
    ///
    /// Distinct from `clipfile` so a
    /// flat single-file rep and a folder tree never collide, and so the
    /// extension routes `fetchContents` to the flat vs. child pull path by the
    /// prefix alone.
    private static let nodePrefix = "clipnode"
    private static let separator: Character = "."

    /// Encodes `(sessionSalt, generation, repIndex)` into an item identifier
    /// string.
    static func make(sessionSalt: UInt64, generation: UInt64, repIndex: Int) -> String {
        "\(prefix)\(separator)\(sessionSalt)\(separator)\(generation)\(separator)\(repIndex)"
    }

    /// Decodes a flat single-file identifier back to `(sessionSalt, generation,
    /// repIndex)`, or `nil` when it isn't one this provider minted.
    static func decode(
        _ identifier: String
    ) -> (sessionSalt: UInt64, generation: UInt64, repIndex: Int)? {
        let parts = identifier.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == prefix,
            let sessionSalt = UInt64(parts[1]),
            let generation = UInt64(parts[2]),
            let repIndex = Int(parts[3]), repIndex >= 0
        else { return nil }
        return (sessionSalt, generation, repIndex)
    }

    /// Encodes a directory-rep **tree node** identifier — `(sessionSalt,
    /// generation, repIndex, childSeq)`, with `childSeq == 0` naming the folder
    /// root and `>= 1` a descendant.
    static func makeNode(
        sessionSalt: UInt64, generation: UInt64, repIndex: Int, childSeq: UInt32
    ) -> String {
        "\(nodePrefix)\(separator)\(sessionSalt)\(separator)\(generation)\(separator)\(repIndex)\(separator)\(childSeq)"
    }

    /// Decodes a tree-node identifier back to `(sessionSalt, generation,
    /// repIndex, childSeq)`, or `nil` when it isn't one this provider minted.
    static func decodeNode(
        _ identifier: String
    ) -> (sessionSalt: UInt64, generation: UInt64, repIndex: Int, childSeq: UInt32)? {
        let parts = identifier.split(separator: separator, omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == nodePrefix,
            let sessionSalt = UInt64(parts[1]),
            let generation = UInt64(parts[2]),
            let repIndex = Int(parts[3]), repIndex >= 0,
            let childSeq = UInt32(parts[4])
        else { return nil }
        return (sessionSalt, generation, repIndex, childSeq)
    }
}

/// The current offer's file items, written by the agent and read by the
/// extension's enumerator.
///
/// One entry per File-Provider-served file rep.
public struct FileProviderManifest: Codable, Sendable, Equatable {
    /// One enumerable file item: its `(sessionSalt, generation, repIndex)`
    /// identity plus the metadata the enumerator needs to build a dataless
    /// `NSFileProviderItem`.
    public struct Item: Codable, Sendable, Equatable {
        /// The publishing owner session's salt — makes the item identifier
        /// unique across sessions whose `generation` counters restart (#541);
        /// see `FileProviderItemIdentifier`.
        public var sessionSalt: UInt64
        /// Offer generation this item belongs to.
        public var generation: UInt64
        /// Index of the file representation within the offer.
        public var repIndex: Int
        /// Suggested filename — the placeholder's name under the domain root.
        public var filename: String
        /// Total byte count, surfaced as the item's `documentSize`.
        public var byteCount: UInt64
        /// Content UTI, mapped to the item's `contentType`.
        public var uti: String

        /// Creates a manifest item from a file rep's identity and metadata.
        public init(
            sessionSalt: UInt64, generation: UInt64, repIndex: Int, filename: String,
            byteCount: UInt64, uti: String
        ) {
            self.sessionSalt = sessionSalt
            self.generation = generation
            self.repIndex = repIndex
            self.filename = filename
            self.byteCount = byteCount
            self.uti = uti
        }

        /// The File Provider item identifier string for this entry.
        public var itemIdentifier: String {
            FileProviderItemIdentifier.make(
                sessionSalt: sessionSalt, generation: generation, repIndex: repIndex)
        }
    }

    /// A directory representation published as a placeholder **tree** (folder
    /// D1b, `clipboard.dirtree.v1`): a folder root plus every descendant node.
    ///
    /// The enumerator serves the root under the domain root and each folder's
    /// direct children under it; a file node's bytes are pulled by a child
    /// `ClipboardTreeFetch` on `fetchContents`.
    public struct FolderRep: Codable, Sendable, Equatable {
        /// The publishing owner session's salt (#541), shared by the root and
        /// every node's identifier.
        public var sessionSalt: UInt64
        /// Offer generation this folder belongs to.
        public var generation: UInt64
        /// Index of the directory representation within the offer.
        public var repIndex: Int
        /// Folder name — the root placeholder's name under the domain root.
        public var filename: String
        /// Folder/package content UTI, mapped to the root item's `contentType`
        /// (a package UTI so a pasted bundle opens as a package).
        public var uti: String
        /// Whether the root folder is an OS package (.app/.rtfd).
        public var isPackage: Bool
        /// Stat-walk size estimate, surfaced as the root's `documentSize`
        /// (advisory — see the proto's `byte_count` doc).
        public var byteCount: UInt64
        /// Root folder modification time (ms since epoch), for fidelity.
        public var mtimeMs: Int64
        /// Every descendant node (`childSeq >= 1`); the folder root is `childSeq
        /// 0`, represented by this `FolderRep` itself.
        public var nodes: [Node]

        /// One node of a directory rep's tree — a file, subdirectory, or symlink.
        public struct Node: Codable, Sendable, Equatable {
            /// Node kind.
            ///
            /// Raw `Int` for a compact, stable Codable encoding.
            public enum Kind: Int, Codable, Sendable {
                case file = 0
                case directory = 1
                case symlink = 2
            }

            /// Stable per-tree sequence (1-based); its `transfer_id`/identifier key.
            public var childSeq: UInt32
            /// `childSeq` of the parent node, or `0` for a direct child of the
            /// folder root (no descendant is `childSeq 0`, which is the root).
            public var parentChildSeq: UInt32
            /// Whether this node is a file, subdirectory, or symlink.
            public var kind: Kind
            /// Last path component — the placeholder's display name.
            public var filename: String
            /// POSIX path relative to the folder root ("sub/file.txt"), the
            /// child fetch's addressing.
            public var relativePath: String
            /// File size (0 for a directory/symlink), the item's `documentSize`.
            public var byteCount: UInt64
            /// Content UTI (a file's type; a package UTI for a package subdir).
            public var uti: String
            /// Whether a directory node is an OS package.
            public var isPackage: Bool
            /// Raw symlink target for a symlink node; empty otherwise.
            public var symlinkTarget: String
            /// POSIX permission bits (`st_mode & 0o7777`) for the executable bit
            /// and friends; 0 when unknown.
            public var posixPermissions: UInt32
            /// Modification time (ms since epoch), for fidelity.
            public var mtimeMs: Int64

            /// Creates a tree node.
            public init(
                childSeq: UInt32, parentChildSeq: UInt32, kind: Kind, filename: String,
                relativePath: String, byteCount: UInt64, uti: String, isPackage: Bool = false,
                symlinkTarget: String = "", posixPermissions: UInt32 = 0, mtimeMs: Int64 = 0
            ) {
                self.childSeq = childSeq
                self.parentChildSeq = parentChildSeq
                self.kind = kind
                self.filename = filename
                self.relativePath = relativePath
                self.byteCount = byteCount
                self.uti = uti
                self.isPackage = isPackage
                self.symlinkTarget = symlinkTarget
                self.posixPermissions = posixPermissions
                self.mtimeMs = mtimeMs
            }
        }

        /// Creates a folder rep.
        public init(
            sessionSalt: UInt64, generation: UInt64, repIndex: Int, filename: String, uti: String,
            isPackage: Bool = false, byteCount: UInt64 = 0, mtimeMs: Int64 = 0, nodes: [Node]
        ) {
            self.sessionSalt = sessionSalt
            self.generation = generation
            self.repIndex = repIndex
            self.filename = filename
            self.uti = uti
            self.isPackage = isPackage
            self.byteCount = byteCount
            self.mtimeMs = mtimeMs
            self.nodes = nodes
        }

        /// The folder root's File Provider item identifier (`childSeq 0`).
        public var rootIdentifier: String {
            FileProviderItemIdentifier.makeNode(
                sessionSalt: sessionSalt, generation: generation, repIndex: repIndex, childSeq: 0)
        }

        /// A descendant node's item identifier.
        public func identifier(for node: Node) -> String {
            FileProviderItemIdentifier.makeNode(
                sessionSalt: sessionSalt, generation: generation, repIndex: repIndex,
                childSeq: node.childSeq)
        }
    }

    /// A manifest identifier resolved to what it names in the current offer.
    public enum Resolved: Equatable {
        /// A flat single-file rep.
        case flatFile(Item)
        /// A directory rep's root folder.
        case folderRoot(FolderRep)
        /// A node within a directory rep's tree.
        case node(FolderRep, FolderRep.Node)
    }

    /// The offer generation this manifest describes; `0` means no current offer.
    public var generation: UInt64
    /// One entry per flat (single-file) File-Provider-served file rep.
    public var items: [Item]
    /// One entry per directory rep published as a placeholder tree.
    public var folders: [FolderRep]

    /// Creates a manifest for an offer generation and its file items and folders.
    public init(generation: UInt64, items: [Item], folders: [FolderRep] = []) {
        self.generation = generation
        self.items = items
        self.folders = folders
    }

    /// No current offer — an empty working set.
    public static let empty = FileProviderManifest(generation: 0, items: [], folders: [])

    /// The flat single-file item matching an identifier, or `nil`.
    ///
    /// Kept for the flat single-file path; folder-tree callers use `resolve(_:)`.
    public func item(for identifier: String) -> Item? {
        guard let decoded = FileProviderItemIdentifier.decode(identifier) else { return nil }
        return items.first {
            $0.sessionSalt == decoded.sessionSalt && $0.generation == decoded.generation
                && $0.repIndex == decoded.repIndex
        }
    }

    /// Resolves any manifest identifier to what it names — a flat file, a folder
    /// root, or a tree node — or `nil` for a stale/unknown identifier (a
    /// superseded generation, a previous session (#541), or not one of ours).
    public func resolve(_ identifier: String) -> Resolved? {
        if let item = item(for: identifier) { return .flatFile(item) }
        guard let decoded = FileProviderItemIdentifier.decodeNode(identifier),
            let folder = folders.first(where: {
                $0.sessionSalt == decoded.sessionSalt && $0.generation == decoded.generation
                    && $0.repIndex == decoded.repIndex
            })
        else { return nil }
        if decoded.childSeq == 0 { return .folderRoot(folder) }
        guard let node = folder.nodes.first(where: { $0.childSeq == decoded.childSeq }) else {
            return nil
        }
        return .node(folder, node)
    }

    /// Root-level items: flat single files plus each directory rep's folder root.
    public func rootEntries() -> (files: [Item], folderRoots: [FolderRep]) {
        (items, folders)
    }

    /// The direct children of a container identifier — a folder root or a
    /// directory node — as `(FolderRep, Node)` pairs, or `nil` when `identifier`
    /// isn't a directory container in the current offer.
    public func children(ofContainer identifier: String) -> [(FolderRep, FolderRep.Node)]? {
        switch resolve(identifier) {
        case .folderRoot(let folder):
            return folder.nodes.filter { $0.parentChildSeq == 0 }.map { (folder, $0) }
        case .node(let folder, let node) where node.kind == .directory:
            return folder.nodes.filter { $0.parentChildSeq == node.childSeq }.map { (folder, $0) }
        default:
            return nil
        }
    }
}

/// Failure reaching the shared app-group container.
enum FileProviderContainerError: Error {
    /// The app-group container couldn't be resolved (e.g. the entitlement is
    /// absent, as in a CI test host).
    case containerUnavailable
}

/// Locates the shared app-group container and reads/writes the offer manifest
/// for one direction's config.
///
/// `containerURL(forSecurityApplicationGroupIdentifier:)` may return a URL whose
/// directory isn't actually accessible (per Apple's docs), so writes are
/// fallible and reads degrade to `.empty`. Direction-bound: the app group and
/// the subdirectory come from the `FileProviderConfig` it's built with,
/// so the guest and host containers never collide on a shared dev Mac.
public struct FileProviderContainer: Sendable {
    private static let stagingDirectoryName = "staging"
    private static let manifestFilename = "clipboard-manifest.json"

    private let appGroupIdentifier: String
    private let directoryName: String

    /// Builds a container for one direction.
    public init(config: FileProviderConfig) {
        self.appGroupIdentifier = config.appGroupIdentifier
        self.directoryName = config.containerDirectoryName
    }

    /// The shared app-group container directory, or `nil` if unavailable.
    public func containerURL() -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private func fileProviderDirectoryURL() -> URL? {
        containerURL()?.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Root for inbound File-Provider staging, inside the shared container so the
    /// sandboxed extension can read the staged bytes. `nil` when the container is
    /// unavailable.
    public func stagingRootURL() -> URL? {
        fileProviderDirectoryURL()?.appendingPathComponent(
            Self.stagingDirectoryName, isDirectory: true)
    }

    private func manifestURL() -> URL? {
        fileProviderDirectoryURL()?.appendingPathComponent(
            Self.manifestFilename, isDirectory: false)
    }

    /// Atomically writes the current offer manifest (container-app side).
    public func writeManifest(_ manifest: FileProviderManifest) throws {
        guard let url = manifestURL() else {
            throw FileProviderContainerError.containerUnavailable
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    /// Reads the current offer manifest (extension side); `.empty` when none is
    /// present or it can't be decoded.
    public func readManifest() -> FileProviderManifest {
        guard let url = manifestURL(), let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(FileProviderManifest.self, from: data)
        else { return .empty }
        return manifest
    }
}
