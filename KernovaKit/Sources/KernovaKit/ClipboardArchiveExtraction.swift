import AppleArchive
import Darwin
import Foundation
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

/// The attributes an entry asks for, applied after its content.
private struct EntryAttributes {
    let group: UInt64?
    let creation: timespec?
    let modification: timespec?
    let flags: UInt32?
    let mode: mode_t?

    init(_ fields: ClipboardArchiveEntryFields) {
        group = fields.group
        creation = fields.creation
        modification = fields.modification
        flags = fields.flags.map { UInt32(truncatingIfNeeded: $0) & ClipboardArchiveCodec.settableEntryFlags }
        mode = fields.mode.map { mode_t(truncatingIfNeeded: $0 & 0o7777) }
    }

    /// The attributes applied after the group, the mode without setgid
    /// unless `groupApplied`: setgid runs as the item's group, which is one
    /// the entry never named unless its own was applied.
    func settable(groupApplied: Bool) -> [ClipboardArchiveAttribute] {
        [
            creation.map(ClipboardArchiveAttribute.creation),
            modification.map(ClipboardArchiveAttribute.modification),
            flags.map(ClipboardArchiveAttribute.flags),
            mode.map { .mode(groupApplied ? $0 : $0 & ~S_ISGID) },
        ].compactMap { $0 }
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

    /// Creates the entry `fields` describes, running `content` once — unless
    /// the entry fails first — with the closure that puts each piece of a
    /// regular file's data into it, and discards the data of any other entry.
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
            try climb(&cursor, to: parent, for: path)
            let created = try create(fields, named: name, at: path, in: cursor.descriptor, content: content)
            if case .directory(let descriptor, let status) = created {
                cursor.descend(
                    into: descriptor, status: status, frame: Frame(attributes: EntryAttributes(fields)))
                here = path
            }
        }
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

    /// Climbs back to the top, applying each directory's attributes as it is
    /// left, the root entry's last.
    private func finish() throws {
        let climbed: Void? = try withCursor { cursor in
            try climb(&cursor, to: [], for: [])
            if let rootAttributes {
                try apply(rootAttributes, to: .descriptor(cursor.descriptor), path: [])
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
                        try apply(attributes, to: .descriptor(descriptor), path: left)
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
            try writeRegularFile(
                fields, named: name, at: path, in: directory, content: content, created: created)
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
            guard let target = fields.linkTarget, !target.contains(0) else {
                throw ClipboardArchiveMalformedEntry(
                    path: ClipboardArchiveCodec.displayPath(path), rule: .linkTarget)
            }
            try Self.attempt(path) { () throws(Errno) in
                try volume.makeSymlink(name, to: target, in: directory)
            }
            created()
            try apply(EntryAttributes(fields), to: .name(name, in: directory), path: path)
            return .item
        default:
            return .nothing
        }
    }

    /// Creates the regular file `name` in `directory` holding the data
    /// `content` delivers, then applies its attributes.
    private func writeRegularFile(
        _ fields: ClipboardArchiveEntryFields, named name: [UInt8], at path: [UInt8],
        in directory: Int32,
        content: (_ data: (UnsafeRawBufferPointer) throws -> Void) throws -> Void,
        created: () -> Void
    ) throws {
        let file = try Self.attempt(path) { () throws(Errno) in
            try volume.createFile(name, in: directory)
        }
        created()
        do {
            try content { piece in
                var written = 0
                while written < piece.count {
                    let count = try Self.attempt(path) { () throws(Errno) in
                        try volume.write(file, from: UnsafeRawBufferPointer(rebasing: piece[written...]))
                    }
                    // `write(2)` returns 0 only for a zero-byte request.
                    guard count > 0 else {
                        throw ClipboardItemFailure(
                            itemPath: ClipboardArchiveCodec.displayPath(path), reason: .unknown)
                    }
                    written += count
                }
            }
            try apply(EntryAttributes(fields), to: .descriptor(file), path: path)
        } catch {
            volume.close(file)
            throw error
        }
        // With `F_NOCACHE` and no `fsync`, a write failure can surface only
        // here.
        try Self.attempt(path) { () throws(Errno) in try volume.closeWritten(file) }
    }

    /// Applies `attributes` to `target`, the entry at `path`, one at a time,
    /// leaving out each one the target cannot hold: the group first, because
    /// changing it clears the set-id bits the mode then sets.
    ///
    /// An unprivileged receiver owns what it creates, so the entry's `UID` is
    /// never applied, and a group it cannot give — or a value no group can
    /// have — leaves the one the entry was created with (findings 7 and 11).
    private func apply(
        _ attributes: EntryAttributes, to target: ClipboardArchiveEntryTarget, path: [UInt8]
    ) throws {
        var groupApplied = false
        if let group = attributes.group.flatMap({ gid_t(exactly: $0) }) {
            groupApplied = try Self.applied(path) { () throws(Errno) in try volume.setGroup(group, of: target) }
        }
        for attribute in attributes.settable(groupApplied: groupApplied) {
            _ = try Self.applied(path) { () throws(Errno) in try volume.setAttribute(attribute, of: target) }
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
