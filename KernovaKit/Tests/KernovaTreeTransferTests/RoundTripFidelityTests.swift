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
import KernovaWire
import Testing

@testable import KernovaTreeTransfer

/// Reader → encoder → decoder → writer on a generated tree, compared entry by entry with what it was read
/// from: the receiver-writer parity note's method (docs/research/2026-10-24-receiver-writer-parity.md) as a
/// test.
@Suite("Round-trip fidelity")
struct RoundTripFidelityTests {
    static let lz4Always = ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil)

    /// What the generated tree holds that a comparison of two trees alone could pass without.
    struct Expected {
        /// Entries given each carried extended attribute, which the landed tree must hold.
        var xattrs: [([[UInt8]], String, [UInt8])] = []
        /// An extended attribute the format does not carry, on its entry.
        var uncarriedXattr: ([[UInt8]], String)?
        /// Entries given flags, with the flags given.
        var flags: [([[UInt8]], UInt32)] = []
        /// Files with holes.
        var sparse: [[[UInt8]]] = []
        /// A file whose zeros are stored, not holes.
        var storedZeros: [[UInt8]] = []
    }

    static let item = bytes("item")

    /// Builds the item: every entry type, modes, times, flags and carried and uncarried extended attributes,
    /// deep nesting, more siblings than one folder batch takes, empty files and directories, files on each
    /// side of the batch and chunk sizes, sparse files with holes smaller than a chunk, and on Linux a name
    /// that is not UTF-8.
    static func buildTree(on bench: FidelityBench) throws -> Expected {
        var expected = Expected()
        var created: [[[UInt8]]] = []
        var symlinks: Set<[[UInt8]]> = []
        let root = [item]
        func at(_ names: String...) -> [[UInt8]] { root + names.map(bytes) }
        func directory(_ components: [[UInt8]]) throws {
            try bench.makeDirectory(components)
            created.append(components)
        }
        func file(_ components: [[UInt8]], _ content: Data) throws {
            try bench.makeFile(components, content)
            created.append(components)
        }
        func link(_ components: [[UInt8]], _ target: String) throws {
            try bench.makeSymlink(components, to: bytes(target))
            created.append(components)
            symlinks.insert(components)
        }

        try directory(root)
        try file(at("empty-file"), Data())
        try directory(at("empty-dir"))
        try file(at("one"), Data([0x2A]))
        let chunk = ContainerEncoder.chunkByteCount
        try file(at("chunk"), randomBytes(chunk, seed: 1))
        try file(at("chunk-plus-one"), randomBytes(chunk + 1, seed: 2))
        try file(at("large"), randomBytes(1 << 20 + 17, seed: 3))
        try file(at("text"), Data(String(repeating: "a tree crosses the boundary. ", count: 15_000).utf8))
        try file(at("read-only"), Data("sealed".utf8))
        try file(at("café"), Data("unicode".utf8))
        try directory(at("sealed"))
        try file(at("sealed", "inside"), Data("held".utf8))

        try directory(at("many"))
        for index in 0..<300 {
            let name = "f" + String(index + 1000).dropFirst()
            try file(at("many", name), index % 50 == 0 ? Data() : randomBytes(index % 97 + 1, seed: UInt64(index)))
        }

        var deep = at("deep")
        try directory(deep)
        for level in 0..<40 {
            deep.append(bytes("d\(level)"))
            try directory(deep)
        }
        try file(deep + [bytes("leaf")], Data("bottom".utf8))

        // Holes at 64 KiB alignment, a multiple of every volume's hole size; the small file's lie inside one
        // chunk, which the encoder's own zero scan never makes a run of.
        let large = at("sparse-large")
        let largeSize = 2 << 20
        var largeContent = Data(count: largeSize)
        largeContent.replaceSubrange(0..<(64 << 10), with: randomBytes(64 << 10, seed: 4))
        largeContent.replaceSubrange((1 << 20)..<((1 << 20) + (64 << 10)), with: randomBytes(64 << 10, seed: 5))
        try file(large, largeContent)
        try bench.punchHoles(
            large, [Int64(64 << 10)..<Int64(1 << 20), Int64((1 << 20) + (64 << 10))..<Int64(largeSize)])
        let small = at("sparse-small")
        var smallContent = Data(count: 192 << 10)
        smallContent.replaceSubrange(0..<(16 << 10), with: randomBytes(16 << 10, seed: 6))
        smallContent.replaceSubrange((176 << 10)..<(192 << 10), with: randomBytes(16 << 10, seed: 7))
        try file(small, smallContent)
        try bench.punchHoles(small, [Int64(64 << 10)..<Int64(128 << 10)])
        expected.sparse = [large, small]
        try file(at("stored-zeros"), Data(count: 300 << 10))
        expected.storedZeros = at("stored-zeros")

        try link(at("link-relative"), "one")
        try link(at("link-absolute"), "/nonexistent/absolute/target")
        try link(at("link-directory"), "deep/d0")
        try link(at("deep", "d0", "link-up"), "../../one")

        #if os(Linux)
        try file(root + [[0x6E, 0xFF, 0xFE]], Data("not UTF-8".utf8))
        let note = (at("one"), "user.kernova.note", bytes("a note"))
        let folderNote = (at("deep"), "user.kernova.folder", bytes("on a directory"))
        let empty = (at("chunk"), "user.kernova.empty", [UInt8]())
        for (components, name, value) in [note, folderNote, empty] {
            try bench.setExtendedAttribute(components, name, value)
            expected.xattrs.append((components, name, value))
        }
        #elseif canImport(Darwin)
        let tags = "com.apple.metadata:_kMDItemUserTags"
        let tagValue = bytes("bplist00\u{A1}\u{01}SRed\u{0A}6")
        for components in [at("one"), at("deep")] {
            try bench.setExtendedAttribute(components, tags, tagValue)
            expected.xattrs.append((components, tags, tagValue))
        }
        try bench.setExtendedAttribute(at("link-relative"), tags, tagValue, symlink: true)
        expected.xattrs.append((at("link-relative"), tags, tagValue))
        let fork = Array(randomBytes(4096, seed: 8))
        try bench.setExtendedAttribute(at("chunk"), "com.apple.ResourceFork", fork)
        expected.xattrs.append((at("chunk"), "com.apple.ResourceFork", fork))
        try bench.setExtendedAttribute(at("one"), "com.example.private", bytes("stays home"))
        expected.uncarriedXattr = (at("one"), "com.example.private")
        // `UF_TRACKED` (0x40) is not carried; it rides along to show the mask.
        expected.flags = [
            (at("one"), 0x8000), (at("deep"), 0x8000), (at("chunk"), 0x1), (at("text"), 0x8000 | 0x40),
            (at("link-relative"), 0x8000),
        ]
        for (components, flags) in expected.flags { try bench.setFlags(components, flags) }
        #endif

        // Modes, then times children first: a time lands last, since creating an entry changes its
        // directory's, and on Darwin an earlier modification time pulls the birth time back to it.
        let modes: [[[UInt8]]: UInt32] = [
            at("one"): 0o600, at("large"): 0o640, at("read-only"): 0o444, at("empty-dir"): 0o700,
            at("sealed"): 0o555, at("text"): 0o755, root: 0o750,
        ]
        for (index, components) in created.enumerated().reversed() {
            if let mode = modes[components] { try bench.setMode(components, mode) }
            let time = FileTime(seconds: 1_600_000_000 + Int64(index) * 37, nanoseconds: Int64(index) * 1_001 + 7)
            try bench.setModificationTime(components, time)
            #if canImport(Darwin)
            if index % 2 == 0 {
                try bench.setBirthTime(components, FileTime(seconds: time.seconds - 86_400, nanoseconds: 3))
            }
            #endif
        }
        return expected
    }

    @Test("a generated tree lands entry for entry as it was read", arguments: [false, true])
    func folderRoundTrip(lz4: Bool) throws {
        let bench = try FidelityBench()
        let expected = try Self.buildTree(on: bench)
        let acceptance = ContainerAcceptance(storage: .folder, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: lz4)
        let landed = try bench.roundTrip(Self.item, accepting: acceptance, policy: lz4 ? Self.lz4Always : .never)
        #expect(landed == Self.item)

        let source = try bench.facts(of: Self.item, in: bench.sourcePath)
        let destination = try bench.facts(of: Self.item, in: bench.destinationPath)
        try Self.compare(source: source, destination: destination, expected: expected)
    }

    @Test("a sparse FILE item lands with its holes where they were")
    func sparseFileRoundTrip() throws {
        let bench = try FidelityBench()
        let name = bytes("disk.img")
        let size = 2 << 20
        var content = Data(count: size)
        content.replaceSubrange((1 << 20)..<((1 << 20) + 4096), with: randomBytes(4096, seed: 9))
        try bench.makeFile([name], content)
        try bench.punchHoles([name], [0..<Int64(1 << 20), Int64((1 << 20) + 65536)..<Int64(size)])
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)
        #expect(try bench.roundTrip(name, accepting: acceptance, policy: .never) == name)
        var source = try #require(try bench.facts(of: name, in: bench.sourcePath)[[name]])
        var landed = try #require(try bench.facts(of: name, in: bench.destinationPath)[[name]])
        try #require(source.blocks * 512 < Int64(size) / 4, "the source is sparse")
        #expect(landed.blocks == source.blocks - source.storedZeroBlocks)
        // Names the format does not carry, such as an OS's own provenance attribute, are not compared, and
        // the blocks are compared above.
        source.xattrNames = []
        landed.xattrNames = []
        source.blocks = landed.blocks
        source.storedZeroBlocks = landed.storedZeroBlocks
        #expect(landed == source)
    }

    @Test("the reader says each hole exactly, as zeros beside the stored bytes")
    func holesAsEvents() throws {
        let bench = try FidelityBench()
        let name = bytes("holes")
        var content = Data(count: 256 << 10)
        content.replaceSubrange(0..<(16 << 10), with: randomBytes(16 << 10, seed: 10))
        content.replaceSubrange((80 << 10)..<(96 << 10), with: randomBytes(16 << 10, seed: 11))
        try bench.makeFile([name], content)
        try bench.punchHoles([name], [Int64(16 << 10)..<Int64(80 << 10), Int64(96 << 10)..<Int64(256 << 10)])
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: 1 << 30, decmpfsTypes: [], acceptsLZ4: false)
        let events = try bench.events(name, accepting: acceptance)
        let pieces = events.compactMap { event -> String? in
            switch event {
            case .bytes(let bytes): "bytes \(bytes.count)"
            case .zeros(let count): "zeros \(count)"
            default: nil
            }
        }
        #expect(pieces == ["bytes \(16 << 10)", "zeros \(64 << 10)", "bytes \(16 << 10)", "zeros \(160 << 10)"])
        #expect(events.first.map { if case .beginFile = $0 { true } else { false } } == true)
        #expect(events.suffix(2) == [.finishFile, .end])
    }

    // MARK: - Comparing

    static func compare(
        source: [[[UInt8]]: FidelityBench.Facts], destination: [[[UInt8]]: FidelityBench.Facts], expected: Expected
    ) throws {
        #expect(Set(destination.keys) == Set(source.keys), "the same entries")
        try #require(source.count > 360, "the tree was generated")
        for (components, read) in source {
            let where_ = components.map(Landing.display).joined(separator: "/")
            guard let landed = destination[components] else { continue }
            #expect(landed.kind == read.kind, "type of \(where_)")
            #expect(landed.permissions == read.permissions, "mode of \(where_)")
            #expect(landed.flags == read.flags & ValidatedEntry.allowedDarwinFlags, "flags of \(where_)")
            #expect(landed.modificationTime == read.modificationTime, "mtime of \(where_)")
            #expect(landed.birthTime == read.birthTime, "birth time of \(where_)")
            #expect(landed.size == read.size, "size of \(where_)")
            #expect(landed.linkTarget == read.linkTarget, "symlink target of \(where_)")
            #expect(landed.carriedXattrs == read.carriedXattrs, "xattrs of \(where_)")
            #expect(landed.digest == read.digest, "SHA-256 of \(where_)")
            // The writer leaves every whole all-zero block a hole, whether the source stored it or not.
            #expect(landed.blocks == read.blocks - read.storedZeroBlocks, "st_blocks of \(where_)")
        }
        for (components, name, value) in expected.xattrs {
            #expect(destination[components]?.carriedXattrs[bytes(name)] == value, "\(name) landed on \(components)")
        }
        if let (components, name) = expected.uncarriedXattr {
            try #require(source[components]?.xattrNames.contains(bytes(name)) == true)
            #expect(destination[components]?.xattrNames.contains(bytes(name)) == false, "\(name) stayed home")
        }
        for (components, flags) in expected.flags {
            try #require(source[components]?.flags == flags, "flags given to \(components)")
            #expect(destination[components]?.flags == flags & ValidatedEntry.allowedDarwinFlags)
        }
        for components in expected.sparse {
            let read = try #require(source[components])
            try #require(read.blocks * 512 < read.size, "\(components) is sparse in the source")
        }
        let stored = try #require(source[expected.storedZeros])
        try #require(stored.storedZeroBlocks > 0, "the source stores its zeros")
        #if canImport(Darwin)
        #expect(source.values.allSatisfy { $0.birthTime != nil }, "the source keeps birth times")
        #endif
    }
}
#endif
