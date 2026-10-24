import AppleArchive
import Darwin
import Foundation
import KernovaTestSupport
import System
import Testing

@testable import KernovaKit

/// The folder walk and the entry headers it writes: headers match
/// AppleArchive's own, names cross as their raw bytes, and neither depth nor
/// path length bounds the tree. Round-trip fidelity is
/// `ClipboardArchiveStreamTests`.
@Suite("ClipboardArchiveTree", .caseScoped)
struct ClipboardArchiveTreeTests {
    private let scratch = TestScratchDirectory(prefix: "archive-tree-tests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - Headers

    /// The header AppleArchive itself builds for the entry at `path` under
    /// `directory`, with the archive's own key set.
    private func appleArchiveHeader(_ directory: String, _ path: String) throws -> [UInt8] {
        let keySet = try #require(ArchiveHeader.FieldKeySet(ClipboardArchive.fieldKeys))
        let header = try #require(
            ArchiveHeader(keySet: keySet, directory: FilePath(directory), path: FilePath(path), flags: []))
        return header.withAAEncodedData { Array($0) }
    }

    private func lstatus(_ path: String) throws -> stat {
        var status = stat()
        try #require(lstat(path, &status) == 0)
        return status
    }

    @Test("each entry kind's header is the one AppleArchive builds from the same entry")
    func headersMatchAppleArchives() throws {
        let root = scratch.url.appendingPathComponent("kinds", isDirectory: true).path
        try FileManager.default.createDirectory(atPath: "\(root)/d", withIntermediateDirectories: true)
        try Data("file".utf8).write(to: URL(fileURLWithPath: "\(root)/f"))
        try #require(symlink("f", "\(root)/l") == 0)
        try #require(mkfifo("\(root)/p", 0o644) == 0)

        for name in ["", "d", "p"] {
            let full = name.isEmpty ? root : "\(root)/\(name)"
            let ours = try ClipboardArchiveEntryHeader(
                path: Array(name.utf8), status: lstatus(full)
            ).make()
            #expect(ours.withAAEncodedData { Array($0) } == (try appleArchiveHeader(root, name)), "\(name)")
        }

        let link = try ClipboardArchiveEntryHeader(
            path: Array("l".utf8), status: lstatus("\(root)/l"), linkTarget: Array("f".utf8)
        ).make()
        #expect(link.withAAEncodedData { Array($0) } == (try appleArchiveHeader(root, "l")))

        // AppleArchive's header for a regular file carries no `DAT`; the
        // encoder adds it last, as the walk's own header has it.
        let file = try ClipboardArchiveEntryHeader(
            path: Array("f".utf8), status: lstatus("\(root)/f"), byteCount: 4
        ).make()
        guard case .blob(let key, let size, _) = file.remove(at: file.count - 1) else {
            Issue.record("a regular file's header does not end in its data")
            return
        }
        #expect(key == ArchiveHeader.FieldKey("DAT") && size == 4)
        #expect(file.withAAEncodedData { Array($0) } == (try appleArchiveHeader(root, "f")))

        // A device carries `DEV`, and devfs keeps no creation time.
        let device = try ClipboardArchiveEntryHeader(
            path: Array("null".utf8), status: lstatus("/dev/null")
        ).make()
        #expect(device.withAAEncodedData { Array($0) } == (try appleArchiveHeader("/dev", "null")))
    }

    // MARK: - Real volume

    /// The archive carries the whole tree; AppleArchive's extract, on the
    /// receiving side, is what then refuses a path this long.
    @Test("a folder whose paths run past PATH_MAX archives whole")
    func pathsPastPathMaxArchive() throws {
        let source = scratch.url.appendingPathComponent("deep", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let name = String(repeating: "n", count: 200)
        let depth = 6
        let payload = Data("at the bottom".utf8)

        // Built and removed a level at a time through descriptors: a full path
        // this long is refused by every path-taking call, the scratch
        // directory's own sweep included.
        var levels = [open(source.path, O_RDONLY | O_DIRECTORY)]
        defer {
            unlinkat(levels[levels.count - 1], "deep.txt", 0)
            while levels.count > 1 {
                close(levels.removeLast())
                unlinkat(levels[levels.count - 1], name, AT_REMOVEDIR)
            }
            close(levels[0])
        }
        try #require(levels[0] >= 0)
        for _ in 0..<depth {
            try #require(mkdirat(levels[levels.count - 1], name, 0o755) == 0)
            let next = openat(levels[levels.count - 1], name, O_RDONLY | O_DIRECTORY)
            try #require(next >= 0)
            levels.append(next)
        }
        let file = openat(levels[levels.count - 1], "deep.txt", O_WRONLY | O_CREAT, 0o644)
        try #require(file >= 0)
        defer { close(file) }
        try #require(payload.withUnsafeBytes { write(file, $0.baseAddress, $0.count) } == payload.count)

        let entries = try decodedEntries(
            ClipboardArchive.decompressedForTest(ClipboardArchive.archiveBytes(of: .directory(source))),
            readingBlobs: true)
        let deepPath = Array(
            (Array(repeating: name, count: depth).joined(separator: "/") + "/deep.txt").utf8)
        #expect(deepPath.count > Int(PATH_MAX))
        #expect(entries.first { $0.path == deepPath }?.data == payload)
    }

    /// Opening a FIFO for reading blocks until a writer arrives unless the open
    /// asks not to wait; the type check after the open is what refuses it.
    @Test("a FIFO where a regular file was expected is refused, not waited on")
    func fifoInPlaceOfAFileIsRefused() throws {
        let fifo = scratch.url.appendingPathComponent("pipe")
        try #require(mkfifo(fifo.path, 0o644) == 0)
        #expect(throws: ClipboardSourceReadFailure(itemPath: "", reason: .posix(EFTYPE))) {
            _ = try ClipboardArchive.archiveBytes(of: .file(fifo, name: "pipe", byteCount: 1))
        }
    }

    // MARK: - Walk, against a volume double

    private static let latin1Cafe: [UInt8] = Array("caf".utf8) + [0xE9]

    @Test("names that are not UTF-8 reach the archive as their own bytes")
    func rawNamesReachTheArchive() throws {
        let volume = FakeVolume()
        let cafe = volume.root.add(Self.latin1Cafe, .directory)
        cafe.add([0x6C, 0xFF], .link([0x74, 0xFE]))
        cafe.add([0x70], .fifo)

        let entries = try encodeTree(on: volume)
        #expect(
            entries.map(\.path) == [
                [], Self.latin1Cafe, Self.latin1Cafe + [0x2F, 0x6C, 0xFF], Self.latin1Cafe + [0x2F, 0x70],
            ])
        #expect(entries[2].link == [0x74, 0xFE])
        #expect(volume.open.isEmpty)
    }

    @Test("a failure on a name that is not UTF-8 names it decoded for display")
    func rawNameFailureIsDisplayable() throws {
        let volume = FakeVolume()
        let sub = volume.root.add(Self.latin1Cafe, .directory).add(Array("sub".utf8), .directory)
        sub.refusal = .permissionDenied

        #expect(
            throws: ClipboardSourceReadFailure(itemPath: "caf\u{FFFD}/sub", reason: .posix(EACCES))
        ) {
            _ = try encodeTree(on: volume)
        }
        #expect(volume.open.isEmpty)
    }

    @Test("a deep tree is walked whole while holding at most two directories open")
    func deepTreeHoldsBoundedDescriptors() throws {
        let volume = FakeVolume()
        var level = volume.root
        let depth = 400
        for _ in 0..<depth { level = level.add([0x64], .directory) }
        level.add([0x70], .fifo)
        volume.root.add([0x7A], .fifo)

        let entries = try encodeTree(on: volume)
        #expect(entries.count == 1 + depth + 2)
        #expect(entries.last?.path == [0x7A])
        #expect(volume.mostOpen <= 2)
        #expect(volume.open.isEmpty)
    }

    @Test("a path too long for an entry's header stops the walk, naming it")
    func pathPastTheHeaderStopsTheWalk() throws {
        let volume = FakeVolume()
        let name = [UInt8](repeating: 0x6E, count: 255)
        var level = volume.root
        for _ in 0..<300 { level = level.add(name, .directory) }

        do {
            _ = try encodeTree(on: volume)
            Issue.record("the walk archived a path no header can carry")
        } catch let failure as ClipboardSourceReadFailure {
            #expect(failure.reason == .posix(ENAMETOOLONG))
            #expect(failure.itemPath.utf8.count > Int(UInt16.max) - 256)
        }
        #expect(volume.open.isEmpty)
    }

    @Test("a directory no longer where the walk left it stops the walk, naming it")
    func movedAncestorStopsTheWalk() throws {
        let volume = FakeVolume()
        let a = volume.root.add([0x61], .directory)
        let b = a.add([0x62], .directory)
        b.add([0x70], .fifo)
        a.add([0x7A], .fifo)
        // `b` was moved out from under `a`: its `..` is somewhere else now.
        b.parentOverride = volume.root.add([0x6D], .directory)

        #expect(throws: ClipboardSourceReadFailure(itemPath: "a", reason: .unknown)) {
            _ = try encodeTree(on: volume)
        }
        #expect(volume.open.isEmpty)
    }

    // MARK: - Helpers

    /// What one decoded entry carries, its strings as raw bytes.
    private struct Entry {
        let path: [UInt8]
        let link: [UInt8]?
        let data: Data?
    }

    /// Walks `volume` into an uncompressed archive and decodes its entries.
    private func encodeTree(on volume: FakeVolume) throws -> [Entry] {
        let sink = ClipboardArchiveDataSink()
        do {
            let byteStream = try #require(ArchiveByteStream.customStream(instance: sink))
            defer { try? byteStream.close() }
            let encode = try #require(ArchiveStream.encodeStream(writingTo: byteStream))
            defer { try? encode.close() }
            try ClipboardArchiveCodec.writeTree(at: FakeVolume.rootPath, to: encode, on: volume)
        }
        return try decodedEntries(sink.bytes, readingBlobs: false)
    }

    /// The entries of an uncompressed archive.
    private func decodedEntries(_ bytes: Data, readingBlobs: Bool) throws -> [Entry] {
        let byteStream = try #require(
            ArchiveByteStream.customStream(instance: ClipboardArchiveDataSource(bytes: bytes)))
        defer { try? byteStream.close() }
        let decode = try #require(ArchiveStream.decodeStream(readingFrom: byteStream))
        defer { try? decode.close() }
        var entries: [Entry] = []
        while let header = try decode.readHeader() {
            let encoded = header.withAAEncodedData { Array($0) }
            var data: Data?
            if readingBlobs, case .blob(_, let size, _)? = header.field(forKey: .init("DAT")) {
                var buffer = Data(count: Int(size))
                try buffer.withUnsafeMutableBytes { try decode.readBlob(key: .init("DAT"), into: $0) }
                data = buffer
            }
            entries.append(
                Entry(
                    path: try #require(Self.stringField("PAT", in: encoded)),
                    link: Self.stringField("LNK", in: encoded), data: data))
        }
        return entries
    }

    /// The raw bytes of the string field `key` in an encoded header: its key,
    /// the subtype `P`, a little-endian `UInt16` length, then the bytes.
    private static func stringField(_ key: String, in encoded: [UInt8]) -> [UInt8]? {
        let marker = Array(key.utf8) + [UInt8(ascii: "P")]
        var index = 6
        while index + marker.count + 2 <= encoded.count {
            if Array(encoded[index..<index + marker.count]) == marker {
                let start = index + marker.count + 2
                let length = Int(encoded[start - 2]) | Int(encoded[start - 1]) << 8
                return Array(encoded[start..<start + length])
            }
            index += 1
        }
        return nil
    }
}

extension ClipboardArchive {
    /// `archive`, LZ4 decompressed.
    fileprivate static func decompressedForTest(_ archive: Data) throws -> Data {
        let sink = ClipboardArchiveDataSink()
        let source = try #require(
            ArchiveByteStream.customStream(instance: ClipboardArchiveDataSource(bytes: archive)))
        defer { try? source.close() }
        let decompress = try #require(ArchiveByteStream.decompressionStream(readingFrom: source))
        defer { try? decompress.close() }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decompress.read(into: $0) }
            if count <= 0 { break }
            _ = try buffer.withUnsafeBytes {
                try sink.write(from: UnsafeRawBufferPointer(rebasing: $0[..<count]))
            }
        }
        return sink.bytes
    }
}

/// An in-memory volume the walk reads through descriptors it hands out,
/// recording how many it holds open at once.
private final class FakeVolume: ClipboardArchiveVolume {
    static let rootPath = "/fake/root"

    final class Node {
        enum Kind {
            case directory
            case link([UInt8])
            case fifo
        }

        let kind: Kind
        let inode: ino_t
        private(set) var children: [[UInt8]: Node] = [:]
        weak var parent: Node?
        /// Where `..` leads instead of `parent`.
        var parentOverride: Node?
        /// What opening this directory fails with.
        var refusal: Errno?
        private unowned let volume: FakeVolume

        init(_ kind: Kind, volume: FakeVolume) {
            self.kind = kind
            self.volume = volume
            inode = volume.mintInode()
        }

        @discardableResult
        func add(_ name: [UInt8], _ kind: Kind) -> Node {
            let child = Node(kind, volume: volume)
            child.parent = self
            children[name] = child
            return child
        }
    }

    private var nextInode: ino_t = 2
    private var nextDescriptor: Int32 = 100
    private(set) var open: [Int32: Node] = [:]
    private(set) var mostOpen = 0
    private(set) lazy var root = Node(.directory, volume: self)

    fileprivate func mintInode() -> ino_t {
        defer { nextInode += 1 }
        return nextInode
    }

    private func node(_ name: [UInt8], in directory: Int32) throws(Errno) -> Node {
        if directory == AT_FDCWD {
            guard name == Array(Self.rootPath.utf8) else { throw .noSuchFileOrDirectory }
            return root
        }
        guard let parent = open[directory] else { throw .badFileDescriptor }
        if name == [0x2E, 0x2E] {
            guard let up = parent.parentOverride ?? parent.parent else { throw .noSuchFileOrDirectory }
            return up
        }
        guard let child = parent.children[name] else { throw .noSuchFileOrDirectory }
        return child
    }

    private func status(of node: Node) -> stat {
        var status = stat()
        switch node.kind {
        case .directory: status.st_mode = S_IFDIR | 0o755
        case .link(let target):
            status.st_mode = S_IFLNK | 0o755
            status.st_size = off_t(target.count)
        case .fifo: status.st_mode = S_IFIFO | 0o644
        }
        status.st_dev = 7
        status.st_ino = node.inode
        status.st_mtimespec = timespec(tv_sec: 1_700_000_000, tv_nsec: 0)
        status.st_birthtimespec = timespec(tv_sec: 1_600_000_000, tv_nsec: 0)
        return status
    }

    private func hand(_ node: Node) -> Int32 {
        nextDescriptor += 1
        open[nextDescriptor] = node
        mostOpen = max(mostOpen, open.count)
        return nextDescriptor
    }

    func status(of name: [UInt8], in directory: Int32) throws(Errno) -> stat {
        status(of: try node(name, in: directory))
    }

    func status(of descriptor: Int32) throws(Errno) -> stat {
        guard let node = open[descriptor] else { throw .badFileDescriptor }
        return status(of: node)
    }

    func openDirectory(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        let node = try node(name, in: directory)
        guard case .directory = node.kind else { throw .notDirectory }
        if let refusal = node.refusal { throw refusal }
        return hand(node)
    }

    func openFile(_ name: [UInt8], in directory: Int32) throws(Errno) -> Int32 {
        hand(try node(name, in: directory))
    }

    func names(in directory: Int32) throws(Errno) -> [[UInt8]] {
        guard let node = open[directory] else { throw .badFileDescriptor }
        return Array(node.children.keys)
    }

    func linkTarget(of name: [UInt8], in directory: Int32) throws(Errno) -> [UInt8] {
        guard case .link(let target) = try node(name, in: directory).kind else { throw .invalidArgument }
        return target
    }

    func read(_ descriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) throws(Errno) -> Int {
        throw .invalidArgument
    }

    func close(_ descriptor: Int32) {
        let closed = open.removeValue(forKey: descriptor)
        precondition(closed != nil, "closed descriptor \(descriptor) twice")
    }
}
