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

/// A 64 MB exFAT disk image attached under a scratch directory, detached and deleted when this goes.
///
/// A detach that fails records a warning, not an error, with hdiutil's message and the processes then holding
/// the image's device nodes: a forced detach unmounts past descriptors open on the volume and fails only while a
/// process holds a device node, which no code under test opens, so the failure says nothing about the test.
final class ExFATVolume {
    let scratch: PortableScratchDirectory
    var mountPoint: String { scratch.path + "/mount" }
    /// The device nodes the image attached as, from `hdiutil attach -plist`'s `dev-entry` keys.
    private let devices: [String]

    init() throws {
        scratch = try PortableScratchDirectory(prefix: "exfat")
        let image = scratch.path + "/volume.dmg"
        let mountPoint = scratch.path + "/mount"
        try Self.hdiutil(["create", "-size", "64m", "-fs", "ExFAT", "-volname", "KTEST", image]).require()
        try #require(mkdir(mountPoint, 0o755) == 0)
        let attached = try Self.hdiutil([
            "attach", "-plist", "-nobrowse", "-noverify", "-mountpoint", mountPoint, image,
        ])
        try attached.require()
        let plist = try PropertyListSerialization.propertyList(from: attached.output, format: nil)
        let entities = try #require((plist as? [String: Any])?["system-entities"] as? [[String: Any]])
        devices = entities.compactMap { $0["dev-entry"] as? String }
        try #require(!devices.isEmpty, "hdiutil attach named no device")
    }

    deinit {
        do {
            let detached = try Self.hdiutil(["detach", "-force", mountPoint])
            guard detached.status != 0 else { return }
            Issue.record(
                "\(detached.failure); holding \(devices.joined(separator: " ")): \(Self.holders(of: devices))",
                severity: .warning)
        } catch {
            Issue.record("hdiutil detach -force \(mountPoint) did not run: \(error)", severity: .warning)
        }
    }

    /// What a run of a tool printed and how it ended.
    private struct Run {
        let command: String
        let status: Int32
        let output: Data
        let errorOutput: String

        var failure: String { "\(command) exited \(status): \(errorOutput)" }

        func require() throws {
            try #require(status == 0, "\(failure)")
        }
    }

    private static func hdiutil(_ arguments: [String]) throws -> Run {
        try run("/usr/bin/hdiutil", arguments)
    }

    /// `lsof`'s report of every process holding `devices` or their raw nodes, or that none does.
    private static func holders(of devices: [String]) -> String {
        let nodes = devices.flatMap { [$0, $0.replacingOccurrences(of: "/dev/disk", with: "/dev/rdisk")] }
        guard let listed = try? run("/usr/sbin/lsof", ["-nP"] + nodes) else { return "lsof did not run" }
        let report = String(decoding: listed.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return report.isEmpty ? "no process holds them now" : report
    }

    private static func run(_ tool: String, _ arguments: [String]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let output = Pipe()
        let errorOutput = Pipe()
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()
        let printed = output.fileHandleForReading.readDataToEndOfFile()
        let complained = errorOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(
            command: ([URL(fileURLWithPath: tool).lastPathComponent] + arguments).joined(separator: " "),
            status: process.terminationStatus, output: printed,
            errorOutput: String(decoding: complained, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
#endif
