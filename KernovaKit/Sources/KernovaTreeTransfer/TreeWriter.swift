#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaFileTree
import KernovaLogging
import KernovaWire

/// Lands a tree from its `TreeEvent`s, never resolving a path.
///
/// Every event is admitted through a `TreeEventSequence` before the writer acts on it — the rules the
/// container grammar holds a container's events to — so no producer lands an entry out of order, a size it did
/// not declare, or a name, flag, extended attribute, mode or time the format does not carry. Every entry
/// is created by one name relative to the descriptor of the directory it lies in —
/// `O_CREAT | O_EXCL | O_NOFOLLOW` for a file, `mkdirat` for a directory, `symlinkat` for a symlink, none
/// of which follows a symlink or replaces what has the name — and the only directories ever entered are
/// ones the writer just created. The directory an entry lies in is the top of the writer's stack, so no
/// entry can name a parent the transfer did not create, and a name taken twice, a symlink's included,
/// fails at its creation with `EEXIST`. A ``DirectoryCursor`` holds the stack, so at most two directories
/// are open whatever the depth. Each directory's mode, flags and times land as it is left.
///
/// The item's own entry is created in the destination under ``stagingName``, exclusively, and everything
/// else inside it; it takes ``name`` — the item's name, which the caller supplies and the container's unnamed
/// root does not carry — only when the module's ``TreeReceiver`` publishes it, after the producer confirmed
/// the tree whole. A failure removes it, so nothing the writer created stays anywhere.
///
/// A folder's symlinks and small files are held in a batch and created side by side
/// (``FolderBatch``) before the writer creates anything else or leaves the folder, so a failure among them
/// is still the first in the producer's order.
public final class TreeWriter<FileSystem: MutableTreeFileSystem> {
    /// The name the item's own entry has in the destination until it is published.
    public let stagingName: [UInt8]
    /// The name the item's own entry is published under, and the first component of a failure's path once that
    /// entry has begun.
    public let name: [UInt8]

    private let fileSystem: FileSystem
    private let destination: Int32
    private let destinationPathByteCount: Int
    private let logger: KernovaLogger

    private enum Phase {
        case writing
        case published
        case failed(TreeWriteFailure)
    }

    private var phase = Phase.writing
    /// The rules every event is admitted through before the writer acts on it.
    private var sequence: TreeEventSequence
    /// Whether the item's own entry was created under ``stagingName``, which a failure then removes.
    private var stagingCreated = false
    /// The identity of the item's own entry, once created.
    private var root: FolderBatch.Identity?
    /// The directories entered, the item's own first, while the cursor is inside them.
    private var cursor: DirectoryCursor<FileSystem, Frame>?
    /// Each directory entered, the item's own first.
    private var entered: [Entered] = []
    /// The file whose bytes are arriving.
    private var file: OpenFile?
    /// The folder's symlinks and small files waiting to be created.
    private(set) var batch = FolderBatch()
    /// The hole size of the destination's volume, once read: `.some(nil)` for one that makes none.
    private var volumeHoleSize: Int??

    /// A directory the writer is inside: its name, and its landing path's length.
    private struct Entered {
        let name: [UInt8]
        let pathByteCount: Int
    }

    /// A directory entered: its identity and what lands on it as it is left.
    private struct Frame {
        let identity: FolderBatch.Identity
        let metadata: EntryMetadata
    }

    /// A file whose bytes are arriving: its data's, then its resource fork's. It is changed only in place
    /// through ``file``, never through a copy, so appending to a held file's bytes never copies them.
    private struct OpenFile {
        let name: [UInt8]
        let path: [[UInt8]]
        let metadata: EntryMetadata
        /// The bytes its data and resource fork carry together.
        let byteCount: UInt64
        /// The `com.apple.decmpfs` attribute and logical size of a file landing compressed.
        let compressedStorage: (attribute: [UInt8], logicalSize: UInt64)?
        /// A file held for the folder's batch: its data and its resource fork so far, copied into storage of
        /// their own, so they keep nothing of the producer's buffers alive. Empty for a written file.
        var held = Data()
        var heldResourceFork = Data()
        /// A plain file written as its bytes arrive; `nil` for a held or compressed one.
        var written: SparseFile<FileSystem>?
        /// Whether the volume refused the written plain file's resource fork, which is then left out.
        var resourceForkDropped = false
        /// A compressed file written as its resource fork arrives; `nil` for a held or plain one.
        var compressed: CompressedFile<FileSystem>?
    }

    /// One run of a file's bytes, as an event carries it.
    private enum Piece {
        case bytes(Data)
        case zeros(UInt64)

        /// Runs `body` on the piece's bytes, in buffers of at most 64 KiB for zeros.
        func withBuffers<Failure: Error>(_ body: (UnsafeRawBufferPointer) throws(Failure) -> Void) throws(Failure) {
            switch self {
            case .bytes(let bytes):
                // `withUnsafeBytes` rethrows untyped, so the failure crosses it as a value.
                var failure: Failure?
                bytes.withUnsafeBytes { buffer in
                    do throws(Failure) {
                        try body(buffer)
                    } catch {
                        failure = error
                    }
                }
                if let failure { throw failure }
            case .zeros(var count):
                while count > 0 {
                    let piece = Int(min(count, UInt64(zeroBlock.count)))
                    try body(UnsafeRawBufferPointer(rebasing: zeroBlock[..<piece]))
                    count -= UInt64(piece)
                }
            }
        }
    }

    /// A writer landing the item `name` in `destination`.
    ///
    /// - Parameters:
    ///   - name: The item's name, which it is published under; one this OS cannot land fails the item's own
    ///     entry as it is created — `.container(.invalidName)` for one that is not a single path component.
    ///   - fileSystem: The calls the writer makes.
    ///   - destination: An open directory, which the writer takes ownership of and closes when it ends.
    ///   - destinationPathByteCount: The length in bytes of the destination's absolute path, against which
    ///     this OS's limit on a landed entry's path is measured.
    ///   - acceptance: What the pull accepts, which every event is held to: the root's type, the byte ceiling,
    ///     the decmpfs types it lands compressed, and its codecs.
    ///   - logger: Where a staging root the writer could not remove is reported.
    public init(
        name: [UInt8], fileSystem: FileSystem, destination: Int32, destinationPathByteCount: Int,
        accepting acceptance: ContainerAcceptance, logger: KernovaLogger = TreeWriterLog.logger
    ) {
        self.name = name
        self.fileSystem = fileSystem
        self.destination = destination
        self.destinationPathByteCount = destinationPathByteCount
        sequence = TreeEventSequence(accepting: acceptance)
        self.logger = logger
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<16).map { _ in Array("0123456789abcdef".utf8)[Int(generator.next() % 16)] }
        stagingName = Array(".kernova-".utf8) + suffix
    }

    deinit {
        discard()
        fileSystem.close(destination)
    }

    /// Takes the next event.
    ///
    /// - Throws: ``TreeWriteFailure`` naming the entry that failed; the writer has then removed everything it
    ///   created, and throws the same failure from every later call.
    public func write(_ event: TreeEvent) throws(TreeWriteFailure) {
        if case .failed(let failure) = phase { throw failure }
        let admitted: TreeEventSequence.Admitted
        do {
            admitted = try sequence.admit(event)
        } catch {
            throw fail(.container(error), at: path(of: event))
        }
        do {
            try take(event, admitted)
        } catch {
            throw fail(error)
        }
    }

    /// The path a refusal of `event` names: the entry an entry event creates, else the writer's place.
    private func path(of event: TreeEvent) -> [[UInt8]] {
        switch event {
        case .enterDirectory(let header), .beginFile(let header), .symlink(let header):
            if header.depth == 0 {
                [name]
            } else {
                entered.prefix(Int(min(header.depth, UInt32(entered.count)))).map(\.name) + [Array(header.name)]
            }
        default: position
        }
    }

    /// Fails the transfer at the writer's place in the tree.
    func failHere(_ reason: TreeWriteFailure.Reason) -> TreeWriteFailure {
        fail(reason, at: position)
    }

    /// The writer's place in the tree: the file open, else the directory it is in, else the item's own
    /// entry once it has begun.
    private var position: [[UInt8]] {
        if let file { return file.path }
        if !entered.isEmpty { return entered.map(\.name) }
        return root == nil ? [] : [name]
    }

    /// Gives the item's own entry ``name`` in the destination, exclusively.
    ///
    /// - Returns: ``name``, the name it landed under.
    func publish() throws(TreeWriteFailure) -> [UInt8] {
        switch phase {
        case .failed(let failure): throw failure
        case .published: throw failHere(.container(.bytesAfterEnd))
        case .writing: guard sequence.isEnded else { throw failHere(.container(.eventOutOfOrder)) }
        }
        guard let root else { preconditionFailure("ended with no root") }
        let staged = try? fileSystem.status(of: stagingName, in: destination)
        guard let staged, FolderBatch.Identity(staged) == root else {
            throw fail(.moved, at: [name])
        }
        do {
            try fileSystem.rename(stagingName, in: destination, to: name, in: destination)
        } catch {
            throw fail(.system(error), at: [name])
        }
        cursor = nil
        phase = .published
        return name
    }

    /// Removes everything the writer created, unless it was published.
    func discard() {
        if let written = file?.written { fileSystem.close(written.descriptor) }
        // A compressed file closes itself as it goes.
        file = nil
        cursor = nil
        _ = batch.take()
        guard stagingCreated, case .writing = phase else { return }
        do {
            try TreeRemoval.remove(stagingName, in: destination, on: fileSystem)
        } catch {
            let name = String(decoding: stagingName, as: UTF8.self)
            let reason = String(describing: error)
            logger.log(
                .error, "Could not remove the staging root \(name, privacy: .public): \(reason, privacy: .public)")
        }
    }

    // MARK: - Events

    /// Acts on `event`, which the sequence admitted as `admitted`.
    private func take(_ event: TreeEvent, _ admitted: TreeEventSequence.Admitted) throws(TreeWriteFailure) {
        switch (event, admitted) {
        case (.enterDirectory, .entry(let entry)): try enterDirectory(entry)
        case (.beginFile, .entry(let entry)): try beginFile(entry)
        case (.symlink, .entry(let entry)): try symlink(entry)
        case (.bytes(let bytes), .content(let part, let offset)): try carry(.bytes(bytes), into: part, at: offset)
        case (.zeros(let count), .content(let part, let offset)): try carry(.zeros(count), into: part, at: offset)
        case (.finishFile, _): try finishFile()
        case (.leaveDirectory, _): try leaveDirectory()
        // The sequence holds a resource fork's start and the end; neither creates anything.
        default: break
        }
    }

    private func enterDirectory(_ entry: ValidatedEntry) throws(TreeWriteFailure) {
        let (name, path, pathByteCount) = try landing(entry.header)
        let metadata = EntryMetadata(entry)
        if entry.header.depth == 0 {
            try system(path) { () throws(TreeFileSystemError) in
                try fileSystem.makeDirectory(stagingName, in: destination)
            }
            stagingCreated = true
            let (descriptor, status) = try open(stagingName, in: destination, path: path)
            root = FolderBatch.Identity(status)
            cursor = DirectoryCursor(
                fileSystem: fileSystem, descriptor: descriptor, status: status,
                frame: Frame(identity: FolderBatch.Identity(status), metadata: metadata))
        } else {
            try withCursor { cursor throws(TreeWriteFailure) in
                try createBatch(in: cursor.descriptor)
                let parent = cursor.descriptor
                try system(path) { () throws(TreeFileSystemError) in try fileSystem.makeDirectory(name, in: parent) }
                let (descriptor, status) = try open(name, in: parent, path: path)
                cursor.descend(
                    into: descriptor, status: status,
                    frame: Frame(identity: FolderBatch.Identity(status), metadata: metadata))
            }
        }
        entered.append(Entered(name: name, pathByteCount: pathByteCount))
    }

    private func beginFile(_ entry: ValidatedEntry) throws(TreeWriteFailure) {
        let (name, path, _) = try landing(entry.header)
        let metadata = EntryMetadata(entry)
        let compressedStorage = entry.decmpfs.map {
            (attribute: Array(entry.header.decmpfs.attribute), logicalSize: $0.uncompressedSize)
        }
        var open = OpenFile(
            name: name, path: path, metadata: metadata, byteCount: entry.carriedByteCount,
            compressedStorage: compressedStorage)
        let directory: Int32
        let created: [UInt8]
        if entry.header.depth == 0 {
            (directory, created) = (destination, stagingName)
        } else if entry.carriedByteCount <= FolderBatch.largestFile {
            file = open
            return
        } else {
            directory = try withCursor { cursor throws(TreeWriteFailure) in
                try createBatch(in: cursor.descriptor)
                return cursor.descriptor
            }
            created = name
        }
        do {
            if let compressedStorage {
                open.compressed = try CompressedFile(
                    creating: created, in: directory, attribute: compressedStorage.attribute,
                    logicalSize: compressedStorage.logicalSize, extendedAttributes: metadata.extendedAttributes,
                    on: fileSystem)
            } else {
                open.written = sparseFile(try fileSystem.createFile(created, in: directory))
            }
        } catch {
            throw TreeWriteFailure(path: path, reason: .system(error))
        }
        file = open
        guard created == stagingName else { return }
        stagingCreated = true
        do {
            let status: FileStatus
            if let compressed = open.compressed {
                status = try compressed.status()
            } else if let written = open.written {
                status = try fileSystem.status(of: written.descriptor)
            } else {
                preconditionFailure("the root file is written as it arrives")
            }
            root = FolderBatch.Identity(status)
        } catch {
            throw TreeWriteFailure(path: path, reason: .system(error))
        }
    }

    /// Lands `piece` of the open file's `part`, `offset` bytes into it.
    private func carry(_ piece: Piece, into part: TreeEventSequence.FilePart, at offset: UInt64)
        throws(TreeWriteFailure)
    {
        // Only scalars are read out of `file`: a copy of it would share the held bytes, and the append below
        // would then copy them all.
        guard let path = file?.path else { preconditionFailure("content admitted with no file open") }
        if part == .resourceFork {
            try carryResourceFork(piece, at: offset, path: path)
            return
        }
        guard var sparse = file?.written else {
            switch piece {
            case .bytes(let bytes):
                bytes.withUnsafeBytes { buffer in
                    buffer.withMemoryRebound(to: UInt8.self) { file?.held.append($0) }
                }
            case .zeros(let count):
                file?.held.count += Int(count)
            }
            return
        }
        defer { file?.written = sparse }
        try system(path) { () throws(TreeFileSystemError) in
            switch piece {
            case .bytes(let bytes): try sparse.append(bytes)
            case .zeros(let count): try sparse.appendZeros(Int64(count))
            }
        }
    }

    /// Lands `piece` of the current file's resource fork at `offset`: held, written into the plain file's
    /// fork, or appended to the compressed file's.
    private func carryResourceFork(_ piece: Piece, at offset: UInt64, path: [[UInt8]]) throws(TreeWriteFailure) {
        if let compressed = file?.compressed {
            do {
                try piece.withBuffers { buffer throws(CompressedFileFailure) in
                    try compressed.appendResourceFork(buffer)
                }
            } catch {
                throw TreeWriteFailure(path: path, reason: Self.reason(error))
            }
            return
        }
        guard let descriptor = file?.written?.descriptor else {
            switch piece {
            case .bytes(let bytes):
                bytes.withUnsafeBytes { buffer in
                    buffer.withMemoryRebound(to: UInt8.self) { file?.heldResourceFork.append($0) }
                }
            case .zeros(let count):
                file?.heldResourceFork.count += Int(count)
            }
            return
        }
        guard file?.resourceForkDropped == false else { return }
        var position = offset
        var held = true
        try system(path) { () throws(TreeFileSystemError) in
            try piece.withBuffers { buffer throws(TreeFileSystemError) in
                guard held else { return }
                held = try fileSystem.writeResourceFork(descriptor, from: buffer, at: position)
                position += UInt64(buffer.count)
            }
        }
        // A volume that holds no resource fork leaves it out, as it does any attribute it cannot hold.
        if !held { file?.resourceForkDropped = true }
    }

    private func finishFile() throws(TreeWriteFailure) {
        guard let open = file.take() else { preconditionFailure("a finish admitted with no file open") }
        if let compressed = open.compressed {
            do {
                _ = try compressed.finish(open.metadata.attributes)
            } catch {
                throw TreeWriteFailure(path: open.path, reason: Self.reason(error))
            }
            return
        }
        guard var sparse = open.written else {
            let content: FolderBatch.Entry.Content
            if let storage = open.compressedStorage {
                content = .compressedFile(
                    attribute: storage.attribute, logicalSize: storage.logicalSize,
                    resourceFork: open.heldResourceFork)
            } else {
                content = .file(open.held, resourceFork: open.heldResourceFork)
            }
            try hold(
                FolderBatch.Entry(
                    name: open.name, path: open.path, metadata: open.metadata, content: content,
                    byteCount: Int(open.byteCount)))
            return
        }
        let descriptor = sparse.descriptor
        do {
            try sparse.finish()
            try open.metadata.apply(to: .descriptor(descriptor), on: fileSystem)
        } catch {
            fileSystem.close(descriptor)
            throw TreeWriteFailure(path: open.path, reason: .system(error))
        }
        try system(open.path) { () throws(TreeFileSystemError) in try fileSystem.closeWritten(descriptor) }
    }

    /// The reason a compressed file's `failure` fails its entry for.
    static func reason(_ failure: CompressedFileFailure) -> TreeWriteFailure.Reason {
        switch failure {
        case .system(let error): .system(error)
        case .notCompressed(let refusal): .notCompressed(refusal)
        }
    }

    private func symlink(_ entry: ValidatedEntry) throws(TreeWriteFailure) {
        let (name, path, _) = try landing(entry.header)
        let target = Array(entry.header.symlinkTarget)
        try hold(
            FolderBatch.Entry(
                name: name, path: path, metadata: EntryMetadata(entry), content: .symlink(target: target),
                byteCount: target.count))
    }

    private func leaveDirectory() throws(TreeWriteFailure) {
        guard let left = entered.last else { preconditionFailure("a leave admitted with no directory entered") }
        let path = entered.map(\.name)
        try withCursor { cursor throws(TreeWriteFailure) in
            try createBatch(in: cursor.descriptor)
            guard !cursor.isAtTop else {
                try system(path) { () throws(TreeFileSystemError) in
                    try cursor.frame.metadata.apply(to: .descriptor(cursor.descriptor), on: fileSystem)
                }
                return
            }
            let frame: Frame
            do {
                frame = try cursor.ascend { descriptor, frame in
                    try frame.metadata.apply(to: .descriptor(descriptor), on: fileSystem)
                }
            } catch let error as TreeFileSystemError {
                throw TreeWriteFailure(path: path, reason: .system(error))
            } catch DirectoryCursorFailure.system(let error) {
                throw TreeWriteFailure(path: path, reason: .system(error))
            } catch {
                throw TreeWriteFailure(path: path, reason: .moved)
            }
            // The parent is the one the writer came down from; the name it gave the directory left must
            // still be that directory, not something moved or linked into its place.
            let named = try? fileSystem.status(of: left.name, in: cursor.descriptor)
            guard let named, named.kind == .directory, FolderBatch.Identity(named) == frame.identity else {
                throw TreeWriteFailure(path: path, reason: .moved)
            }
        }
        entered.removeLast()
    }

    // MARK: - Steps

    /// The name `header` lands under — ``name`` for the item's own entry, else its header's — its path, and
    /// its landing path's length, once this OS lands it.
    private func landing(_ header: EntryHeader) throws(TreeWriteFailure) -> (
        name: [UInt8], path: [[UInt8]], pathByteCount: Int
    ) {
        let name = header.depth == 0 ? self.name : Array(header.name)
        let path = entered.map(\.name) + [name]
        // The sequence held every header's name to one path component; the caller's is held here.
        guard header.depth > 0 || PathComponent.isValid(name) else {
            throw TreeWriteFailure(path: path, reason: .container(.invalidName))
        }
        let pathByteCount = (entered.last?.pathByteCount ?? destinationPathByteCount) + 1 + name.count
        if let refusal = fileSystem.landingRefusal(of: name, pathByteCount: pathByteCount) {
            throw TreeWriteFailure(path: path, reason: .refused(refusal))
        }
        return (name, path, pathByteCount)
    }

    /// Holds `entry` in the folder's batch, creating the batch first when it has no room for it.
    private func hold(_ entry: FolderBatch.Entry) throws(TreeWriteFailure) {
        if !batch.admits(entry) {
            try withCursor { cursor throws(TreeWriteFailure) in try createBatch(in: cursor.descriptor) }
        }
        batch.append(entry)
    }

    /// Creates the batch in `directory`, the folder the cursor is at.
    private func createBatch(in directory: Int32) throws(TreeWriteFailure) {
        guard !batch.isEmpty else { return }
        let entries = batch.take()
        let holeSize = holeSize(of: directory)
        if let (position, failure) = FolderBatch.create(entries, in: directory, holeSize: holeSize, on: fileSystem) {
            throw TreeWriteFailure(path: entries[position].path, reason: Self.reason(failure))
        }
    }

    /// Opens the directory `name` in `directory`, just created, as the entry at `path`.
    private func open(_ name: [UInt8], in directory: Int32, path: [[UInt8]]) throws(TreeWriteFailure) -> (
        Int32, FileStatus
    ) {
        let descriptor = try system(path) { () throws(TreeFileSystemError) in
            try fileSystem.openDirectory(name, in: directory)
        }
        do {
            return (descriptor, try fileSystem.status(of: descriptor))
        } catch {
            fileSystem.close(descriptor)
            throw TreeWriteFailure(path: path, reason: .system(error))
        }
    }

    private func sparseFile(_ descriptor: Int32) -> SparseFile<FileSystem> {
        SparseFile(fileSystem: fileSystem, descriptor: descriptor, holeSize: holeSize(of: descriptor))
    }

    /// The hole size of the destination's volume, read from `descriptor` the first time.
    private func holeSize(of descriptor: Int32) -> Int? {
        if let volumeHoleSize { return volumeHoleSize }
        let size = fileSystem.holeSize(of: descriptor)
        volumeHoleSize = .some(size)
        return size
    }

    /// Runs `body` on the cursor, taken out and put back.
    private func withCursor<Result>(
        _ body: (inout DirectoryCursor<FileSystem, Frame>) throws(TreeWriteFailure) -> Result
    ) throws(TreeWriteFailure) -> Result {
        guard var held = cursor.take() else { preconditionFailure("a folder's step admitted with no folder entered") }
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

    /// Runs a file-system call for the entry at `path`.
    private func system<Result>(_ path: [[UInt8]], _ body: () throws(TreeFileSystemError) -> Result)
        throws(TreeWriteFailure) -> Result
    {
        do {
            return try body()
        } catch {
            throw TreeWriteFailure(path: path, reason: .system(error))
        }
    }

    // MARK: - Failure

    private func fail(_ reason: TreeWriteFailure.Reason, at path: [[UInt8]]) -> TreeWriteFailure {
        fail(TreeWriteFailure(path: path, reason: reason))
    }

    /// Records `failure`, removing everything the writer created.
    private func fail(_ failure: TreeWriteFailure) -> TreeWriteFailure {
        if case .failed(let first) = phase { return first }
        discard()
        phase = .failed(failure)
        return failure
    }
}

/// The logger a ``TreeWriter`` reports to unless it is given another.
public enum TreeWriterLog {
    /// Category `TreeWriter` in the `app.kernova` subsystem.
    public static let logger = KernovaLogger(subsystem: "app.kernova", category: "TreeWriter")
}
