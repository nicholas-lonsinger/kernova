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
import KernovaDigest
import KernovaFileTree
import KernovaPortableTestSupport
import KernovaWire
import Testing

@testable import KernovaTreeTransfer

/// A source directory to build items in and a destination to land them in, both under one scratch directory.
final class FidelityBench {
    let scratch: PortableScratchDirectory
    let fileSystem = POSIXTreeFileSystem()

    var sourcePath: String { scratch.path + "/source" }
    var destinationPath: String { scratch.path + "/destination" }

    init() throws {
        scratch = try PortableScratchDirectory(prefix: "tree-fidelity")
        try #require(mkdir(sourcePath, 0o755) == 0)
        try #require(mkdir(destinationPath, 0o755) == 0)
    }

    deinit {
        // Both trees may hold directories their owner cannot write, which the scratch directory's own removal
        // cannot empty.
        if let top = try? fileSystem.openDirectory(bytes(scratch.path), in: AT_FDCWD) {
            for name in (try? fileSystem.names(in: top)) ?? [] {
                try? TreeRemoval.remove(name, in: top, on: fileSystem)
            }
            fileSystem.close(top)
        }
    }

    // MARK: - Building the source

    /// The source path of the entry whose components below the source directory are `components`.
    func path(_ components: [[UInt8]]) -> [UInt8] {
        bytes(sourcePath) + components.flatMap { [0x2F] + $0 }
    }

    func makeDirectory(_ components: [[UInt8]]) throws {
        try #require(withPath(path(components)) { mkdir($0, 0o755) } == 0, "mkdir \(components)")
    }

    func makeFile(_ components: [[UInt8]], _ content: Data) throws {
        let descriptor = withPath(path(components)) { open($0, O_WRONLY | O_CREAT | O_EXCL, 0o644) }
        try #require(descriptor >= 0, "create \(components)")
        defer { close(descriptor) }
        try content.withUnsafeBytes { buffer in
            var written = 0
            while written < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + written, buffer.count - written)
                try #require(count > 0)
                written += count
            }
        }
    }

    func makeSymlink(_ components: [[UInt8]], to target: [UInt8]) throws {
        let made = withPath(target) { target in withPath(path(components)) { symlink(target, $0) } }
        try #require(made == 0, "symlink \(components)")
    }

    func punchHoles(_ components: [[UInt8]], _ ranges: [Range<Int64>]) throws {
        let descriptor = withPath(path(components)) { open($0, O_RDWR) }
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        for range in ranges {
            try fileSystem.punchHole(in: descriptor, at: range.lowerBound, length: range.upperBound - range.lowerBound)
        }
    }

    /// Sets an extended attribute through the writer's own call, on a symlink itself when `symlink`.
    func setExtendedAttribute(_ components: [[UInt8]], _ name: String, _ value: [UInt8], symlink: Bool = false)
        throws
    {
        if symlink {
            let parent = try fileSystem.openDirectory(path(Array(components.dropLast())), in: AT_FDCWD)
            defer { fileSystem.close(parent) }
            try fileSystem.setExtendedAttribute(bytes(name), to: value, of: .symlink(components.last!, in: parent))
        } else {
            let descriptor = withPath(path(components)) { open($0, O_RDONLY) }
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            try fileSystem.setExtendedAttribute(bytes(name), to: value, of: .descriptor(descriptor))
        }
    }

    func setMode(_ components: [[UInt8]], _ mode: UInt32) throws {
        try #require(withPath(path(components)) { chmod($0, mode_t(mode)) } == 0)
    }

    func setModificationTime(_ components: [[UInt8]], _ time: FileTime) throws {
        let times = [timespec(time), timespec(time)]
        try #require(withPath(path(components)) { utimensat(AT_FDCWD, $0, times, AT_SYMLINK_NOFOLLOW) } == 0)
    }

    #if canImport(Darwin)
    func setFlags(_ components: [[UInt8]], _ flags: UInt32) throws {
        try #require(withPath(path(components)) { lchflags($0, flags) } == 0)
    }

    func setBirthTime(_ components: [[UInt8]], _ time: FileTime) throws {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var value = timespec(time)
        let set = withPath(path(components)) {
            setattrlist($0, &list, &value, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW))
        }
        try #require(set == 0)
    }
    #endif

    // MARK: - Moving it

    /// Reads the item `name` in the source through a ``TreeReader``, encodes its events, decodes the container
    /// and lands it in the destination, returning the landed name.
    func roundTrip(_ name: [UInt8], accepting acceptance: ContainerAcceptance, policy: ChunkCompressionPolicy)
        throws -> [UInt8]
    {
        let parent = try fileSystem.openDirectory(bytes(sourcePath), in: AT_FDCWD)
        defer { fileSystem.close(parent) }
        let reader = try TreeReader(fileSystem: fileSystem, item: name, in: parent, accepting: acceptance)
        var encoder = ContainerEncoder(accepting: acceptance, policy: policy)
        let receiver = TreeReceiver(
            accepting: acceptance, fileSystem: fileSystem,
            destination: try fileSystem.openDirectory(bytes(destinationPath), in: AT_FDCWD),
            destinationPathByteCount: destinationPath.utf8.count)
        while let event = try reader.next() {
            try receiver.receive(try encoder.encode(event))
        }
        return try receiver.finish()
    }

    /// Every event the reader produces for the item `name` in the source.
    func events(_ name: [UInt8], accepting acceptance: ContainerAcceptance) throws -> [TreeEvent] {
        let parent = try fileSystem.openDirectory(bytes(sourcePath), in: AT_FDCWD)
        defer { fileSystem.close(parent) }
        let reader = try TreeReader(fileSystem: fileSystem, item: name, in: parent, accepting: acceptance)
        var events: [TreeEvent] = []
        while let event = try reader.next() { events.append(event) }
        return events
    }

    // MARK: - Comparing

    /// What the suite compares of each entry.
    struct Facts: Equatable {
        var kind: FileKind
        var permissions: UInt32
        var flags: UInt32
        var modificationTime: FileTime
        var birthTime: FileTime?
        var size: Int64
        var linkTarget: [UInt8]?
        /// The extended attributes the format carries.
        var carriedXattrs: [[UInt8]: [UInt8]]
        /// Every extended attribute name.
        var xattrNames: Set<[UInt8]>
        /// 512-byte blocks allocated, `st_blocks`.
        var blocks: Int64
        /// The 512-byte blocks of the whole hole-sized blocks the file stores that hold only zeros.
        var storedZeroBlocks: Int64 = 0
        var digest: [UInt8]?
    }

    /// The facts of the item `name` in the directory at `directoryPath` and of everything in it, keyed by
    /// each entry's components below that directory.
    func facts(of name: [UInt8], in directoryPath: String) throws -> [[[UInt8]]: Facts] {
        let top = try fileSystem.openDirectory(bytes(directoryPath), in: AT_FDCWD)
        defer { fileSystem.close(top) }
        var found: [[[UInt8]]: Facts] = [:]
        try collect(name, in: top, components: [], into: &found)
        return found
    }

    private func collect(
        _ name: [UInt8], in directory: Int32, components: [[UInt8]], into found: inout [[[UInt8]]: Facts]
    ) throws {
        let here = components + [name]
        let status = try fileSystem.status(of: name, in: directory)
        var raw = stat()
        try #require(withPath(name) { fstatat(directory, $0, &raw, AT_SYMLINK_NOFOLLOW) } == 0)
        var facts = Facts(
            kind: status.kind, permissions: status.permissions, flags: status.flags,
            modificationTime: status.modificationTime, birthTime: status.birthTime,
            size: status.kind == .regular ? status.size : 0, linkTarget: nil, carriedXattrs: [:], xattrNames: [],
            blocks: status.kind == .regular ? Int64(raw.st_blocks) : 0, digest: nil)
        func readXattrs(_ target: TreeEntryTarget) throws {
            for attribute in try fileSystem.extendedAttributeNames(of: target) {
                facts.xattrNames.insert(attribute)
                guard ValidatedEntry.isAllowedXattrName(Data(attribute)) else { continue }
                facts.carriedXattrs[attribute] = try fileSystem.extendedAttribute(
                    attribute, of: target, maxByteCount: 1 << 20)
            }
        }
        switch status.kind {
        case .regular:
            let descriptor = try fileSystem.openFile(name, in: directory)
            defer { fileSystem.close(descriptor) }
            try readXattrs(.descriptor(descriptor))
            var content = [UInt8](repeating: 0, count: Int(status.size))
            var offset = 0
            while offset < content.count {
                let count = try content.withUnsafeMutableBytes { buffer in
                    try fileSystem.read(descriptor, into: UnsafeMutableRawBufferPointer(rebasing: buffer[offset...]))
                }
                try #require(count > 0)
                offset += count
            }
            facts.digest = SHA256.hash(content)
            if let holeSize = fileSystem.holeSize(of: descriptor) {
                var start: Int64 = 0
                while let run = try fileSystem.dataRun(in: descriptor, from: start) {
                    let whole = stride(from: Int(run.lowerBound), to: Int(run.upperBound), by: holeSize).filter {
                        $0 + holeSize <= content.count && !content[$0..<($0 + holeSize)].contains { $0 != 0 }
                    }
                    facts.storedZeroBlocks += Int64(whole.count * holeSize / 512)
                    start = run.upperBound
                }
            }
        case .directory:
            let descriptor = try fileSystem.openDirectory(name, in: directory)
            defer { fileSystem.close(descriptor) }
            try readXattrs(.descriptor(descriptor))
            for child in try fileSystem.names(in: descriptor) {
                try collect(child, in: descriptor, components: here, into: &found)
            }
        case .symbolicLink:
            facts.linkTarget = try fileSystem.linkTarget(of: name, in: directory)
            try readXattrs(.symlink(name, in: directory))
        default:
            break
        }
        found[here] = facts
    }
}

func withPath<Result>(_ path: [UInt8], _ body: (UnsafePointer<CChar>) -> Result) -> Result {
    let cString = path.map { CChar(bitPattern: $0) } + [0]
    return cString.withUnsafeBufferPointer { body($0.baseAddress!) }
}

extension timespec {
    init(_ time: FileTime) {
        self.init(tv_sec: Int(time.seconds), tv_nsec: Int(time.nanoseconds))
    }
}

/// `count` bytes of a seeded random sequence.
func randomBytes(_ count: Int, seed: UInt64) -> Data {
    var generator = SplitMix64(seed: seed)
    return generator.bytes(count)
}
#endif
