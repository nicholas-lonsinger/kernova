import Foundation
import SwiftProtobuf
import UniformTypeIdentifiers

/// In-process directory-tree walking and serialization for the folder
/// placeholder-tree transport (`clipboard.dirtree.v1`, #422/#376).
///
/// Where `ClipboardDirectoryArchive` packs a whole folder into one AppleArchive,
/// this walks the source tree lazily and emits **metadata only**: the producer
/// serves a listing on demand (`ClipboardTreeListing`) and each child file
/// individually, so no archive is built at copy time and Kernova's marginal disk
/// stays ≈ 0 (CLIPBOARD.md §2/§3). Fidelity (§6) — kind, size, POSIX
/// permissions, mtime, symlink targets, and package-ness — rides the listing so
/// the consumer's File Provider placeholders reconstruct the tree.
///
/// All helpers are pure/stateless (no logging — callers log at their own
/// subsystem, matching the other `KernovaKit` stream/staging types) and
/// sandbox-safe (in-process `FileManager`, never shelling out — §11). Symlinks
/// are recorded, not followed; child resolution is confined beneath the source
/// root so a crafted `relative_path` can't escape it.
public enum ClipboardDirectoryTree {
    /// UTI for a plain folder — equals `UTType.folder.identifier`, kept as a
    /// literal so the package needn't import `UniformTypeIdentifiers`.
    public static let folderUTI = ClipboardDirectoryArchive.directoryUTI

    /// UTI for a streamed tree-listing payload — an inline transfer whose bytes
    /// deserialize to a `ClipboardTreeListing`, never something the pasteboard
    /// sees.
    ///
    /// Shared by both directions' producer.
    public static let treeListingUTI = "app.kernova.clipboard.tree-listing"

    /// Upper bound on how many entries a walk visits before stopping, so a
    /// pathological tree (or a symlink cycle reached via the estimate's
    /// following enumerator) can't spin unbounded.
    ///
    /// Comfortably past the design
    /// target of a 100k-entry tree.
    public static let entryCap = 500_000

    // MARK: - Listing

    /// Walks the tree at `root` (depth-first, names sorted for determinism) into
    /// a flat list of `ClipboardTreeEntry`, assigning each node a 1-based
    /// `child_seq`.
    ///
    /// Symlinks are recorded (kind `.symlink`, with their raw
    /// target) and never traversed; directories — including OS packages, which
    /// are flagged so the pasted folder opens as a bundle — are recorded and
    /// recursed into. Stops at `entryCap` nodes.
    ///
    /// - Throws: any error `FileManager.contentsOfDirectory` raises on `root`
    ///   itself (a caller maps that to a failed listing); per-child stat failures
    ///   are tolerated (the child is recorded with best-effort metadata).
    public static func enumerateTree(at root: URL) throws -> [Kernova_V1_ClipboardTreeEntry] {
        var entries: [Kernova_V1_ClipboardTreeEntry] = []
        var seq: UInt32 = 0
        try recurse(root, prefix: "", into: &entries, seq: &seq)
        return entries
    }

    private static func recurse(
        _ dir: URL, prefix: String, into entries: inout [Kernova_V1_ClipboardTreeEntry],
        seq: inout UInt32
    ) throws {
        let children = try FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [
                .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isPackageKey,
            ],
            options: [])
        // Deterministic order so the same tree produces the same listing/child
        // sequence on every walk (the listing and each later child fetch must
        // agree on `child_seq`).
        let sorted = children.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in sorted {
            guard entries.count < entryCap else { return }
            let name = child.lastPathComponent
            let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
            let values = try? child.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isPackageKey,
            ])
            // `attributesOfItem` uses lstat semantics (the link's own attrs), so
            // a symlink's mtime/permissions are its own, not its target's.
            let attrs = try? FileManager.default.attributesOfItem(atPath: child.path)
            seq &+= 1
            var entry = Kernova_V1_ClipboardTreeEntry()
            entry.relativePath = rel
            entry.childSeq = seq
            if let mtime = attrs?[.modificationDate] as? Date {
                entry.mtimeMs = Int64(mtime.timeIntervalSince1970 * 1000)
            }
            if values?.isSymbolicLink == true {
                entry.kind = .symlink
                entry.symlinkTarget =
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: child.path)) ?? ""
                entries.append(entry)
            } else if values?.isDirectory == true {
                entry.kind = .directory
                entry.isPackage = values?.isPackage == true
                if let mode = attrs?[.posixPermissions] as? NSNumber {
                    entry.posixPermissions = mode.uint32Value & 0o7777
                }
                entries.append(entry)
                try recurse(child, prefix: rel, into: &entries, seq: &seq)
            } else {
                entry.kind = .file
                entry.byteCount = UInt64(values?.fileSize ?? 0)
                if let mode = attrs?[.posixPermissions] as? NSNumber {
                    entry.posixPermissions = mode.uint32Value & 0o7777
                }
                entries.append(entry)
            }
        }
    }

    /// Serializes a tree listing for the wire (the inline payload of a
    /// listing-mode `ClipboardTreeFetch` reply).
    ///
    /// `rootMtimeMs` is the source folder's own modification time (ms since
    /// epoch, 0 when unknown) — the entries carry only descendants' mtimes.
    public static func serializeListing(
        _ entries: [Kernova_V1_ClipboardTreeEntry], rootMtimeMs: Int64
    ) throws -> Data {
        var listing = Kernova_V1_ClipboardTreeListing()
        listing.entries = entries
        listing.rootMtimeMs = rootMtimeMs
        return try listing.serializedData()
    }

    /// Deserializes a tree listing received over the wire.
    public static func deserializeListing(_ data: Data) throws -> Kernova_V1_ClipboardTreeListing {
        try Kernova_V1_ClipboardTreeListing(serializedBytes: data)
    }

    /// The modification time of the item at `url` in milliseconds since the Unix
    /// epoch, or 0 when it cannot be read.
    public static func mtimeMs(at url: URL) -> Int64 {
        guard
            let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
                .modificationDate] as? Date
        else { return 0 }
        return Int64(mtime.timeIntervalSince1970 * 1000)
    }

    // MARK: - Estimate

    /// A stat-walk size estimate (sum of regular-file sizes) for a source folder,
    /// used only for the directory rep's offer `byte_count` (UI/free-space
    /// preflight).
    ///
    /// Metadata-only and bounded by `entryCap`; symlink cycles are
    /// bounded by the cap rather than resolved.
    public static func estimatedByteCount(at root: URL) -> Int {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
        else { return 0 }
        var total = 0
        var count = 0
        while let url = enumerator.nextObject() as? URL {
            count += 1
            if count > entryCap { break }
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            {
                total &+= values.fileSize ?? 0
            }
        }
        return total
    }

    // MARK: - Child resolution

    /// Resolves `relativePath` beneath `root` to the URL of a **regular file**,
    /// or `nil` when the path is unsafe or doesn't name a plain file.
    ///
    /// Rejects an absolute path, any `.`/`..` component, a leaf that is a symlink
    /// or a directory, and any path whose symlink-resolved location escapes
    /// `root` — defense in depth on the producer side (the listing never
    /// traverses symlinks, so a legitimate child fetch always names a path within
    /// the real tree).
    public static func resolveChildFile(root: URL, relativePath: String) -> URL? {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else { return nil }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: true).map(
            String.init)
        guard !components.isEmpty, !components.contains(".."), !components.contains(".") else {
            return nil
        }
        let resolved = components.reduce(root) { $0.appendingPathComponent($1) }
        // Symlink-resolved confinement: the resolved leaf (following any
        // symlinked intermediate) must still live under the root.
        let rootReal = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedReal = resolved.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedReal == rootReal || resolvedReal.hasPrefix(rootReal + "/") else { return nil }
        // The leaf must be a plain file, not a symlink (checked before following)
        // or a directory.
        guard
            let values = try? resolved.resourceValues(forKeys: [
                .isSymbolicLinkKey, .isRegularFileKey,
            ]),
            values.isSymbolicLink != true, values.isRegularFile == true
        else { return nil }
        return resolved
    }

    // MARK: - Producer: serve a tree fetch

    /// Serves a directory rep's tree fetch (folder D1b) off the caller's actor:
    /// walks the source tree for a **listing** (empty `relative_path`, streamed
    /// inline) or opens one **confined child** (`relative_path`, streamed as a
    /// file), replying over `sender` keyed by the fetch's `transfer_id`.
    ///
    /// A
    /// walk/open failure sends a `ClipboardStreamAbort` so the consumer's parked
    /// pull wakes immediately.
    ///
    /// The walk and LZFSE-free listing serialization run on a background queue so
    /// a large tree never blocks the caller's run loop; `sender.startTransfer`
    /// then reads the source off its own transfer queue. Shared by the host
    /// (host→guest paste) and the guest agent (guest→host "Copy to Mac").
    public static func serveFetch(
        _ fetch: Kernova_V1_ClipboardTreeFetch, sourceURL: URL, sender: ClipboardStreamSender,
        isCurrent: @escaping @Sendable (UInt64) -> Bool
    ) {
        let transferID = fetch.transferID
        let generation = fetch.generation
        let relativePath = fetch.relativePath
        let maxAccept = fetch.maxAcceptByteCount
        DispatchQueue.global(qos: .userInitiated).async {
            if relativePath.isEmpty {
                guard let entries = try? enumerateTree(at: sourceURL),
                    let data = try? serializeListing(
                        entries, rootMtimeMs: mtimeMs(at: sourceURL))
                else {
                    sender.rejectRequest(
                        transferID: transferID, code: "tree.error",
                        message: "Could not list the folder")
                    return
                }
                sender.startTransfer(
                    transferID: transferID, generation: generation,
                    representation: ClipboardContent.Representation(uti: treeListingUTI, data: data),
                    maxAcceptByteCount: ClipboardStreamTuning.unlimitedAcceptByteCount,
                    isInline: true, isCurrent: isCurrent)
            } else {
                guard let childURL = resolveChildFile(root: sourceURL, relativePath: relativePath),
                    let size = try? childURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                else {
                    sender.rejectRequest(
                        transferID: transferID, code: "tree.child.error",
                        message: "Could not open child \(relativePath)")
                    return
                }
                sender.startTransfer(
                    transferID: transferID, generation: generation,
                    representation: ClipboardContent.Representation(
                        uti: "public.data", fileURL: childURL, byteCount: size,
                        filename: (relativePath as NSString).lastPathComponent),
                    maxAcceptByteCount: maxAccept, isInline: false, isCurrent: isCurrent)
            }
        }
    }

    // MARK: - Consumer: listing → manifest tree

    /// Builds a `FileProviderManifest.FolderRep` from a received tree listing,
    /// resolving each node's parent (by relative-path prefix) and deriving a
    /// content UTI from its name so the consumer can publish the placeholder
    /// tree.
    ///
    /// Called on the consumer (paste) side.
    public static func makeFolderRep(
        sessionSalt: UInt64, generation: UInt64, repIndex: Int, filename: String,
        isPackage: Bool, estimatedByteCount: UInt64, rootMtimeMs: Int64,
        entries: [Kernova_V1_ClipboardTreeEntry]
    ) -> FileProviderManifest.FolderRep {
        // relativePath → childSeq, so a node resolves its parent's sequence.
        var seqByPath: [String: UInt32] = [:]
        for entry in entries { seqByPath[entry.relativePath] = entry.childSeq }
        let nodes = entries.map { entry -> FileProviderManifest.FolderRep.Node in
            let parentPath = (entry.relativePath as NSString).deletingLastPathComponent
            let parentSeq = parentPath.isEmpty ? 0 : (seqByPath[parentPath] ?? 0)
            let kind: FileProviderManifest.FolderRep.Node.Kind
            switch entry.kind {
            case .directory: kind = .directory
            case .symlink: kind = .symlink
            default: kind = .file
            }
            let name = (entry.relativePath as NSString).lastPathComponent
            return FileProviderManifest.FolderRep.Node(
                childSeq: entry.childSeq, parentChildSeq: parentSeq, kind: kind, filename: name,
                relativePath: entry.relativePath, byteCount: entry.byteCount,
                uti: contentUTI(kind: kind, filename: name, isPackage: entry.isPackage),
                isPackage: entry.isPackage, symlinkTarget: entry.symlinkTarget,
                posixPermissions: entry.posixPermissions, mtimeMs: entry.mtimeMs)
        }
        return FileProviderManifest.FolderRep(
            sessionSalt: sessionSalt, generation: generation, repIndex: repIndex,
            filename: filename,
            uti: contentUTI(kind: .directory, filename: filename, isPackage: isPackage),
            isPackage: isPackage, byteCount: estimatedByteCount, mtimeMs: rootMtimeMs, nodes: nodes)
    }

    /// Derives a content UTI for a tree node from its kind, name, and package
    /// flag — a package/file type from the extension, else `public.folder` for a
    /// plain directory or `public.data` for an unknown file.
    ///
    /// Symlinks are not
    /// content-typed here (the consumer uses `UTType.symbolicLink`).
    static func contentUTI(
        kind: FileProviderManifest.FolderRep.Node.Kind, filename: String, isPackage: Bool
    ) -> String {
        let ext = (filename as NSString).pathExtension
        switch kind {
        case .symlink:
            return UTType.symbolicLink.identifier
        case .directory:
            if isPackage, !ext.isEmpty, let type = UTType(filenameExtension: ext) {
                return type.identifier
            }
            return folderUTI
        case .file:
            if !ext.isEmpty, let type = UTType(filenameExtension: ext) { return type.identifier }
            return UTType.data.identifier
        }
    }
}
