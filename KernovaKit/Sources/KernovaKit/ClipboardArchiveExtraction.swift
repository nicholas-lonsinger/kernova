import AppleArchive
import Darwin
import Foundation
import KernovaSynchronization
import System

/// An arriving entry that breaks a rule every archive the sender writes keeps,
/// so the archive is not one this side unpacks.
struct ClipboardArchiveMalformedEntry: Error, Equatable {
    enum Rule: Equatable, Sendable {
        /// The path is not `/`-separated non-empty components, none of them
        /// `.` or `..`, free of NUL — or the entry has none.
        case path
        /// The entry's parent is not a directory the extract is still inside:
        /// one no earlier entry created, or one whose contents already ended.
        case parent
        /// The root entry — the one with an empty path — is not a directory,
        /// or is not the archive's first entry.
        case root
        /// A symlink entry carries no target, or one holding a NUL byte.
        case linkTarget
        /// A blob field's key is not three ASCII letters or digits.
        case blobKey
    }

    /// The entry's path, decoded for display.
    let path: String
    let rule: Rule
}

extension ClipboardArchiveCodec {
    /// Creates the entries `decodeStream` delivers under `destination`, an
    /// existing empty directory, through a ``TreeMaterializer``, the root
    /// entry's attributes landing on `destination` itself.
    ///
    /// The peer chooses every entry's type, so the materializer's leaving out
    /// all but regular files, directories and symlinks is the one place that
    /// rule can hold.
    ///
    /// - Throws: ``ClipboardItemFailure`` naming the entry, relative to the
    ///   archive's root, that could not be created, written or given its
    ///   attributes; ``ClipboardArchiveMalformedEntry`` for an entry no
    ///   sender writes; or the decoder's own error. The extract stops there,
    ///   leaving what it created for the caller to remove.
    static func extractEntries<Volume: ClipboardArchiveWritableVolume>(
        from decodeStream: ArchiveStream, into destination: String, on volume: Volume
    ) throws {
        try TreeMaterializer.materialize(into: destination, on: volume) { materializer in
            let buffer = UnsafeMutableRawBufferPointer.allocate(
                byteCount: fileReadBlockSize, alignment: 16)
            defer { buffer.deallocate() }
            while let header = try decodeStream.readHeader() {
                guard let fields = ClipboardArchiveEntryFields(header) else {
                    throw ClipboardArchiveMalformedEntry(path: "", rule: .path)
                }
                guard let blobs = fields.blobs else {
                    throw ClipboardArchiveMalformedEntry(
                        path: displayPath(fields.path ?? []), rule: .blobKey)
                }
                try materializer.take(fields) { data in
                    try readBlobs(blobs, from: decodeStream, into: buffer, data: data)
                }
            }
        }
    }

    /// Reads every blob in `blobs`, in order and in full, in pieces of at most
    /// `buffer.count` bytes, handing `body` each piece of the first `DAT`.
    private static func readBlobs(
        _ blobs: [ClipboardArchiveEntryFields.Blob], from decodeStream: ArchiveStream,
        into buffer: UnsafeMutableRawBufferPointer, data body: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let dataIndex = blobs.firstIndex(where: \.isData)
        for (index, blob) in blobs.enumerated() {
            var remaining = blob.size
            while remaining > 0 {
                let piece = UnsafeMutableRawBufferPointer(
                    rebasing: buffer[..<Int(min(UInt64(buffer.count), remaining))])
                try decodeStream.readBlob(key: blob.key, into: piece)
                if index == dataIndex { try body(UnsafeRawBufferPointer(piece)) }
                remaining -= UInt64(piece.count)
            }
        }
    }

    /// The flags an entry's `FLG` may set on what lands.
    ///
    /// Immutable and append-only are left out: either blocks `unlink` on the
    /// entry and on every directory above it, so one locked entry would leave
    /// the whole staged tree unremovable. The peer chooses `FLG`, so only the
    /// receiver can guarantee that. Every other flag needs privilege (`SF_*`,
    /// `UF_DATAVAULT`) or cannot be set (`UF_COMPRESSED`, `SF_DATALESS`)
    /// (docs/research/2026-10-23-applearchive-extract-semantics.md, finding 11).
    static let settableEntryFlags = UInt32(UF_NODUMP | UF_OPAQUE | UF_TRACKED | UF_HIDDEN)
}

private let pathSeparator = UInt8(ascii: "/")

/// The errnos with which a target refuses an attribute it cannot hold: a
/// group the receiver is not in is `EPERM` (finding 11), and on exFAT and FAT
/// every flag but `UF_HIDDEN` is `EINVAL`.
private let unheldAttributeErrnos: Set<Int32> = [EINVAL, ENOTSUP, EOPNOTSUPP, EPERM]

/// The bounds of the batch in which a ``TreeMaterializer`` creates a folder's
/// small entries side by side.
private enum FileBatch {
    /// The largest regular file a batch takes.
    static let largestFile = 256 * 1024
    /// The most file data and link targets one batch holds.
    static let byteBudget = 8 * 1024 * 1024
    /// The most entries one batch holds.
    static let entryBudget = 256
}

/// The attributes an entry asks for, applied after its content.
private struct EntryAttributes: Sendable {
    let group: UInt64?
    /// Every attribute but the group, the mode as the entry asks for it.
    let others: ClipboardArchiveAttributes

    init(_ fields: ClipboardArchiveEntryFields) {
        group = fields.group
        others = ClipboardArchiveAttributes(
            creation: fields.creation, modification: fields.modification,
            flags: fields.flags.map {
                UInt32(truncatingIfNeeded: $0) & ClipboardArchiveCodec.settableEntryFlags
            },
            mode: fields.mode.map { mode_t(truncatingIfNeeded: $0 & 0o7777) })
    }

    /// The attributes applied after the group, the mode without setgid
    /// unless `groupApplied`: setgid runs as the item's group, which is one
    /// the entry never named unless its own was applied.
    func settable(groupApplied: Bool) -> ClipboardArchiveAttributes {
        var settable = others
        if !groupApplied { settable.mode = settable.mode.map { $0 & ~S_ISGID } }
        return settable
    }
}

/// Creates a tree's entries as a source delivers them — the root entry, with
/// an empty path, first, and each directory ahead of its contents.
///
/// Each entry is created relative to its parent's open descriptor and never
/// through a symlink, so neither path length nor depth bounds what lands; a
/// ``DirectoryCursor`` holds the place, so at most two directories are open.
/// Only regular files, directories and symlinks are created. Below the root,
/// any other entry — a FIFO, socket, device node, or a type no file system
/// object has — creates nothing and fails nothing, and the entries after it
/// still land; a new item's root of another type fails with `EFTYPE`.
/// A directory's own attributes are applied once its contents have ended, the
/// root entry's last of all.
///
/// A folder's symlinks and small regular files are read into a batch, bounded
/// in entries and bytes, and created side by side, each regular file's
/// descriptor open only while it is written. The batch is created before the
/// materializer leaves the folder, and before any other entry is created, so
/// a failure in it is the one in archive order that creating the entries one
/// at a time would have met first. A regular file's whole blocks of zeros
/// become holes.
///
/// A source is the archive ``ClipboardArchiveCodec/extractEntries(from:into:on:)``
/// decodes, or a ``ClipboardArchiveCodec/TreeWalk`` of a tree on disk.
final class TreeMaterializer<Volume: ClipboardArchiveWritableVolume>: ClipboardArchiveEntrySink {
    /// Where the root entry lands.
    private enum Top {
        /// An existing directory, which the root entry's attributes are
        /// applied to, and the entries are created in.
        case existingDirectory(String)
        /// A path nothing occupies, where the root entry is created.
        case newItem(String)
    }

    /// Creates what `feed` delivers, through ``take(_:content:)``, in the
    /// existing directory `destination`, which the root entry's attributes
    /// are applied to. The root entry is optional, and is a directory when
    /// present.
    ///
    /// - Throws: ``ClipboardItemFailure`` naming the entry, relative to the
    ///   root, that could not be created, written or given its attributes;
    ///   ``ClipboardArchiveMalformedEntry`` for an entry out of order; or
    ///   what `feed` threw. What was created stays for the caller to remove.
    static func materialize(
        into destination: String, on volume: Volume, from feed: (TreeMaterializer) throws -> Void
    ) throws {
        try materialize(.existingDirectory(destination), on: volume, unfinished: { _ in }, from: feed)
    }

    /// Creates what `feed` delivers, through ``take(_:content:)``, at `path`,
    /// where the root entry — a file, directory or symlink, and required — is
    /// created, never replacing what is there. The folder holding `path` is
    /// never opened. When the root was created and the rest failed,
    /// `unfinished` runs with `path`, to dispose of what was created.
    ///
    /// - Throws: as ``materialize(into:on:from:)`` does, and `EEXIST` with an
    ///   empty path when something occupies `path`.
    static func materialize(
        newItemAt path: String, on volume: Volume, unfinished: (_ path: String) -> Void,
        from feed: (TreeMaterializer) throws -> Void
    ) throws {
        try materialize(.newItem(path), on: volume, unfinished: unfinished, from: feed)
    }

    private static func materialize(
        _ top: Top, on volume: Volume, unfinished: (String) -> Void,
        from feed: (TreeMaterializer) throws -> Void
    ) throws {
        let materializer = try TreeMaterializer(top, on: volume)
        do {
            defer { materializer.cursor = nil }
            try feed(materializer)
            try materializer.finish()
        } catch {
            if case .newItem(let path) = top, materializer.createdTop { unfinished(path) }
            throw error
        }
    }

    private let volume: Volume
    private let top: Top
    /// Where the entries are created; `nil` until a `.newItem` directory
    /// root is, and for one that is not a directory.
    private var cursor: DirectoryCursor<Volume, Frame>?
    /// The path of the directory the cursor is at, empty at the top.
    private var here: [UInt8] = []
    private var rootAttributes: EntryAttributes?
    private var isFirst = true
    /// Whether a `.newItem` root was created at the top.
    private var createdTop = false
    /// The entries of the directory the cursor is at waiting to be created,
    /// in archive order.
    private var batch: [PendingEntry] = []
    /// The file data and link targets `batch` holds.
    private var batchByteCount = 0
    /// The hole size of the volume the entries land on, once a descriptor
    /// there has been read: `.some(nil)` for a volume that makes no holes.
    private var volumeHoleSize: Int??

    /// A directory the materializer is inside: the attributes its entry asked
    /// for.
    private struct Frame {
        let attributes: EntryAttributes?
    }

    /// What ``create(_:named:at:in:content:created:)`` made.
    private enum Created {
        /// A directory, open, its attributes not yet applied.
        case directory(descriptor: Int32, status: stat)
        /// A file or symlink, its attributes applied.
        case item
        /// Nothing, for a type left out.
        case nothing
    }

    /// How ``take(_:content:)`` creates an entry below the root.
    private enum Handling {
        /// In the folder's batch, holding `byteCount` bytes of file data.
        case batchedFile(byteCount: Int)
        /// In the folder's batch.
        case batchedLink
        /// On its own, once the folder's batch is created.
        case alone
        /// Not at all: its type is left out.
        case leftOut

        init(_ fields: ClipboardArchiveEntryFields) {
            switch fields.type.flatMap({ UInt32(exactly: $0) }).flatMap(ArchiveHeader.EntryType.init) {
            case .regularFile?:
                let byteCount = fields.blobs?.first(where: \.isData)?.size ?? 0
                self = byteCount <= FileBatch.largestFile ? .batchedFile(byteCount: Int(byteCount)) : .alone
            case .link?: self = .batchedLink
            case .directory?: self = .alone
            default: self = .leftOut
            }
        }
    }

    /// An entry read into the batch: everything creating it takes.
    private struct PendingEntry: Sendable {
        enum Content: Sendable {
            case file(data: [UInt8])
            case link(target: [UInt8])
        }

        let name: [UInt8]
        let path: [UInt8]
        let attributes: EntryAttributes
        let content: Content
    }

    private init(_ top: Top, on volume: Volume) throws {
        self.volume = volume
        self.top = top
        guard case .existingDirectory(let destination) = top else { return }
        let descriptor = try Self.attempt([]) { () throws(Errno) in
            try volume.openDirectory(Array(destination.utf8), in: AT_FDCWD)
        }
        do {
            let status = try Self.attempt([]) { () throws(Errno) in try volume.status(of: descriptor) }
            cursor = DirectoryCursor(
                volume: volume, descriptor: descriptor, status: status, frame: Frame(attributes: nil))
        } catch {
            volume.close(descriptor)
            throw error
        }
    }

    /// Takes the entry `header` describes; ``take(_:content:)`` has the
    /// contract.
    func take(
        _ header: ArchiveHeader, content: (_ data: (UnsafeRawBufferPointer) throws -> Void) throws -> Void
    ) throws {
        guard let fields = ClipboardArchiveEntryFields(header) else {
            throw ClipboardArchiveMalformedEntry(path: "", rule: .path)
        }
        try take(fields, content: content)
    }

    /// Takes the entry `fields` describes, running `content` once — unless
    /// the entry fails first — with the closure that puts each piece of a
    /// regular file's data into it, and discards the data of any other entry.
    ///
    /// The entry may be created later, with the rest of its folder's batch.
    func take(
        _ fields: ClipboardArchiveEntryFields,
        content: (_ data: (UnsafeRawBufferPointer) throws -> Void) throws -> Void
    ) throws {
        guard let path = fields.path else { throw ClipboardArchiveMalformedEntry(path: "", rule: .path) }
        let wasFirst = isFirst
        isFirst = false
        guard !path.isEmpty else {
            guard wasFirst else { throw ClipboardArchiveMalformedEntry(path: "", rule: .root) }
            try takeRoot(fields, content: content)
            return
        }
        guard cursor != nil else {
            // A `.newItem` top whose root has not come, or is not a directory.
            throw ClipboardArchiveMalformedEntry(
                path: ClipboardArchiveCodec.displayPath(path), rule: wasFirst ? .root : .parent)
        }
        let (parent, name) = try Self.split(path)
        _ = try withCursor { cursor in
            if parent != here { try createBatch(in: cursor.descriptor) }
            try climb(&cursor, to: parent, for: path)
            switch Handling(fields) {
            case .batchedFile(let byteCount):
                if batch.count == FileBatch.entryBudget || batchByteCount + byteCount > FileBatch.byteBudget {
                    try createBatch(in: cursor.descriptor)
                }
                var data: [UInt8] = []
                data.reserveCapacity(byteCount)
                try content { piece in data.append(contentsOf: piece) }
                enqueue(fields, named: name, at: path, content: .file(data: data), byteCount: data.count)
            case .batchedLink:
                let target = try Self.linkTarget(of: fields, at: path)
                if batch.count == FileBatch.entryBudget || batchByteCount + target.count > FileBatch.byteBudget {
                    try createBatch(in: cursor.descriptor)
                }
                try content { _ in }
                enqueue(fields, named: name, at: path, content: .link(target: target), byteCount: target.count)
            case .alone:
                try createBatch(in: cursor.descriptor)
                let created = try create(fields, named: name, at: path, in: cursor.descriptor, content: content)
                if case .directory(let descriptor, let status) = created {
                    cursor.descend(
                        into: descriptor, status: status, frame: Frame(attributes: EntryAttributes(fields)))
                    here = path
                }
            case .leftOut:
                try content { _ in }
            }
        }
    }

    private func enqueue(
        _ fields: ClipboardArchiveEntryFields, named name: [UInt8], at path: [UInt8],
        content: PendingEntry.Content, byteCount: Int
    ) {
        batch.append(PendingEntry(name: name, path: path, attributes: EntryAttributes(fields), content: content))
        batchByteCount += byteCount
    }

    /// Runs `body` on the cursor, taken out and put back, returning `nil`
    /// when there is none.
    private func withCursor<Result>(
        _ body: (inout DirectoryCursor<Volume, Frame>) throws -> Result
    ) throws -> Result? {
        guard var held = cursor.take() else { return nil }
        let result: Result
        do {
            result = try body(&held)
        } catch {
            cursor = consume held
            throw error
        }
        cursor = consume held
        return result
    }

    private func takeRoot(
        _ fields: ClipboardArchiveEntryFields,
        content: (_ data: (UnsafeRawBufferPointer) throws -> Void) throws -> Void
    ) throws {
        switch top {
        case .existingDirectory:
            guard fields.type == UInt64(ArchiveHeader.EntryType.directory.rawValue) else {
                throw ClipboardArchiveMalformedEntry(path: "", rule: .root)
            }
            rootAttributes = EntryAttributes(fields)
            try content { _ in }
        case .newItem(let destination):
            let created = try create(
                fields, named: Array(destination.utf8), at: [], in: AT_FDCWD, content: content
            ) { self.createdTop = true }
            switch created {
            case .directory(let descriptor, let status):
                cursor = DirectoryCursor(
                    volume: volume, descriptor: descriptor, status: status, frame: Frame(attributes: nil))
                rootAttributes = EntryAttributes(fields)
            case .item:
                break
            case .nothing:
                throw ClipboardItemFailure(itemPath: "", reason: .posix(EFTYPE))
            }
        }
    }

    /// Creates the batch, then climbs back to the top, applying each
    /// directory's attributes as it is left, the root entry's last.
    private func finish() throws {
        let climbed: Void? = try withCursor { cursor in
            try createBatch(in: cursor.descriptor)
            try climb(&cursor, to: [], for: [])
            if let rootAttributes {
                try Self.apply(rootAttributes, to: .descriptor(cursor.descriptor), path: [], on: volume)
            }
        }
        if climbed == nil, !createdTop { throw ClipboardArchiveMalformedEntry(path: "", rule: .root) }
    }

    /// `path`'s parent and own name.
    ///
    /// - Throws: ``ClipboardArchiveMalformedEntry`` when `path` breaks the
    ///   path rule.
    private static func split(_ path: [UInt8]) throws -> (parent: [UInt8], name: [UInt8]) {
        for component in path.split(separator: pathSeparator, omittingEmptySubsequences: false) {
            guard !component.isEmpty, component != [0x2E], component != [0x2E, 0x2E],
                !component.contains(0)
            else {
                throw ClipboardArchiveMalformedEntry(
                    path: ClipboardArchiveCodec.displayPath(path), rule: .path)
            }
        }
        guard let slash = path.lastIndex(of: pathSeparator) else { return ([], path) }
        return (Array(path[..<slash]), Array(path[(slash + 1)...]))
    }

    /// The target of the symlink entry `fields`, at `path`.
    ///
    /// - Throws: ``ClipboardArchiveMalformedEntry`` for a missing target or
    ///   one holding a NUL.
    private static func linkTarget(
        of fields: ClipboardArchiveEntryFields, at path: [UInt8]
    ) throws(ClipboardArchiveMalformedEntry) -> [UInt8] {
        guard let target = fields.linkTarget, !target.contains(0) else {
            throw ClipboardArchiveMalformedEntry(
                path: ClipboardArchiveCodec.displayPath(path), rule: .linkTarget)
        }
        return target
    }

    /// Moves `cursor` up from ``here`` to `parent`, applying each
    /// directory's attributes as the materializer leaves it.
    ///
    /// - Throws: ``ClipboardArchiveMalformedEntry`` for the entry at `path`
    ///   when `parent` is neither ``here`` nor above it.
    private func climb(
        _ cursor: inout DirectoryCursor<Volume, Frame>, to parent: [UInt8], for path: [UInt8]
    ) throws {
        guard here != parent else { return }
        guard
            here.count > parent.count, here.starts(with: parent),
            parent.isEmpty || here[parent.count] == pathSeparator
        else {
            throw ClipboardArchiveMalformedEntry(
                path: ClipboardArchiveCodec.displayPath(path), rule: .parent)
        }
        while here != parent {
            let left = here
            let above = here.lastIndex(of: pathSeparator).map { Array(here[..<$0]) } ?? []
            do {
                _ = try cursor.ascend { descriptor, frame in
                    if let attributes = frame.attributes {
                        try Self.apply(attributes, to: .descriptor(descriptor), path: left, on: volume)
                    }
                }
            } catch let failure as DirectoryCursorFailure {
                throw failure.naming(above)
            }
            here = above
        }
    }

    /// Creates the entry `fields` describes as `name` in `directory`, calling
    /// `created` as soon as something exists under that name.
    private func create(
        _ fields: ClipboardArchiveEntryFields, named name: [UInt8], at path: [UInt8],
        in directory: Int32,
        content: (_ data: (UnsafeRawBufferPointer) throws -> Void) throws -> Void,
        created: () -> Void = {}
    ) throws -> Created {
        let type = fields.type.flatMap { UInt32(exactly: $0) }.flatMap(ArchiveHeader.EntryType.init)
        guard type != .regularFile else {
            try Self.writeRegularFile(
                named: name, at: path, in: directory, attributes: EntryAttributes(fields), on: volume,
                holeSize: holeSize(of:), created: created
            ) { file in
                try content { piece in try file.write(piece) }
            }
            return .item
        }
        try content { _ in }
        switch type {
        case .directory?:
            try Self.attempt(path) { () throws(Errno) in try volume.makeDirectory(name, in: directory) }
            created()
            let opened = try Self.attempt(path) { () throws(Errno) in
                try volume.openDirectory(name, in: directory)
            }
            do {
                let status = try Self.attempt(path) { () throws(Errno) in try volume.status(of: opened) }
                return .directory(descriptor: opened, status: status)
            } catch {
                volume.close(opened)
                throw error
            }
        case .link?:
            let target = try Self.linkTarget(of: fields, at: path)
            try Self.attempt(path) { () throws(Errno) in
                try volume.makeSymlink(name, to: target, in: directory)
            }
            created()
            try Self.apply(EntryAttributes(fields), to: .name(name, in: directory), path: path, on: volume)
            return .item
        default:
            return .nothing
        }
    }

    /// The hole size of the volume the entries land on, read from
    /// `descriptor` the first time.
    private func holeSize(of descriptor: Int32) -> Int? {
        if let volumeHoleSize { return volumeHoleSize }
        let size = volume.holeSize(of: descriptor)
        volumeHoleSize = .some(size)
        return size
    }

    // MARK: - The batch

    /// Creates the batch's entries in `directory`, the folder the cursor is
    /// at, side by side, and empties it.
    ///
    /// - Throws: the failure creating the entries one at a time, in archive
    ///   order, would have met first.
    private func createBatch(in directory: Int32) throws {
        guard !batch.isEmpty else { return }
        let entries = batch
        batch.removeAll(keepingCapacity: true)
        batchByteCount = 0
        let holeSize = holeSize(of: directory)
        let volume = volume
        let failures = Locked<[Int: any Error]>([:])
        DispatchQueue.concurrentPerform(iterations: entries.count) { position in
            do {
                try Self.create(entries[position], in: directory, holeSize: holeSize, on: volume)
            } catch {
                failures.withLock { $0[position] = error }
            }
        }
        let failed = failures.withLock { $0 }
        if let failure = Self.firstFailure(of: entries, failed: failed, in: directory, on: volume) { throw failure }
    }

    private static func create(
        _ entry: PendingEntry, in directory: Int32, holeSize: Int?, on volume: Volume
    ) throws {
        switch entry.content {
        case .file(let data):
            try writeRegularFile(
                named: entry.name, at: entry.path, in: directory, attributes: entry.attributes, on: volume,
                holeSize: { _ in holeSize }
            ) { file in
                try data.withUnsafeBytes { try file.write($0) }
            }
        case .link(let target):
            try attempt(entry.path) { () throws(Errno) in
                try volume.makeSymlink(entry.name, to: target, in: directory)
            }
            try apply(entry.attributes, to: .name(entry.name, in: directory), path: entry.path, on: volume)
        }
    }

    /// The failure creating `entries` one at a time, in order, would have met
    /// first, given the ones that `failed`, by position, created side by side
    /// — `nil` when none did.
    ///
    /// Of two entries the volume takes for one name, the later in archive
    /// order fails one at a time, but either can side by side, so each
    /// collision is charged to the second entry in archive order of those
    /// that took the name.
    private static func firstFailure(
        of entries: [PendingEntry], failed: [Int: any Error], in directory: Int32, on volume: Volume
    ) -> (any Error)? {
        var charged = failed
        let collided = failed.keys.filter { (failed[$0] as? ClipboardItemFailure)?.reason == .posix(EEXIST) }
        if !collided.isEmpty {
            func inode(_ position: Int) -> ino_t? {
                try? volume.status(of: entries[position].name, in: directory).st_ino
            }
            var holders: [ino_t: Int] = [:]
            for position in entries.indices where failed[position] == nil {
                if let inode = inode(position) { holders[inode] = position }
            }
            var sharers: [Int: [Int]] = [:]
            for position in collided {
                guard let holder = inode(position).flatMap({ holders[$0] }) else { continue }
                sharers[holder, default: [holder]].append(position)
                charged[position] = nil
            }
            for positions in sharers.values {
                let second = positions.sorted()[1]
                charged[second] = ClipboardItemFailure(
                    itemPath: ClipboardArchiveCodec.displayPath(entries[second].path), reason: .posix(EEXIST))
            }
        }
        return charged.min { $0.key < $1.key }?.value
    }

    // MARK: - Writes

    /// Creates the regular file `name` in `directory`, calls `created`, runs
    /// `fill` with the writer of its data — its holes the size `holeSize`
    /// gives for the new file's descriptor — then applies `attributes`.
    ///
    /// - Throws: ``ClipboardItemFailure`` naming `path` when the file cannot
    ///   be created, written, given its attributes or closed; or what `fill`
    ///   threw.
    private static func writeRegularFile(
        named name: [UInt8], at path: [UInt8], in directory: Int32, attributes: EntryAttributes,
        on volume: Volume, holeSize: (Int32) -> Int?, created: () -> Void = {},
        fill: (inout SparseFile) throws -> Void
    ) throws {
        let descriptor = try attempt(path) { () throws(Errno) in try volume.createFile(name, in: directory) }
        created()
        do {
            var file = SparseFile(volume: volume, descriptor: descriptor, holeSize: holeSize(descriptor), path: path)
            try fill(&file)
            try file.finish()
            try apply(attributes, to: .descriptor(descriptor), path: path, on: volume)
        } catch {
            volume.close(descriptor)
            throw error
        }
        // With `F_NOCACHE` and no `fsync`, a write failure can surface only
        // here.
        try attempt(path) { () throws(Errno) in try volume.closeWritten(descriptor) }
    }

    /// A new regular file's data, written in order, each run of whole
    /// hole-sized blocks of zeros left as a hole.
    ///
    /// A run is punched once it lies inside the file, the only place a punch
    /// frees blocks; until then the volume holds zeros there.
    private struct SparseFile {
        let volume: Volume
        let descriptor: Int32
        /// The unit and alignment of a hole, `nil` on a volume that makes
        /// none.
        let holeSize: Int?
        /// The entry the file is, for a failure to name.
        let path: [UInt8]
        /// The bytes written and skipped so far.
        private var length: Int64 = 0
        /// The zeros skipped since the last write, not yet a hole.
        private var skipped: Range<Int64>?

        init(volume: Volume, descriptor: Int32, holeSize: Int?, path: [UInt8]) {
            self.volume = volume
            self.descriptor = descriptor
            self.holeSize = holeSize
            self.path = path
        }

        /// Appends `data`.
        mutating func write(_ data: UnsafeRawBufferPointer) throws(ClipboardItemFailure) {
            guard let holeSize else {
                try writeWhole(data)
                return
            }
            var start = 0
            while start < data.count {
                let intoBlock = Int(length % Int64(holeSize))
                guard intoBlock == 0, data.count - start >= holeSize else {
                    let end = start + min(data.count - start, holeSize - intoBlock)
                    try writeWhole(UnsafeRawBufferPointer(rebasing: data[start..<end]))
                    start = end
                    continue
                }
                let isZero = Self.isZero(data, at: start, count: holeSize)
                var end = start + holeSize
                while data.count - end >= holeSize, Self.isZero(data, at: end, count: holeSize) == isZero {
                    end += holeSize
                }
                if isZero {
                    let run = Int64(end - start)
                    skipped = (skipped?.lowerBound ?? length)..<(length + run)
                    length += run
                } else {
                    try writeWhole(UnsafeRawBufferPointer(rebasing: data[start..<end]))
                }
                start = end
            }
        }

        /// Ends the file at the bytes appended, which skipped zeros leave it
        /// short of.
        mutating func finish() throws(ClipboardItemFailure) {
            guard skipped != nil else { return }
            try attempt(path) { () throws(Errno) in try volume.setSize(of: descriptor, to: length) }
            punchSkipped()
        }

        private mutating func writeWhole(_ data: UnsafeRawBufferPointer) throws(ClipboardItemFailure) {
            var written = 0
            while written < data.count {
                let count = try attempt(path) { () throws(Errno) in
                    try volume.write(
                        descriptor, from: UnsafeRawBufferPointer(rebasing: data[written...]),
                        at: length + Int64(written))
                }
                // `pwrite(2)` returns 0 only for a zero-byte request.
                guard count > 0 else {
                    throw ClipboardItemFailure(
                        itemPath: ClipboardArchiveCodec.displayPath(path), reason: .unknown)
                }
                written += count
            }
            length += Int64(written)
            punchSkipped()
        }

        private mutating func punchSkipped() {
            guard let run = skipped else { return }
            skipped = nil
            // The run already reads as zeros, so a volume refusing the hole
            // leaves the file whole, only larger.
            try? volume.punchHole(in: descriptor, at: run.lowerBound, length: run.upperBound - run.lowerBound)
        }

        /// Whether the `count` bytes of `data` at `start` are all zero.
        private static func isZero(_ data: UnsafeRawBufferPointer, at start: Int, count: Int) -> Bool {
            guard let base = data.baseAddress?.advanced(by: start) else { return true }
            var offset = 0
            while count - offset >= 64 {
                // Eight words at a time: a `SIMD64<UInt8>` comparison scans
                // fifty times slower.
                var word: UInt64 = 0
                for index in 0..<8 { word |= base.loadUnaligned(fromByteOffset: offset + index * 8, as: UInt64.self) }
                if word != 0 { return false }
                offset += 64
            }
            return UnsafeRawBufferPointer(start: base + offset, count: count - offset).allSatisfy { $0 == 0 }
        }
    }

    // MARK: - Attributes

    /// Applies `attributes` to `target`, the entry at `path`: the group
    /// first, because changing it clears the set-id bits the mode then sets,
    /// then the rest in one call — or, when the target refuses the call as
    /// holding one it cannot, one at a time, leaving out each it cannot hold.
    ///
    /// An unprivileged receiver owns what it creates, so the entry's `UID` is
    /// never applied, and a group it cannot give — or a value no group can
    /// have — leaves the one the entry was created with (findings 7 and 11).
    private static func apply(
        _ attributes: EntryAttributes, to target: ClipboardArchiveEntryTarget, path: [UInt8], on volume: Volume
    ) throws(ClipboardItemFailure) {
        var groupApplied = false
        if let group = attributes.group.flatMap({ gid_t(exactly: $0) }) {
            groupApplied = try applied(path) { () throws(Errno) in try volume.setGroup(group, of: target) }
        }
        let settable = attributes.settable(groupApplied: groupApplied)
        guard !settable.isEmpty,
            try !applied(path, { () throws(Errno) in try volume.setAttributes(settable, of: target) })
        else { return }
        let separated = settable.separated
        guard separated.count > 1 else { return }
        for attribute in separated {
            _ = try applied(path) { () throws(Errno) in try volume.setAttributes(attribute, of: target) }
        }
    }

    /// Runs `apply`, returning whether the target took the attribute, or
    /// `false` when it refused it as one it cannot hold.
    ///
    /// - Throws: ``ClipboardItemFailure`` naming `path` for any other errno.
    private static func applied(
        _ path: [UInt8], _ apply: () throws(Errno) -> Void
    ) throws(ClipboardItemFailure) -> Bool {
        do {
            try apply()
            return true
        } catch let error where unheldAttributeErrnos.contains(error.rawValue) {
            return false
        } catch {
            throw ClipboardItemFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(error.rawValue))
        }
    }

    private static func attempt<Result>(
        _ path: [UInt8], _ body: () throws(Errno) -> Result
    ) throws(ClipboardItemFailure) -> Result {
        do {
            return try body()
        } catch {
            throw ClipboardItemFailure(
                itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(error.rawValue))
        }
    }
}
