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
/// stored bytes as `bytes` of at most `ContainerEncoder.chunkByteCount`; its resource fork follows, read in
/// pieces of the same size.
///
/// A file stored compressed whose decmpfs type the pull accepts is read as its compressed storage — its
/// `com.apple.decmpfs` attribute and the resource fork that holds its compressed bytes — and lands as it was
/// stored. Any other file, compressed or not, is read as the bytes it holds, which the kernel decompresses;
/// a compressed file then shows no resource fork.
///
/// Every event is one `ContainerEncoder` takes: an entry the format cannot carry — a FIFO, device or socket,
/// a name or symlink target past the format's limits, extended attributes too large for a header record, or
/// a file past the pull's byte ceiling — fails the read naming it, rather than leaving the item without it.
/// Every header is admitted through `ValidatedEntry`, the rules the decoder and writer hold it to; only the
/// extended attributes `ValidatedEntry.isAllowedXattrName(_:)` names are read, and only the
/// `ValidatedEntry.allowedDarwinFlags` of an entry's flags.
public final class TreeReader<FileSystem: TreeFileSystem> {
    private let fileSystem: FileSystem
    private let acceptance: ContainerAcceptance
    /// The logical bytes every file so far lands.
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
        self.acceptance = acceptance
        step = .ended
        let path = [name]
        // The item's name is the one name not read from a directory, so it is held to one path component
        // before anything resolves it.
        guard ValidatedEntry.isValidName(Data(name)) else {
            throw TreeReadFailure(path: path, reason: .notCarried(.entry(.invalidName)))
        }
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
            var header = try header(
                name, depth: depth, type: .symlink, status: status, attributesOf: .symlink(name, in: directory),
                path: path)
            header.symlinkTarget = Data(target)
            try Self.admit(header, path: path)
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
            try Self.admit(header, path: path)
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
            var header = try header(
                name, depth: depth, type: .file, status: status, attributesOf: .descriptor(descriptor), path: path)
            let compressedStorage = try compressedStorage(of: descriptor, status: status, path: path)
            let dataSize: UInt64
            if let compressedStorage {
                header.decmpfs.attribute = Data(compressedStorage)
                dataSize = 0
            } else if acceptance.acceptsLZ4 {
                dataSize = UInt64(max(0, status.size))
                header.lz4.size = dataSize
            } else {
                dataSize = UInt64(max(0, status.size))
                header.plain.size = dataSize
            }
            let showingCompression = compressedStorage != nil
            header.resourceForkSize = try Self.system(path) { () throws(TreeFileSystemError) in
                try fileSystem.resourceForkSize(of: descriptor, showingCompression: showingCompression)
            }
            let entry = try Self.admit(header, path: path)
            do {
                landedBytes = try acceptance.admitLanding(entry, after: landedBytes)
            } catch .exceedsByteCeiling {
                throw TreeReadFailure(path: path, reason: .exceedsByteCeiling(acceptance.byteCeiling))
            } catch {
                throw TreeReadFailure(path: path, reason: .notCarried(.entry(error)))
            }
            let read = FileRead(
                descriptor: descriptor, path: path, status: status, dataSize: Int64(dataSize),
                resourceForkSize: header.resourceForkSize, showingCompression: showingCompression)
            return (read, header)
        } catch {
            fileSystem.close(descriptor)
            throw error
        }
    }

    /// The `com.apple.decmpfs` attribute of the open file `descriptor` of `status`, when it is stored
    /// compressed in a type the pull accepts and its resource fork can be read in pieces; nil to read it as
    /// the bytes it holds.
    private func compressedStorage(of descriptor: Int32, status: FileStatus, path: [[UInt8]])
        throws(TreeReadFailure) -> [UInt8]?
    {
        guard status.isCompressed, !acceptance.decmpfsTypes.isEmpty else { return nil }
        let attribute = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.compressedStorage(of: descriptor, maxByteCount: DecmpfsHeader.maxAttributeByteCount)
        }
        guard let attribute, let header = try? DecmpfsHeader(attribute: Data(attribute)),
            acceptance.decmpfsTypes.contains(header.compressionType),
            header.uncompressedSize == UInt64(max(0, status.size))
        else { return nil }
        let forkSize = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.resourceForkSize(of: descriptor, showingCompression: true)
        }
        return forkSize <= ValidatedEntry.maxResourceForkByteCount ? attribute : nil
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
        header.darwinFlags = status.flags & ValidatedEntry.allowedDarwinFlags
        header.modificationTime = Kernova_V2_Timespec(status.modificationTime)
        if let birth = status.birthTime { header.birthTime = Kernova_V2_Timespec(birth) }
        let names = try Self.system(path) { () throws(TreeFileSystemError) in
            try fileSystem.extendedAttributeNames(of: target)
        }
        for attribute in names.sorted(by: { $0.lexicographicallyPrecedes($1) })
        where ValidatedEntry.isAllowedXattrName(Data(attribute)) {
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

    /// Holds `header` to the rules every entry keeps and to one header record.
    @discardableResult
    private static func admit(_ header: EntryHeader, path: [[UInt8]]) throws(TreeReadFailure) -> ValidatedEntry {
        let entry: ValidatedEntry
        do {
            entry = try ValidatedEntry(header)
        } catch {
            throw TreeReadFailure(path: path, reason: .notCarried(.entry(error)))
        }
        guard header.fitsHeaderRecord else { throw TreeReadFailure(path: path, reason: .notCarried(.metadataTooLarge)) }
        return entry
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

    /// A regular file being read, from the descriptor its status came from: its data, then its resource fork.
    private struct FileRead {
        let descriptor: Int32
        let path: [[UInt8]]
        /// The status its header described.
        let status: FileStatus
        /// The bytes of its data: its size, or none when it is read as its compressed storage.
        let dataSize: Int64
        let resourceForkSize: UInt64
        /// Whether the resource fork is read as its compressed storage holds it.
        let showingCompression: Bool
        /// The data's bytes read and holes passed so far.
        var offset: Int64 = 0
        /// The end of the stored run `offset` lies in.
        var runEnd: Int64
        /// The resource fork's bytes read so far, once its data is all read; nil before.
        var resourceForkOffset: UInt64?

        init(
            descriptor: Int32, path: [[UInt8]], status: FileStatus, dataSize: Int64, resourceForkSize: UInt64,
            showingCompression: Bool
        ) {
            self.descriptor = descriptor
            self.path = path
            self.status = status
            self.dataSize = dataSize
            self.resourceForkSize = resourceForkSize
            self.showingCompression = showingCompression
            // A compressed file's data fork stores nothing, so `lseek(2)` reports its whole size a hole
            // (`SEEK_DATA` fails with `ENXIO` on `/bin/ls`, macOS 27.2) while `read(2)` returns every byte: it is
            // read as one stored run.
            runEnd = status.isCompressed ? dataSize : 0
        }

        /// The file's next stored bytes or hole, the start of its resource fork, or nil once it has all its
        /// bytes.
        mutating func next(on fileSystem: FileSystem) throws(TreeReadFailure) -> TreeEvent? {
            if offset < dataSize { return try nextData(on: fileSystem) }
            guard let forkOffset = resourceForkOffset else {
                guard resourceForkSize > 0 else { return nil }
                resourceForkOffset = 0
                return .resourceFork
            }
            guard forkOffset < resourceForkSize else { return nil }
            let count = Int(min(UInt64(ContainerEncoder.chunkByteCount), resourceForkSize - forkOffset))
            let showing = showingCompression
            let bytes = try read(count) { buffer throws(TreeFileSystemError) in
                try fileSystem.readResourceFork(descriptor, into: buffer, at: forkOffset, showingCompression: showing)
            }
            resourceForkOffset = forkOffset + UInt64(bytes.count)
            return .bytes(bytes)
        }

        /// The data's next stored bytes or hole.
        private mutating func nextData(on fileSystem: FileSystem) throws(TreeReadFailure) -> TreeEvent {
            let size = dataSize
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
            let at = offset
            let bytes = try read(count) { buffer throws(TreeFileSystemError) in
                try fileSystem.read(descriptor, into: buffer, at: at)
            }
            offset += Int64(bytes.count)
            return .bytes(bytes)
        }

        /// Up to `count` bytes from one `read`, which must return some: a file ending before the size its
        /// header declared changed.
        private func read(_ count: Int, _ read: (UnsafeMutableRawBufferPointer) throws(TreeFileSystemError) -> Int)
            throws(TreeReadFailure) -> Data
        {
            var bytes = Data(count: count)
            // `withUnsafeMutableBytes` rethrows untyped, so the failure crosses it as a value.
            var failure: TreeFileSystemError?
            let got = bytes.withUnsafeMutableBytes { buffer in
                do throws(TreeFileSystemError) {
                    return try read(buffer)
                } catch {
                    failure = error
                    return 0
                }
            }
            if let failure { throw TreeReadFailure(path: path, reason: .system(failure)) }
            guard got > 0 else { throw TreeReadFailure(path: path, reason: .changed) }
            return got == count ? bytes : bytes.prefix(got)
        }

        /// Closes the file, confirming its size, modification time and resource fork are still those its
        /// header declared.
        func finish(on fileSystem: FileSystem) throws(TreeReadFailure) {
            defer { fileSystem.close(descriptor) }
            let showing = showingCompression
            let (now, forkSize) = try TreeReader.system(path) { () throws(TreeFileSystemError) in
                (
                    try fileSystem.status(of: descriptor),
                    try fileSystem.resourceForkSize(of: descriptor, showingCompression: showing)
                )
            }
            guard now.size == status.size, now.modificationTime == status.modificationTime,
                now.isCompressed == status.isCompressed, forkSize == resourceForkSize
            else {
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
