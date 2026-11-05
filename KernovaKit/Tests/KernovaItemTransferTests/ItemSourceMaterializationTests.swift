#if canImport(Darwin)
import Darwin
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaFileTree
import KernovaItemTransfer
import KernovaSynchronization
import KernovaWire
import Testing

/// A pull is when a representation's bytes move, so the source reads what it serves downloading a dataless file.
@Suite("Item source materialization")
struct ItemSourceMaterializationTests {
    @Test(
        "every open and read a pull of a FOLDER makes runs with materialization on",
        arguments: [4_096, WireConstants.maxRawDataPayload])
    func pullReadsWithMaterializationOn(readSize: Int) async throws {
        let bench = try Bench()
        try bench.write(Data(repeating: 7, count: 300_000), to: "source/Folder/a.bin")
        try bench.write(Data("b".utf8), to: "source/Folder/sub/b.txt")
        let fileSystem = PolicyRecordingFileSystem()
        let source = ItemSourceAdapter(fileSystem: fileSystem, logger: Bench.logger) { _, _, _, _ in
            .success(.tree(path: bench.path("source/Folder")))
        }
        var request = PullRequest()
        request.byteCeiling = 1 << 30
        var representation = Representation()
        representation.storage = .folder
        let (sources, reporter) = Inbox<ItemSourceInput>.make { ItemSourceReporter(ItemConnection(role: .host), $0) }
        source.handle(.serve(Bench.id, .clipboard, request, representation), reporter: reporter)
        defer { source.handle(.release(Bench.id), reporter: reporter) }
        reading: while true {
            source.handle(.read(Bench.id, maxBytes: readSize), reporter: reporter)
            switch await sources.next() {
            case .bytes?: continue
            case .finished?: break reading
            case let report: throw WireError(.internal, debugDetail: "\(String(describing: report))")
            }
        }
        let seen = fileSystem.seen.withLock { $0 }
        #expect(seen.opens >= 3)
        #expect(seen.reads > 0)
        #expect(seen.policies == [.on])
    }
}

/// The POSIX calls, recording each open's and read's thread policy.
private final class PolicyRecordingFileSystem: TreeFileSystem, Sendable {
    struct Seen {
        var opens = 0
        var reads = 0
        var policies: Set<DatalessMaterialization?> = []
    }

    let seen = Locked(Seen())
    private let posix = POSIXTreeFileSystem()

    private func record(read: Bool) {
        let policy = DatalessMaterialization.ofThisThread
        seen.withLock { seen in
            if read { seen.reads += 1 } else { seen.opens += 1 }
            seen.policies.insert(policy)
        }
    }

    func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus {
        try posix.status(of: name, in: directory)
    }

    func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus {
        try posix.status(of: descriptor)
    }

    func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        record(read: false)
        return try posix.openDirectory(name, in: directory)
    }

    func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32 {
        record(read: false)
        return try posix.openParent(of: directory)
    }

    func openFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        record(read: false)
        return try posix.openFile(name, in: directory)
    }

    func names(in directory: Int32) throws(TreeFileSystemError) -> [[UInt8]] {
        record(read: true)
        return try posix.names(in: directory)
    }

    func linkTarget(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> [UInt8] {
        try posix.linkTarget(of: name, in: directory)
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(TreeFileSystemError) -> Int {
        record(read: true)
        return try posix.read(descriptor, into: buffer)
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    {
        record(read: true)
        return try posix.read(descriptor, into: buffer, at: offset)
    }

    func dataRun(in descriptor: Int32, from offset: Int64) throws(TreeFileSystemError) -> Range<Int64>? {
        try posix.dataRun(in: descriptor, from: offset)
    }

    func extendedAttributeNames(of target: TreeEntryTarget) throws(TreeFileSystemError) -> [[UInt8]] {
        try posix.extendedAttributeNames(of: target)
    }

    func extendedAttribute(_ name: [UInt8], of target: TreeEntryTarget, maxByteCount: Int)
        throws(TreeFileSystemError) -> [UInt8]?
    {
        try posix.extendedAttribute(name, of: target, maxByteCount: maxByteCount)
    }

    func compressedStorage(of descriptor: Int32, maxByteCount: Int) throws(TreeFileSystemError) -> [UInt8]? {
        try posix.compressedStorage(of: descriptor, maxByteCount: maxByteCount)
    }

    func resourceForkSize(of descriptor: Int32, showingCompression: Bool) throws(TreeFileSystemError) -> UInt64 {
        try posix.resourceForkSize(of: descriptor, showingCompression: showingCompression)
    }

    func readResourceFork(
        _ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, showingCompression: Bool
    ) throws(TreeFileSystemError) -> Int {
        record(read: true)
        return try posix.readResourceFork(descriptor, into: buffer, at: offset, showingCompression: showingCompression)
    }

    func close(_ descriptor: Int32) { posix.close(descriptor) }
}
#endif
