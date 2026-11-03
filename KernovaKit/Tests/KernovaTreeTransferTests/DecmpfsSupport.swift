#if canImport(Darwin)
import Compression
import Darwin
import Foundation
import KernovaContainer
import KernovaDigest
import KernovaFileTree
import KernovaPortableTestSupport
import Testing

@testable import KernovaTreeTransfer

/// A file's decmpfs storage: its `com.apple.decmpfs` attribute and its resource fork, and the plain bytes
/// they read back as.
struct CompressedSample {
    let type: UInt32
    let attribute: [UInt8]
    let resourceFork: [UInt8]
    let plain: Data

    /// The storage of a file of `type` holding `plain`, built in the layouts the pass-through note decoded
    /// (docs/research/2026-10-24-decmpfs-pass-through.md, finding 2) with public `libcompression` algorithms;
    /// nil for a type no public algorithm builds.
    ///
    /// Type 7 is LZVN, which has no public constant, so its payload is the LZVN decoder's stored form: the
    /// marker byte `0x06` and the bytes as they are.
    static func built(type: UInt32, plain: Data) -> CompressedSample? {
        let header = decmpfsAttribute(type: type, logicalSize: UInt64(plain.count))
        let attribute: (Data) -> CompressedSample = { payload in
            CompressedSample(type: type, attribute: Array(header + payload), resourceFork: [], plain: plain)
        }
        let fork: ([UInt8]) -> CompressedSample = { fork in
            CompressedSample(type: type, attribute: Array(header), resourceFork: fork, plain: plain)
        }
        switch type {
        case 3: return attribute(zlib(plain))
        case 7: return attribute(Data([0x06]) + plain)
        case 9: return attribute(Data([0xCC]) + plain)
        case 11: return attribute(encoded(plain, COMPRESSION_LZFSE))
        case 13: return attribute(encoded(plain, COMPRESSION_LZBITMAP))
        case 15: return attribute(encoded(plain, COMPRESSION_LZ4))
        case 4: return fork(type4Fork(blocks: chunks(of: plain).map(zlib)))
        case 12: return fork(chunkedFork(chunks(of: plain).map { encoded($0, COMPRESSION_LZFSE) }))
        case 14: return fork(chunkedFork(chunks(of: plain).map { encoded($0, COMPRESSION_LZBITMAP) }))
        case 16: return fork(chunkedFork(chunks(of: plain).map { encoded($0, COMPRESSION_LZ4) }))
        default: return nil
        }
    }

    /// The storage of the compressed file at `path`, read as the reader reads it.
    static func read(_ path: String, on fileSystem: POSIXTreeFileSystem) throws -> CompressedSample {
        let descriptor = open(path, O_RDONLY)
        try #require(descriptor >= 0, "open \(path)")
        defer { close(descriptor) }
        let attribute = try #require(
            try fileSystem.compressedStorage(of: descriptor, maxByteCount: DecmpfsHeader.maxAttributeByteCount))
        let header = try DecmpfsHeader(attribute: Data(attribute))
        let size = try fileSystem.resourceForkSize(of: descriptor, showingCompression: true)
        var fork = [UInt8](repeating: 0, count: Int(size))
        var offset = 0
        while offset < fork.count {
            let count = try fork.withUnsafeMutableBytes { buffer in
                try fileSystem.readResourceFork(
                    descriptor, into: UnsafeMutableRawBufferPointer(rebasing: buffer[offset...]),
                    at: UInt64(offset), showingCompression: true)
            }
            try #require(count > 0)
            offset += count
        }
        return CompressedSample(
            type: header.compressionType, attribute: attribute, resourceFork: fork, plain: try contents(of: path))
    }

    var logicalSize: UInt64 { UInt64(plain.count) }

    /// The 64 KiB pieces a resource fork's compressed chunks each hold.
    private static func chunks(of plain: Data) -> [Data] {
        stride(from: 0, to: plain.count, by: 65_536).map { plain[$0..<min($0 + 65_536, plain.count)] }
    }

    /// `data` encoded whole by `algorithm`.
    static func encoded(_ data: Data, _ algorithm: compression_algorithm) -> Data {
        let capacity = data.count + 4_096
        var output = [UInt8](repeating: 0, count: capacity)
        let count = data.withUnsafeBytes { input in
            compression_encode_buffer(
                &output, capacity, input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, algorithm)
        }
        precondition(count > 0, "the sample compresses")
        return Data(output[..<count])
    }

    /// `data` as a zlib stream: a header, `COMPRESSION_ZLIB`'s raw DEFLATE, then the Adler-32 big-endian.
    static func zlib(_ data: Data) -> Data {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler = b << 16 | a
        return Data([0x78, 0x5E]) + encoded(data, COMPRESSION_ZLIB)
            + Data((0..<4).map { UInt8(truncatingIfNeeded: adler >> (24 - $0 * 8)) })
    }

    /// A resource fork of types 8, 10, 12, 14 and 16: `chunks.count + 1` little-endian offsets, then the
    /// chunks.
    private static func chunkedFork(_ chunks: [Data]) -> [UInt8] {
        var offset = UInt32((chunks.count + 1) * 4)
        var fork: [UInt8] = []
        for chunk in chunks {
            fork += littleEndian(offset)
            offset += UInt32(chunk.count)
        }
        fork += littleEndian(offset)
        for chunk in chunks { fork += chunk }
        return fork
    }

    /// A type-4 resource fork: a resource file whose one resource, `cmpf` 1, holds a block table at `0x104`
    /// — a count, then each block's offset and length from there — and the zlib blocks.
    private static func type4Fork(blocks: [Data]) -> [UInt8] {
        var table = littleEndian(UInt32(blocks.count))
        var offset = UInt32(4 + blocks.count * 8)
        for block in blocks {
            table += littleEndian(offset) + littleEndian(UInt32(block.count))
            offset += UInt32(block.count)
        }
        for block in blocks { table += block }
        let dataLength = UInt32(4 + table.count)
        var fork = bigEndian(0x100) + bigEndian(0x100 + dataLength) + bigEndian(dataLength) + bigEndian(0x32)
        fork += [UInt8](repeating: 0, count: 0x100 - fork.count)
        fork += bigEndian(dataLength - 4) + table
        // The resource map: a reserved header copy, then one type `cmpf` with one resource, ID 1, unnamed.
        var map = [UInt8](repeating: 0, count: 24)
        map += [0x00, 0x1C, 0x00, 0x32, 0x00, 0x00] + Array("cmpf".utf8) + [0x00, 0x00, 0x00, 0x0A]
        map += [0x00, 0x01, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 8)
        return fork + map
    }

    private static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (24 - $0 * 8)) }
    }
}

/// `count` bytes of text that compresses, the same on every run.
func sampleText(_ count: Int, seed: UInt64 = 1) -> Data {
    let words = ["guest", "agent", "container", "fork", "decmpfs", "chunk", "kernel", "volume", "tree", "pull"]
    var generator = SplitMix64(seed: seed)
    var text = Data()
    while text.count < count {
        text.append(contentsOf: words[Int(generator.next() % UInt64(words.count))].utf8)
        text.append(0x20)
    }
    return text.prefix(count)
}

/// Every byte of the file at `path`, read plainly.
func contents(of path: String) throws -> Data {
    let descriptor = open(path, O_RDONLY)
    try #require(descriptor >= 0, "open \(path)")
    defer { close(descriptor) }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let count = read(descriptor, &buffer, buffer.count)
        try #require(count >= 0)
        if count == 0 { return data }
        data.append(contentsOf: buffer[..<count])
    }
}

/// `stat(2)` of `path`, not following a symlink.
func rawStatus(_ path: String) throws -> stat {
    var status = stat()
    try #require(lstat(path, &status) == 0, "lstat \(path)")
    return status
}

/// Creates `path` compressed with `sample`'s storage through the system calls alone — the fork, the
/// attribute, then the flag — leaving the descriptor open for a test to act on.
func createCompressedDirectly(_ path: String, _ sample: CompressedSample) throws -> Int32 {
    let descriptor = open(path, O_RDWR | O_CREAT | O_EXCL, 0o644)
    try #require(descriptor >= 0, "create \(path)")
    if !sample.resourceFork.isEmpty {
        try #require(
            fsetxattr(descriptor, XATTR_RESOURCEFORK_NAME, sample.resourceFork, sample.resourceFork.count, 0, 0) == 0)
    }
    try #require(fsetxattr(descriptor, "com.apple.decmpfs", sample.attribute, sample.attribute.count, 0, 0) == 0)
    try #require(fchflags(descriptor, UInt32(UF_COMPRESSED)) == 0)
    return descriptor
}

/// This machine's volumes through ``POSIXTreeFileSystem``, but for a flag write that leaves the flags as they
/// are: the result the confirmation after `UF_COMPRESSED` exists to catch.
struct FlagDroppingFileSystem: MutableTreeFileSystem {
    let base = POSIXTreeFileSystem()

    func setCompressedFlags(_ flags: UInt32, of descriptor: Int32) throws(TreeFileSystemError) {}

    func status(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> FileStatus {
        try base.status(of: name, in: directory)
    }
    func status(of descriptor: Int32) throws(TreeFileSystemError) -> FileStatus { try base.status(of: descriptor) }
    func openDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openDirectory(name, in: directory)
    }
    func openParent(of directory: Int32) throws(TreeFileSystemError) -> Int32 { try base.openParent(of: directory) }
    func openFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.openFile(name, in: directory)
    }
    func names(in directory: Int32) throws(TreeFileSystemError) -> [[UInt8]] { try base.names(in: directory) }
    func linkTarget(of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> [UInt8] {
        try base.linkTarget(of: name, in: directory)
    }
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(TreeFileSystemError) -> Int {
        try base.read(descriptor, into: buffer)
    }
    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    {
        try base.read(descriptor, into: buffer, at: offset)
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
        try base.readResourceFork(descriptor, into: buffer, at: offset, showingCompression: showingCompression)
    }
    func close(_ descriptor: Int32) { base.close(descriptor) }
    func setMode(_ mode: UInt32, of name: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.setMode(mode, of: name, in: directory)
    }
    func remove(_ name: [UInt8], in directory: Int32, isDirectory: Bool) throws(TreeFileSystemError) {
        try base.remove(name, in: directory, isDirectory: isDirectory)
    }
    func rename(_ name: [UInt8], in directory: Int32, to newName: [UInt8], in newDirectory: Int32)
        throws(TreeFileSystemError)
    {
        try base.rename(name, in: directory, to: newName, in: newDirectory)
    }
    func makeDirectory(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.makeDirectory(name, in: directory)
    }
    func createFile(_ name: [UInt8], in directory: Int32) throws(TreeFileSystemError) -> Int32 {
        try base.createFile(name, in: directory)
    }
    func makeSymlink(_ name: [UInt8], to target: [UInt8], in directory: Int32) throws(TreeFileSystemError) {
        try base.makeSymlink(name, to: target, in: directory)
    }
    func write(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: Int64)
        throws(TreeFileSystemError) -> Int
    {
        try base.write(descriptor, from: buffer, at: offset)
    }
    func setSize(of descriptor: Int32, to size: Int64) throws(TreeFileSystemError) {
        try base.setSize(of: descriptor, to: size)
    }
    func holeSize(of descriptor: Int32) -> Int? { base.holeSize(of: descriptor) }
    func punchHole(in descriptor: Int32, at offset: Int64, length: Int64) throws(TreeFileSystemError) {
        try base.punchHole(in: descriptor, at: offset, length: length)
    }
    func closeWritten(_ descriptor: Int32) throws(TreeFileSystemError) { try base.closeWritten(descriptor) }
    func setExtendedAttribute(_ name: [UInt8], to value: [UInt8], of target: TreeEntryTarget)
        throws(TreeFileSystemError)
    {
        try base.setExtendedAttribute(name, to: value, of: target)
    }
    func writeResourceFork(_ descriptor: Int32, from buffer: UnsafeRawBufferPointer, at offset: UInt64)
        throws(TreeFileSystemError) -> Bool
    {
        try base.writeResourceFork(descriptor, from: buffer, at: offset)
    }
    func volumeStoresCompressedFiles(_ directory: Int32) throws(TreeFileSystemError) -> Bool {
        try base.volumeStoresCompressedFiles(directory)
    }
    func setCompressedStorage(_ attribute: [UInt8], of descriptor: Int32) throws(TreeFileSystemError) {
        try base.setCompressedStorage(attribute, of: descriptor)
    }
    func setAttributes(_ attributes: TreeEntryAttributes, of target: TreeEntryTarget) throws(TreeFileSystemError) {
        try base.setAttributes(attributes, of: target)
    }
    func landingRefusal(of name: [UInt8], pathByteCount: Int) -> TreeFileSystemError? {
        base.landingRefusal(of: name, pathByteCount: pathByteCount)
    }
}

/// A 64 MB exFAT disk image attached under a scratch directory, detached and deleted when this goes.
final class ExFATVolume {
    let scratch: PortableScratchDirectory
    var mountPoint: String { scratch.path + "/mount" }
    private var image: String { scratch.path + "/volume.dmg" }

    init() throws {
        scratch = try PortableScratchDirectory(prefix: "exfat")
        try Self.hdiutil(["create", "-size", "64m", "-fs", "ExFAT", "-volname", "KTEST", image])
        try #require(mkdir(mountPoint, 0o755) == 0)
        try Self.hdiutil(["attach", "-nobrowse", "-noverify", "-mountpoint", mountPoint, image])
    }

    deinit {
        try? Self.hdiutil(["detach", "-force", mountPoint])
    }

    private static func hdiutil(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "hdiutil \(arguments.joined(separator: " "))")
    }
}
#endif
