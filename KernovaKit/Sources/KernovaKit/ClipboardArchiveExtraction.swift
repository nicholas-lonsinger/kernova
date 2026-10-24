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
    /// Creates every regular-file, directory and symlink entry `decodeStream`
    /// delivers under `destination`, an existing empty directory.
    ///
    /// Any other entry — a FIFO, socket, device node, or a type no file
    /// system object has — creates nothing and fails nothing, and the entries
    /// after it still land. The peer chooses every entry's type, so the
    /// receiver is the one place that rule can hold.
    ///
    /// Each entry is created relative to its parent's open descriptor and
    /// never through a symlink, so neither path length nor depth bounds what
    /// lands. A directory's own attributes are applied once its contents have
    /// ended, the root entry's last of all, on `destination` itself.
    ///
    /// - Throws: ``ClipboardItemFailure`` naming the entry, relative to the
    ///   archive's root, that could not be created, written or given its
    ///   attributes; ``ClipboardArchiveMalformedEntry`` for an entry no
    ///   sender writes; or the decoder's own error. The extract stops there,
    ///   leaving what it created for the caller to remove.
    static func extractEntries<Volume: ClipboardArchiveWritableVolume>(
        from decodeStream: ArchiveStream, into destination: String, on volume: Volume
    ) throws {
        try TreeExtract(volume: volume, decodeStream: decodeStream).run(into: destination)
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

/// The attributes an arriving entry asks for, applied after its content.
private struct EntryAttributes {
    var group: UInt64?
    var settable: ClipboardArchiveSettableAttributes

    init(_ fields: ClipboardArchiveEntryFields) {
        group = fields.group
        settable = ClipboardArchiveSettableAttributes(
            creation: fields.creation, modification: fields.modification,
            mode: fields.mode.map { mode_t(truncatingIfNeeded: $0 & 0o7777) },
            flags: fields.flags.map {
                UInt32(truncatingIfNeeded: $0) & ClipboardArchiveCodec.settableEntryFlags
            })
    }
}

/// One extract's writes, against one volume and one decode stream.
private struct TreeExtract<Volume: ClipboardArchiveWritableVolume> {
    let volume: Volume
    let decodeStream: ArchiveStream

    /// A directory the extract is inside: the attributes its entry asked for.
    private struct Frame {
        let attributes: EntryAttributes?
    }

    func run(into destination: String) throws {
        let top = try attempt([]) { () throws(Errno) in
            try volume.openDirectory(Array(destination.utf8), in: AT_FDCWD)
        }
        let topStatus: stat
        do {
            topStatus = try attempt([]) { () throws(Errno) in try volume.status(of: top) }
        } catch {
            volume.close(top)
            throw error
        }
        var cursor = DirectoryCursor(
            volume: volume, descriptor: top, status: topStatus, frame: Frame(attributes: nil))
        defer { cursor.close() }
        // The path of the directory the cursor is at, empty at the destination.
        var here: [UInt8] = []
        var rootAttributes: EntryAttributes?
        var isFirst = true

        let buffer = UnsafeMutableRawBufferPointer.allocate(
            byteCount: ClipboardArchiveCodec.fileReadBlockSize, alignment: 16)
        defer { buffer.deallocate() }

        while let header = try decodeStream.readHeader() {
            guard let fields = ClipboardArchiveEntryFields(header), let path = fields.path else {
                throw ClipboardArchiveMalformedEntry(path: "", rule: .path)
            }
            guard let blobs = fields.blobs else {
                throw ClipboardArchiveMalformedEntry(
                    path: ClipboardArchiveCodec.displayPath(path), rule: .blobKey)
            }
            let wasFirst = isFirst
            isFirst = false
            guard !path.isEmpty else {
                guard wasFirst, fields.type == UInt64(ArchiveHeader.EntryType.directory.rawValue)
                else { throw ClipboardArchiveMalformedEntry(path: "", rule: .root) }
                rootAttributes = EntryAttributes(fields)
                try read(blobs, into: buffer) { _ in }
                continue
            }
            let (parent, name) = try Self.split(path)
            try climb(&cursor, from: &here, to: parent, for: path)
            if let directory = try create(
                fields, blobs: blobs, named: name, at: path, in: cursor.descriptor, buffer)
            {
                cursor.descend(
                    into: directory.descriptor, status: directory.status,
                    frame: Frame(attributes: EntryAttributes(fields)))
                here = path
            }
        }
        try climb(&cursor, from: &here, to: [], for: [])
        if let rootAttributes {
            try apply(rootAttributes, to: .descriptor(cursor.descriptor), path: [])
        }
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

    /// Moves the cursor up from `here` to `parent`, applying each directory's
    /// attributes as the extract leaves it.
    ///
    /// - Throws: ``ClipboardArchiveMalformedEntry`` for the entry at `path`
    ///   when `parent` is neither `here` nor above it.
    private func climb(
        _ cursor: inout DirectoryCursor<Volume, Frame>, from here: inout [UInt8], to parent: [UInt8],
        for path: [UInt8]
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

    /// Creates the entry `fields` describes as `name` in `directory`, reading
    /// all of its `blobs`.
    ///
    /// - Returns: for a directory, that directory, open, its attributes not
    ///   yet applied; otherwise `nil`, with a file or symlink created and its
    ///   attributes applied, or nothing created for any other type.
    private func create(
        _ fields: ClipboardArchiveEntryFields, blobs: [ClipboardArchiveEntryFields.Blob],
        named name: [UInt8], at path: [UInt8], in directory: Int32,
        _ buffer: UnsafeMutableRawBufferPointer
    ) throws -> (descriptor: Int32, status: stat)? {
        let type = fields.type.flatMap { UInt32(exactly: $0) }.flatMap(ArchiveHeader.EntryType.init)
        guard type != .regularFile else {
            try writeRegularFile(fields, blobs: blobs, named: name, at: path, in: directory, buffer)
            return nil
        }
        try read(blobs, into: buffer) { _ in }
        switch type {
        case .directory?:
            try attempt(path) { () throws(Errno) in try volume.makeDirectory(name, in: directory) }
            let opened = try attempt(path) { () throws(Errno) in
                try volume.openDirectory(name, in: directory)
            }
            do {
                let status = try attempt(path) { () throws(Errno) in try volume.status(of: opened) }
                return (opened, status)
            } catch {
                volume.close(opened)
                throw error
            }
        case .link?:
            guard let target = fields.linkTarget, !target.contains(0) else {
                throw ClipboardArchiveMalformedEntry(
                    path: ClipboardArchiveCodec.displayPath(path), rule: .linkTarget)
            }
            try attempt(path) { () throws(Errno) in
                try volume.makeSymlink(name, to: target, in: directory)
            }
            try apply(EntryAttributes(fields), to: .name(name, in: directory), path: path)
        default:
            // Left out: nothing is created.
            break
        }
        return nil
    }

    /// Reads every blob in `blobs`, in order and in full, in pieces of at most
    /// `buffer.count` bytes, handing `body` each piece of the first `DAT`.
    private func read(
        _ blobs: [ClipboardArchiveEntryFields.Blob], into buffer: UnsafeMutableRawBufferPointer,
        data body: (UnsafeRawBufferPointer) throws -> Void
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

    /// Creates the regular file `name` in `directory` holding the entry's
    /// first `DAT`, then applies its attributes.
    private func writeRegularFile(
        _ fields: ClipboardArchiveEntryFields, blobs: [ClipboardArchiveEntryFields.Blob],
        named name: [UInt8], at path: [UInt8], in directory: Int32,
        _ buffer: UnsafeMutableRawBufferPointer
    ) throws {
        let file = try attempt(path) { () throws(Errno) in try volume.createFile(name, in: directory) }
        do {
            try read(blobs, into: buffer) { piece in
                var written = 0
                while written < piece.count {
                    let count = try attempt(path) { () throws(Errno) in
                        try volume.write(
                            file, from: UnsafeRawBufferPointer(rebasing: piece[written...]))
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
        try attempt(path) { () throws(Errno) in try volume.closeWritten(file) }
    }

    /// Applies `attributes` to `target`, the entry at `path`: the group first,
    /// because changing it clears the set-id bits the mode then sets.
    private func apply(
        _ attributes: EntryAttributes, to target: ClipboardArchiveEntryTarget, path: [UInt8]
    ) throws {
        // An unprivileged receiver owns what it creates, so the entry's `UID`
        // is never applied, and a group the receiver is not in — `EPERM`, or
        // a value no group can have — leaves the one the entry was created
        // with (findings 7 and 11).
        if let group = attributes.group.flatMap({ gid_t(exactly: $0) }) {
            do {
                try volume.setGroup(group, of: target)
            } catch Errno.notPermitted {
                // Kept as created.
            } catch {
                throw ClipboardItemFailure(
                    itemPath: ClipboardArchiveCodec.displayPath(path), reason: .posix(error.rawValue))
            }
        }
        guard !attributes.settable.isEmpty else { return }
        try attempt(path) { () throws(Errno) in
            try volume.setAttributes(attributes.settable, of: target)
        }
    }

    private func attempt<Result>(
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
