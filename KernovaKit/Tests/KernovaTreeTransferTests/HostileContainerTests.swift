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

/// Hostile containers fed through the decoder into the writer, with the kernel's containment off — the
/// property macOS 12 to 15.3 rests on — and on. Every case ends with nothing outside the destination and
/// the destination empty, and the failure names where it happened. Nothing asserted rests on a permission
/// check, so the suite means the same run as root, as the Linux CI container runs it.
@Suite("Hostile containers")
struct HostileContainerTests {
    /// A folder `r` holding `child`, its bytes, and the end.
    private static func folder(holding child: EntryHeader, content: Data = Data()) -> Data {
        var container = RawContainer()
        container.header(directory(depth: 0))
        container.file(child, content)
        container.end()
        return container.data
    }

    static let invalidNames: [[UInt8]] = [
        bytes(".."), bytes("."), bytes("/etc"), [], bytes("a/b"), [0x61, 0x00, 0x62], bytes("../outside"),
    ]

    @Test(
        "a name that is `..`, `.`, absolute, empty, or holds `/` or NUL is refused, below the root and as the item's",
        arguments: bothLayers, invalidNames)
    func invalidNamesAreRefused(kernelContainment: Bool, name: [UInt8]) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let below = try landing.land(Self.folder(holding: file(name, depth: 1, size: 0))).failure
        #expect(below == TreeWriteFailure(path: [bytes("r")], reason: .container(.invalidName)))
        try landing.expectNothingOutside()

        var root = RawContainer()
        root.header(directory(depth: 0))
        root.end()
        let atRoot = try landing.land(root.data, as: name).failure
        #expect(atRoot == TreeWriteFailure(path: [name], reason: .container(.invalidName)))
        try landing.expectNothingOutside()
    }

    @Test("a container whose root is named is refused as malformed, landing nothing", arguments: bothLayers)
    func namedRootIsRefused(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        var container = RawContainer()
        container.header(directory("r", depth: 0))
        container.end()
        let failure = try #require(try landing.land(container.data).failure)
        #expect(failure.reason == .container(.rootEntryNamed))
        #expect(failure.wireError.code == .itemContainerMalformed)
        try landing.expectNothingOutside()
    }

    @Test("a depth past the directories entered is refused", arguments: bothLayers)
    func depthJumpsAreRefused(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        var container = RawContainer()
        container.header(directory(depth: 0))
        container.header(directory("a", depth: 1))
        container.header(file("deep", depth: 3, size: 0))
        container.end()
        let failure = try landing.land(container.data).failure
        #expect(
            failure
                == TreeWriteFailure(
                    path: [bytes("r"), bytes("a")],
                    reason: .container(.depthBeyondParent(depth: 3, enteredDirectories: 2))))
        try landing.expectNothingOutside()
    }

    @Test(
        "nothing lands beneath a symlink: a directory or file taking a symlink's name fails at its creation",
        arguments: bothLayers, [false, true])
    func entriesBeneathSymlinksAreRefused(kernelContainment: Bool, asDirectory: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        var container = RawContainer()
        container.header(directory(depth: 0))
        container.header(symlinkEntry("s", depth: 1, target: landing.outsidePath))
        if asDirectory {
            container.header(directory("s", depth: 1))
            container.file(file("inside", depth: 2, size: 1), Data("x".utf8))
        } else {
            container.file(file("s", depth: 1, size: 1), Data("x".utf8))
        }
        container.end()
        let failure = try #require(try landing.land(container.data).failure)
        #expect(failure.path == [bytes("r"), bytes("s")])
        #expect(failure.code == EEXIST)
        try landing.expectNothingOutside()
    }

    /// The two entries of each duplicate shape, the second taking the first's name.
    enum Shape: String, CaseIterable, Sendable {
        case smallFileThenSmallFile, largeFileThenLargeFile, smallFileThenLargeFile, directoryThenDirectory
        case fileThenDirectory, directoryThenFile, symlinkThenDirectory, symlinkThenFile, fileThenSymlink
        case symlinkThenSymlink

        func append(to container: inout RawContainer, name: String) {
            func small() { container.file(file(name, depth: 1, size: 3), Data("abc".utf8)) }
            func large() { container.file(file(name, depth: 1, size: largeFileSize), pattern(Int(largeFileSize))) }
            func folder() {
                container.header(directory(name, depth: 1))
                container.file(file("inner", depth: 2, size: 1), Data("i".utf8))
            }
            func link() { container.header(symlinkEntry(name, depth: 1, target: "elsewhere")) }
            switch self {
            case .smallFileThenSmallFile: small(); small()
            case .largeFileThenLargeFile: large(); large()
            case .smallFileThenLargeFile: small(); large()
            case .directoryThenDirectory: folder(); folder()
            case .fileThenDirectory: small(); folder()
            case .directoryThenFile: folder(); small()
            case .symlinkThenDirectory: link(); folder()
            case .symlinkThenFile: link(); small()
            case .fileThenSymlink: small(); link()
            case .symlinkThenSymlink: link(); link()
            }
        }
    }

    @Test("a name taken twice fails at the second creation with EEXIST", arguments: bothLayers, Shape.allCases)
    func duplicatesFailAtCreation(kernelContainment: Bool, shape: Shape) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        var container = RawContainer()
        container.header(directory(depth: 0))
        container.file(file("before", depth: 1, size: 1), Data("b".utf8))
        shape.append(to: &container, name: "twice")
        container.file(file("after", depth: 1, size: 1), Data("a".utf8))
        container.end()
        let failure = try #require(try landing.land(container.data).failure)
        #expect(failure == TreeWriteFailure(path: [bytes("r"), bytes("twice")], reason: .system(.init(code: EEXIST))))
        try landing.expectNothingOutside()
    }

    /// Whether the volume under `landing` takes `second` for the name `first` already has.
    private static func volumeFolds(_ first: [UInt8], _ second: [UInt8], in landing: Landing) throws -> Bool {
        let probe = try landing.openDestination()
        defer { landing.fileSystem.close(probe) }
        try landing.fileSystem.makeDirectory(first, in: probe)
        defer { try? landing.fileSystem.remove(first, in: probe, isDirectory: true) }
        return (try? landing.fileSystem.status(of: second, in: probe)) != nil
    }

    static let foldedPairs: [(String, [UInt8], [UInt8])] = [
        ("NFC then NFD", [0xC3, 0xA9], [0x65, 0xCC, 0x81]),
        ("case", bytes("Report"), bytes("REPORT")),
    ]

    @Test(
        "names the volume folds together — NFC and NFD, case on APFS — fail at the second creation",
        arguments: bothLayers, foldedPairs.indices)
    func foldedNamesCollide(kernelContainment: Bool, pair: Int) throws {
        let (_, first, second) = Self.foldedPairs[pair]
        let landing = try Landing(kernelContainment: kernelContainment)
        let folds = try Self.volumeFolds(first, second, in: landing)
        var container = RawContainer()
        container.header(directory(depth: 0))
        container.file(file(first, depth: 1, size: 1), Data("1".utf8))
        container.file(file(second, depth: 1, size: 1), Data("2".utf8))
        container.end()
        let result = try landing.land(container.data)
        if folds {
            #expect(
                result.failure == TreeWriteFailure(path: [bytes("r"), second], reason: .system(.init(code: EEXIST))))
            try landing.expectNothingOutside()
        } else {
            #expect(try result.get() == bytes("r"))
            #expect(try landing.landedEntries(bytes("r")).count == 3)
        }
        #if canImport(Darwin)
        // The scratch directory is on the boot volume, which APFS formats case-insensitive.
        #expect(folds)
        #endif
    }

    @Test("a header, chunk or LZ4 chunk over its record ceiling is refused from its prefix", arguments: bothLayers)
    func oversizeRecordsAreRefused(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        for (kind, length) in [
            (ContainerRecordKind.header, ContainerRecord.maxHeaderPayload + 1),
            (.chunk, ContainerRecord.maxChunkPayload + 1),
        ] {
            var container = RawContainer()
            container.header(directory(depth: 0))
            container.header(file("f", depth: 1, size: 1 << 21))
            var prefix = Data([kind.rawValue])
            prefix.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: length >> ($0 * 8)) })
            let failure = try landing.land(container.data + prefix).failure
            #expect(
                failure
                    == TreeWriteFailure(
                        path: [bytes("r"), bytes("f")],
                        reason: .container(.recordLengthOutOfRange(kind: kind, length: length))))
            try landing.expectNothingOutside()
        }

        var lz4 = RawContainer()
        lz4.header(directory(depth: 0))
        var header = file("f", depth: 1, size: 1 << 21)
        header.lz4.size = 1 << 21
        lz4.header(header)
        let declared = ContainerRecord.maxChunkPayload + 1
        lz4.record(.lz4Chunk, Data((0..<4).map { UInt8(truncatingIfNeeded: declared >> ($0 * 8)) }) + Data([0]))
        let failure = try landing.land(lz4.data).failure
        #expect(
            failure
                == TreeWriteFailure(
                    path: [bytes("r"), bytes("f")],
                    reason: .container(
                        .lz4(.sizeOutOfRange(declared: declared, ceiling: ContainerRecord.maxChunkPayload)))))
        try landing.expectNothingOutside()
    }

    @Test(
        "sizes past the byte ceiling, alone or together, and chunks past their entry are refused", arguments: bothLayers
    )
    func oversizeSizesAreRefused(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        var alone = RawContainer()
        alone.header(directory(depth: 0))
        alone.header(file("big", depth: 1, size: 1001))
        #expect(
            try landing.land(alone.data, accepting: acceptance(ceiling: 1000)).failure
                == TreeWriteFailure(
                    path: [bytes("r")], reason: .container(.exceedsByteCeiling(declared: 1001, ceiling: 1000))))
        try landing.expectNothingOutside()

        var together = RawContainer()
        together.header(directory(depth: 0))
        together.file(file("a", depth: 1, size: 600), pattern(600))
        together.header(file("b", depth: 1, size: 401))
        #expect(
            try landing.land(together.data, accepting: acceptance(ceiling: 1000)).failure
                == TreeWriteFailure(
                    path: [bytes("r")], reason: .container(.exceedsByteCeiling(declared: 1001, ceiling: 1000))))
        try landing.expectNothingOutside()

        var forked = RawContainer()
        forked.header(directory(depth: 0))
        forked.header(withResourceFork(file("f", depth: 1, size: 600), size: 401))
        #expect(
            try landing.land(forked.data, accepting: acceptance(ceiling: 1000)).failure
                == TreeWriteFailure(
                    path: [bytes("r")], reason: .container(.exceedsByteCeiling(declared: 1001, ceiling: 1000))))
        try landing.expectNothingOutside()

        var past = RawContainer()
        past.header(directory(depth: 0))
        past.header(file("f", depth: 1, size: 2))
        past.chunk(Data("abc".utf8))
        #expect(
            try landing.land(past.data).failure
                == TreeWriteFailure(
                    path: [bytes("r"), bytes("f")], reason: .container(.chunkPastEntrySize(count: 3, remaining: 2))))
        try landing.expectNothingOutside()
    }

    /// A container of every record kind: a folder, a nested folder, small and large files, a zero run, files
    /// with resource forks, and a symlink.
    private static func everyKind() -> RawContainer {
        var container = RawContainer()
        container.header(directory(depth: 0))
        container.header(directory("nested", depth: 1))
        container.file(file("small", depth: 2, size: 5), Data("small".utf8))
        container.header(file("large", depth: 2, size: largeFileSize + 4096))
        container.chunk(pattern(Int(largeFileSize)))
        container.zeros(4096)
        container.header(withResourceFork(file("forked", depth: 2, size: 3), size: 5))
        container.chunk(Data("abc".utf8))
        container.chunk(Data("forks".utf8))
        container.header(withResourceFork(file("Icon\r", depth: 2, size: 0), size: largeFileSize))
        container.chunk(pattern(Int(largeFileSize)))
        container.header(symlinkEntry("link", depth: 1, target: "nested/small"))
        container.end()
        return container
    }

    @Test("a CRC mismatch in any record is refused", arguments: bothLayers)
    func checksumMismatchesAreRefused(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let container = Self.everyKind()
        for (start, end) in zip(container.boundaries, container.boundaries.dropFirst()) {
            var flipped = container.data
            flipped[end - 1] ^= 0x01
            let failure = try #require(try landing.land(flipped).failure)
            guard case .container(.checksumMismatch(let kind)) = failure.reason else {
                Issue.record("record at \(start): \(failure)")
                continue
            }
            #expect(kind.rawValue == container.data[start])
            try landing.expectNothingOutside()
        }
        #expect(try landing.land(container.data).get() == bytes("r"))
    }

    @Test("a container cut at any record boundary lands nothing", arguments: bothLayers)
    func truncationLandsNothing(kernelContainment: Bool) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        let container = Self.everyKind()
        for boundary in container.boundaries.dropLast() {
            let failure = try landing.land(container.data.prefix(boundary)).failure
            #expect(failure?.reason == .container(.truncated), "cut at \(boundary)")
            try landing.expectNothingOutside()
        }
        let landed = try landing.land(container.data, pieceSize: 7).get()
        #expect(
            try landing.landedEntries(landed)
                == [
                    "./link: symlink -> nested/small", "./nested/large: regular \(largeFileSize + 4096)",
                    "./nested/small: regular 5", "./nested/forked: regular 3", "./nested/Icon%d: regular 0",
                    ".: directory", "./nested: directory",
                ].sorted())
    }

    @Test(
        "an entry typed as a FIFO, a device, a socket or anything unknown is refused, and no node is made",
        arguments: bothLayers, [5, 6, 7, 99])
    func specialNodesAreRefused(kernelContainment: Bool, type: Int) throws {
        let landing = try Landing(kernelContainment: kernelContainment)
        var node = file("node", depth: 1, size: 0)
        node.type = .UNRECOGNIZED(type)
        node.storage = nil
        var container = RawContainer()
        container.header(directory(depth: 0))
        container.header(node)
        container.end()
        #expect(
            try landing.land(container.data).failure
                == TreeWriteFailure(path: [bytes("r")], reason: .container(.unknownEntryType)))
        try landing.expectNothingOutside()
    }

    @Test("an item whose name the destination already holds is refused at publishing, and the other kept")
    func publishingNeverReplaces() throws {
        let landing = try Landing(kernelContainment: true)
        try #require(mkdir(landing.destinationPath + "/r", 0o755) == 0)
        var container = RawContainer()
        container.header(directory(depth: 0))
        container.file(file("f", depth: 1, size: 1), Data("f".utf8))
        container.end()
        #expect(
            try landing.land(container.data).failure
                == TreeWriteFailure(path: [bytes("r")], reason: .system(.init(code: EEXIST))))
        #expect(
            try landing.entriesOutside()
                == [
                    "/destination: directory", "/destination/r: directory", "/outside: directory",
                    "/outside/sentinel: regular 0",
                ].sorted())
    }
}
#endif
