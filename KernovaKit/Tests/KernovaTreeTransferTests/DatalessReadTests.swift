#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import KernovaContainer
import KernovaFileTree
import KernovaSynchronization
import KernovaWire
import Testing

@testable import KernovaTreeTransfer

/// A dataless entry — one a File Provider such as iCloud Drive evicted — is read as the local entry the read
/// downloads, described by the status it has once local.
@Suite("Dataless entries")
struct DatalessReadTests {
    private static let file = ContainerAcceptance(
        storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)
    private static let folder = ContainerAcceptance(
        storage: .folder, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)
    /// When the entries' contents last changed, once local.
    private static let localTime = FileTime(seconds: 1_700_000_000, nanoseconds: 0)

    /// Every event `reader` produces.
    private static func events(_ reader: TreeReader<DatalessFileSystem>) throws -> [TreeEvent] {
        var events: [TreeEvent] = []
        while let event = try reader.next() { events.append(event) }
        return events
    }

    @Test("a dataless file inside a folder, and a dataless folder, land as they are once local")
    func entriesInFolderMaterialized() throws {
        let bench = try FidelityBench()
        try bench.makeDirectory([bytes("Rewards")])
        try bench.makeDirectory([bytes("Rewards"), bytes("Receipts")])
        try bench.makeFile([bytes("Rewards"), bytes("Receipts"), bytes("a.txt")], Data("a".utf8))
        try bench.makeFile([bytes("Rewards"), bytes("Costco.png")], Data("costco".utf8))
        for path in [[bytes("Rewards"), bytes("Costco.png")], [bytes("Rewards"), bytes("Receipts")]] {
            try bench.setModificationTime(path, Self.localTime)
        }
        let fileSystem = DatalessFileSystem()
        try fileSystem.evict(bench.path([bytes("Rewards"), bytes("Costco.png")]))
        try fileSystem.evict(bench.path([bytes("Rewards"), bytes("Receipts")]))
        let events = try Self.events(
            TreeReader(fileSystem: fileSystem, root: bench.path([bytes("Rewards")]), accepting: Self.folder))
        let headers = events.compactMap { event -> EntryHeader? in
            switch event {
            case .beginFile(let header), .enterDirectory(let header): header
            default: nil
            }
        }
        let byName = Dictionary(headers.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let file = try #require(byName[Data("Costco.png".utf8)])
        #expect(file.modificationTime == Kernova_V2_Timespec(Self.localTime))
        #expect(file.plain.size == 6)
        let receipts = try #require(byName[Data("Receipts".utf8)])
        #expect(receipts.modificationTime == Kernova_V2_Timespec(Self.localTime))
        #expect(byName[Data("a.txt".utf8)] != nil, "the dataless folder's listing: \(events)")
        #expect(events.contains(.bytes(Data("costco".utf8))))
        #expect(events.last == .end)
    }

    @Test("an entry that stays dataless fails the read as not local, naming it")
    func staysDataless() throws {
        let bench = try FidelityBench()
        try bench.makeDirectory([bytes("Rewards")])
        try bench.makeDirectory([bytes("Rewards"), bytes("Receipts")])
        try bench.makeFile([bytes("Rewards"), bytes("Costco.png")], Data("costco".utf8))
        for (evicted, failing, acceptance) in [
            ([bytes("Rewards"), bytes("Costco.png")], [bytes("Costco.png")], Self.file),
            ([bytes("Rewards"), bytes("Costco.png")], [bytes("Rewards"), bytes("Costco.png")], Self.folder),
            ([bytes("Rewards"), bytes("Receipts")], [bytes("Rewards"), bytes("Receipts")], Self.folder),
        ] {
            let fileSystem = DatalessFileSystem(materializes: false)
            try fileSystem.evict(bench.path(evicted))
            let root = acceptance.storage == .file ? evicted : [bytes("Rewards")]
            let expected = TreeReadFailure(path: failing, reason: .notLocal)
            #expect(throws: expected) {
                _ = try Self.events(TreeReader(fileSystem: fileSystem, root: bench.path(root), accepting: acceptance))
            }
            #expect(expected.wireError.code == .readFailed)
            #expect(expected.wireError.debugDetail == TreeReadFailure.Reason.notLocal.description)
        }
    }
}

/// This machine's volumes, but for the entries it evicts: each reports `SF_DATALESS` and `UF_COMPRESSED`, and
/// another modification time, until the access the kernel materializes it on — a file's read, a directory's
/// listing — or, when it does not materialize, for good.
private final class DatalessFileSystem: TreeFileSystem {
    private let base = POSIXTreeFileSystem()
    private let materializes: Bool
    /// The device and inode of each entry still dataless.
    private let evicted = Locked<Set<[UInt64]>>([])

    init(materializes: Bool = true) {
        self.materializes = materializes
    }

    /// Makes the entry at the absolute `path` dataless.
    func evict(_ path: [UInt8]) throws {
        let status = try base.status(of: path, in: AT_FDCWD)
        evicted.withLock { _ = $0.insert([status.device, status.inode]) }
    }

    private func reported(_ status: FileStatus) -> FileStatus {
        guard evicted.withLock({ $0.contains([status.device, status.inode]) }) else { return status }
        var dataless = status
        dataless.flags |= FileStatus.datalessFlag | FileStatus.compressedFlag
        dataless.modificationTime = FileTime(seconds: 0, nanoseconds: 0)
        return dataless
    }

    private func access(_ descriptor: Int32) throws(TreeFileSystemError) {
        guard materializes else { return }
        let status = try base.status(of: descriptor)
        evicted.withLock { _ = $0.remove([status.device, status.inode]) }
    }

    func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus {
        reported(try base.status(of: name, in: directory))
    }
    func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus {
        reported(try base.status(of: descriptor))
    }
    func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openDirectory(name, in: directory)
    }
    func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32 { try base.openParent(of: directory) }
    func openFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openFile(name, in: directory)
    }
    func names(in directory: Int32) throws(TreeFileSystemError) -> [[UInt8]] {
        try access(directory)
        return try base.names(in: directory)
    }
    func linkTarget(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> [UInt8] {
        try base.linkTarget(of: name, in: directory)
    }
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(TreeFileSystemError) -> Int {
        try access(descriptor)
        return try base.read(descriptor, into: buffer)
    }
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    {
        try access(descriptor)
        return try base.read(descriptor, into: buffer, at: offset)
    }
    func dataRun(in descriptor: Int32, from offset: Int64) throws(TreeFileSystemError) -> Range<Int64>? {
        try base.dataRun(in: descriptor, from: offset)
    }
    func extendedAttributeNames(of target: TreeEntryTarget) throws(TreeFileSystemError) -> [[UInt8]] {
        try base.extendedAttributeNames(of: target)
    }
    func extendedAttribute(_ name: [UInt8], of target: TreeEntryTarget, maxByteCount: Int)
        throws(TreeFileSystemError) -> [UInt8]?
    {
        try base.extendedAttribute(name, of: target, maxByteCount: maxByteCount)
    }
    func compressedStorage(of descriptor: Int32, maxByteCount: Int) throws(TreeFileSystemError) -> [UInt8]? {
        try base.compressedStorage(of: descriptor, maxByteCount: maxByteCount)
    }
    func resourceForkSize(of descriptor: Int32, showingCompression: Bool) throws(TreeFileSystemError) -> UInt64 {
        try base.resourceForkSize(of: descriptor, showingCompression: showingCompression)
    }
    func readResourceFork(
        _ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, showingCompression: Bool
    ) throws(TreeFileSystemError) -> Int {
        try access(descriptor)
        return try base.readResourceFork(descriptor, into: buffer, at: offset, showingCompression: showingCompression)
    }
    func close(_ descriptor: Int32) { base.close(descriptor) }
}
#endif
