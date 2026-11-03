#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaFileTree
import KernovaWire

/// Reads a FILE or FOLDER item from disk as the `TreeEvent`s its container carries, in depth-first pre-order,
/// never resolving a path or following a symlink.
///
/// Each entry is reached by one name relative to the descriptor of the directory it lies in, through a
/// ``DirectoryCursor``, and is described from the descriptor it is read through, confirmed to be the entry
/// the directory listed. A file's holes come out as `zeros`, exactly where the volume reports them, and its
/// stored bytes as `bytes` of at most `ContainerEncoder.chunkByteCount`.
///
/// Every event is one `ContainerEncoder` takes: an entry the format cannot carry — a FIFO, device or socket,
/// a name or symlink target past the format's limits, extended attributes too large for a header record, or
/// a file past the pull's byte ceiling — fails the read naming it, rather than leaving the item without it.
/// Only the extended attributes `EntryHeader.isCarriedXattrName(_:)` admits are read, and only the
/// `EntryHeader.carriedDarwinFlags` of an entry's flags.
public final class TreeReader<FileSystem: TreeFileSystem> {
    private let fileSystem: FileSystem
    private let acceptsLZ4: Bool
    private let byteCeiling: UInt64
    /// The bytes of every file so far.
    private var landedBytes: UInt64 = 0

    private enum Step {
        /// Moving through directories on the cursor.
        case walking
        /// Reading a file's bytes.
        case reading(FileRead)
        /// The item's own entry is complete; only the end follows.
        case ending
        case ended
        case failed(TreeReadFailure)
    }

    private var step: Step
    /// The item's own entry, not yet taken.
    private var rootEvent: TreeEvent?
    private var cursor: DirectoryCursor<FileSystem, Frame>?
    /// The names of the directories the reader is inside, the item's own first.
    private var entered: [[UInt8]] = []

    /// A directory entered: the names in it not yet read, the next one last.
    private struct Frame {
        var pending: [[UInt8]]
    }

    /// A reader of the item `name` in `parent`, which must be what `acceptance`'s storage names: a directory
    /// for FOLDER, a regular file for FILE.
    ///
    /// - Parameters:
    ///   - fileSystem: The calls the reader makes.
    ///   - name: The item's name in `parent`.
    ///   - parent: An open directory, used only while the reader is created; the caller keeps it.
    ///   - acceptance: What the pull accepts: its storage, its byte ceiling, and whether files go as LZ4
    ///     storage.
    /// - Throws: ``TreeReadFailure`` when the item cannot be opened or is not one `acceptance` names.
    public init(
        fileSystem: FileSystem, item name: [UInt8], in parent: Int32, accepting acceptance: ContainerAcceptance
    ) throws(TreeReadFailure) {
        self.fileSystem = fileSystem
        acceptsLZ4 = acceptance.acceptsLZ4
        byteCeiling = acceptance.byteCeiling
        step = .ended
        let path = [name]
        guard EntryHeader.isValidName(Data(name)) else { throw TreeReadFailure(path: path, reason: .notCarried(.name)) }
        let status = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.status(of: name, in: parent)
        }
        switch (status.kind, acceptance.storage) {
        case (.directory, .folder):
            let opened = try openDirectory(name, in: parent, listed: status, depth: 0, path: path)
            cursor = DirectoryCursor(
                fileSystem: fileSystem, descriptor: opened.descriptor, status: opened.status,
                frame: Frame(pending: opened.names))
            entered = [name]
            rootEvent = .enterDirectory(opened.header)
            step = .walking
        case (.regular, .file):
            let (read, header) = try openFile(name, in: parent, listed: status, depth: 0, path: path)
            rootEvent = .beginFile(header)
            step = .reading(read)
        default:
            throw TreeReadFailure(path: path, reason: .notCarried(.rootType(status.kind)))
        }
    }

    deinit {
        if case .reading(let read) = step { fileSystem.close(read.descriptor) }
    }

    /// The next event, or nil after `.end`.
    ///
    /// - Throws: ``TreeReadFailure`` naming the entry that could not be read or carried; the reader has then
    ///   closed everything it opened, and throws the same failure from every later call.
    public func next() throws(TreeReadFailure) -> TreeEvent? {
        if let rootEvent {
            self.rootEvent = nil
            return rootEvent
        }
        do throws(TreeReadFailure) {
            switch step {
            case .failed(let failure):
                throw failure
            case .ended:
                return nil
            case .ending:
                step = .ended
                return .end
            case .reading(var read):
                if let event = try read.next(on: fileSystem) {
                    step = .reading(read)
                    return event
                }
                step = entered.isEmpty ? .ending : .walking
                try read.finish(on: fileSystem)
                return .finishFile
            case .walking:
                return try walk()
            }
        } catch {
            if case .failed = step { throw error }
            if case .reading(let read) = step { fileSystem.close(read.descriptor) }
            cursor = nil
            step = .failed(error)
            throw error
        }
    }

    // MARK: - Walking

    /// The event for the next name in the current directory, or for leaving it once none is left.
    private func walk() throws(TreeReadFailure) -> TreeEvent {
        guard var held = cursor.take() else { preconditionFailure("walking with no directory entered") }
        let name = held.frame.pending.popLast()
        if name == nil && held.isAtTop {
            _ = consume held
            entered.removeLast()
            step = .ending
            return .leaveDirectory
        }
        var event = TreeEvent.end
        var failure: TreeReadFailure?
        do throws(TreeReadFailure) {
            if let name {
                event = try visit(name, in: &held)
            } else {
                try leave(&held)
                event = .leaveDirectory
            }
        } catch {
            failure = error
        }
        cursor = consume held
        if let failure { throw failure }
        return event
    }

    /// Reads the entry `name` in the cursor's directory, entering it when it is a directory.
    private func visit(_ name: [UInt8], in cursor: inout DirectoryCursor<FileSystem, Frame>) throws(TreeReadFailure)
        -> TreeEvent
    {
        let path = entered + [name]
        guard EntryHeader.isValidName(Data(name)) else { throw TreeReadFailure(path: path, reason: .notCarried(.name)) }
        let directory = cursor.descriptor
        let status = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.status(of: name, in: directory)
        }
        let depth = UInt32(entered.count)
        switch status.kind {
        case .directory:
            let opened = try openDirectory(name, in: directory, listed: status, depth: depth, path: path)
            cursor.descend(into: opened.descriptor, status: opened.status, frame: Frame(pending: opened.names))
            entered.append(name)
            return .enterDirectory(opened.header)
        case .regular:
            let (read, header) = try openFile(name, in: directory, listed: status, depth: depth, path: path)
            step = .reading(read)
            return .beginFile(header)
        case .symbolicLink:
            let target = try Self.system(path) { () throws(TreeFileSystemError) in
                try fileSystem.linkTarget(of: name, in: directory)
            }
            guard EntryHeader.isValidSymlinkTarget(Data(target)) else {
                throw TreeReadFailure(path: path, reason: .notCarried(.symlinkTarget))
            }
            var header = try header(
                name, depth: depth, type: .symlink, status: status, attributesOf: .symlink(name, in: directory),
                path: path)
            header.symlinkTarget = Data(target)
            try Self.requireFits(header, path: path)
            return .symlink(header)
        default:
            throw TreeReadFailure(path: path, reason: .notCarried(.type(status.kind)))
        }
    }

    /// Moves the cursor up out of the directory it is in.
    private func leave(_ cursor: inout DirectoryCursor<FileSystem, Frame>) throws(TreeReadFailure) {
        let path = entered
        do {
            _ = try cursor.ascend()
        } catch DirectoryCursorFailure.system(let error) {
            throw TreeReadFailure(path: path, reason: .system(error))
        } catch {
            throw TreeReadFailure(path: path, reason: .moved)
        }
        entered.removeLast()
    }

    // MARK: - Entries

    private struct OpenedDirectory {
        let descriptor: Int32
        let status: FileStatus
        let header: EntryHeader
        /// The names in it, the first last.
        let names: [[UInt8]]
    }

    /// Opens the directory `name` in `directory`, which listed it as `listed`, and describes it.
    private func openDirectory(
        _ name: [UInt8], in directory: Int32, listed: FileStatus, depth: UInt32, path: [[UInt8]]
    ) throws(TreeReadFailure) -> OpenedDirectory {
        let descriptor = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.openDirectory(name, in: directory)
        }
        do throws(TreeReadFailure) {
            let status = try opened(descriptor, listed: listed, path: path)
            let names = try Self.system(path) { () throws(TreeFileSystemError) in
                try fileSystem.names(in: descriptor)
            }
            let header = try header(
                name, depth: depth, type: .directory, status: status, attributesOf: .descriptor(descriptor),
                path: path)
            try Self.requireFits(header, path: path)
            return OpenedDirectory(
                descriptor: descriptor, status: status, header: header,
                names: names.sorted { $1.lexicographicallyPrecedes($0) })
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
    }

    /// Opens the regular file `name` in `directory`, which listed it as `listed`, and describes it.
    private func openFile(
        _ name: [UInt8], in directory: Int32, listed: FileStatus, depth: UInt32, path: [[UInt8]]
    ) throws(TreeReadFailure) -> (FileRead, EntryHeader) {
        let descriptor = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.openFile(name, in: directory)
        }
        do throws(TreeReadFailure) {
            let status = try opened(descriptor, listed: listed, path: path)
            let size = UInt64(max(0, status.size))
            guard size <= byteCeiling - landedBytes else {
                throw TreeReadFailure(path: path, reason: .exceedsByteCeiling(byteCeiling))
            }
            var header = try header(
                name, depth: depth, type: .file, status: status, attributesOf: .descriptor(descriptor), path: path)
            if acceptsLZ4 {
                header.lz4.size = size
            } else {
                header.plain.size = size
            }
            try Self.requireFits(header, path: path)
            landedBytes += size
            return (FileRead(descriptor: descriptor, path: path, status: status), header)
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
    }

    /// The status of `descriptor`, just opened by the name its directory listed as `listed`, confirmed to be
    /// that entry.
    private func opened(_ descriptor: Int32, listed: FileStatus, path: [[UInt8]]) throws(TreeReadFailure)
        -> FileStatus
    {
        let status = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.status(of: descriptor)
        }
        guard status.kind == listed.kind, status.device == listed.device, status.inode == listed.inode else {
            throw TreeReadFailure(path: path, reason: .changed)
        }
        return status
    }

    /// The header describing an entry of `status`, with the carried extended attributes of `target`.
    private func header(
        _ name: [UInt8], depth: UInt32, type: EntryHeader.TypeEnum, status: FileStatus,
        attributesOf target: TreeEntryTarget, path: [[UInt8]]
    ) throws(TreeReadFailure) -> EntryHeader {
        var header = EntryHeader()
        header.depth = depth
        header.name = Data(name)
        header.type = type
        header.mode = status.permissions
        header.darwinFlags = status.flags & EntryHeader.carriedDarwinFlags
        header.modificationTime = Kernova_V2_Timespec(status.modificationTime)
        if let birth = status.birthTime { header.birthTime = Kernova_V2_Timespec(birth) }
        let names = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.extendedAttributeNames(of: target)
        }
        for attribute in names.sorted(by: { $0.lexicographicallyPrecedes($1) })
        where EntryHeader.isCarriedXattrName(Data(attribute)) {
            let value = try Self.system(path) { () throws(TreeFileSystemError) in
                try fileSystem.extendedAttribute(attribute, of: target, maxByteCount: ContainerRecord.maxHeaderPayload)
            }
            guard let value else { throw TreeReadFailure(path: path, reason: .notCarried(.metadataTooLarge)) }
            var xattr = Kernova_V2_Xattr()
            xattr.name = Data(attribute)
            xattr.value = Data(value)
            header.xattrs.append(xattr)
        }
        return header
    }

    private static func requireFits(_ header: EntryHeader, path: [[UInt8]]) throws(TreeReadFailure) {
        guard header.fitsHeaderRecord else { throw TreeReadFailure(path: path, reason: .notCarried(.metadataTooLarge)) }
    }

    /// Runs a file-system call for the entry at `path`.
    fileprivate static func system<Result>(_ path: [[UInt8]], _ body: () throws(TreeFileSystemError) -> Result)
        throws(TreeReadFailure) -> Result
    {
        do {
            return try body()
        } catch {
            throw TreeReadFailure(path: path, reason: .system(error))
        }
    }

    // MARK: - Files

    /// A regular file being read, from the descriptor its status came from.
    private struct FileRead {
        let descriptor: Int32
        let path: [[UInt8]]
        /// The status its header described.
        let status: FileStatus
        /// The bytes read and the holes passed so far.
        var offset: Int64 = 0
        /// The end of the stored run `offset` lies in.
        var runEnd: Int64 = 0

        /// The file's next stored bytes or hole, or nil once it has all its size.
        mutating func next(on fileSystem: FileSystem) throws(TreeReadFailure) -> TreeEvent? {
            let size = status.size
            guard offset < size else { return nil }
            if offset >= runEnd {
                let start = offset
                let run = try TreeReader.system(path) { () throws(TreeFileSystemError) in
                    try fileSystem.dataRun(in: descriptor, from: start)
                }
                let dataStart = min(run?.lowerBound ?? size, size)
                if dataStart > offset {
                    offset = dataStart
                    return .zeros(UInt64(dataStart - start))
                }
                guard let run, run.upperBound > offset else { throw TreeReadFailure(path: path, reason: .changed) }
                runEnd = min(run.upperBound, size)
            }
            let count = Int(min(Int64(ContainerEncoder.chunkByteCount), runEnd - offset))
            var bytes = Data(count: count)
            // `withUnsafeMutableBytes` rethrows untyped, so the failure crosses it as a value.
            var failure: TreeFileSystemError?
            let at = offset
            let got = bytes.withUnsafeMutableBytes { buffer in
                do throws(TreeFileSystemError) {
                    return try fileSystem.read(descriptor, into: buffer, at: at)
                } catch {
                    failure = error
                    return 0
                }
            }
            if let failure { throw TreeReadFailure(path: path, reason: .system(failure)) }
            // The file ending before the size its header declared.
            guard got > 0 else { throw TreeReadFailure(path: path, reason: .changed) }
            offset += Int64(got)
            return .bytes(got == count ? bytes : bytes.prefix(got))
        }

        /// Closes the file, confirming its size and modification time are still those its header declared.
        func finish(on fileSystem: FileSystem) throws(TreeReadFailure) {
            defer { fileSystem.close(descriptor) }
            let now = try TreeReader.system(path) { () throws(TreeFileSystemError) in
                try fileSystem.status(of: descriptor)
            }
            guard now.size == status.size, now.modificationTime == status.modificationTime else {
                throw TreeReadFailure(path: path, reason: .changed)
            }
        }
    }
}

extension Kernova_V2_Timespec {
    init(_ time: FileTime) {
        self.init()
        seconds = time.seconds
        nanoseconds = UInt32(clamping: time.nanoseconds)
    }
}
