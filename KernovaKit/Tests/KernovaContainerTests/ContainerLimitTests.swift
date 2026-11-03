#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaPortableTestSupport
import KernovaWire
import Testing

/// Each limit at its edge, which decodes, and one past it, which is refused with the error naming it.
@Suite("Container limits")
struct ContainerLimitTests {
    /// A single-file container whose header is `header`, carrying `bytes`.
    static func single(_ header: EntryHeader, bytes: Data = Data()) -> Data {
        var container = headerRecord(header)
        if !bytes.isEmpty { container += record(.chunk, bytes) }
        return container + endRecord(entries: 1, bytes: UInt64(bytes.count))
    }

    /// A folder container holding `header` at depth 1, carrying `bytes`.
    static func inFolder(_ header: EntryHeader, bytes: Data = Data()) -> Data {
        var entry = header
        entry.depth = 1
        var container = headerRecord(directory("root", depth: 0)) + headerRecord(entry)
        if !bytes.isEmpty { container += record(.chunk, bytes) }
        return container + endRecord(entries: 2, bytes: UInt64(bytes.count))
    }

    // MARK: Record sizes

    /// A FILE header padded with an extended attribute to serialize to exactly `byteCount` bytes.
    static func header(serializingTo byteCount: Int) -> EntryHeader {
        var header = plainFile("f", depth: 0, size: 0)
        var xattr = Kernova_V2_Xattr()
        xattr.name = name("user.pad")
        header.xattrs = [xattr]
        var padding = byteCount - serialized(header).count
        while true {
            header.xattrs[0].value = Data(count: max(0, padding))
            let size = serialized(header).count
            if size == byteCount { return header }
            padding += byteCount - size
        }
    }

    @Test("A header payload of 64 KiB decodes; one byte more is refused")
    func headerSize() throws {
        let edge = Self.header(serializingTo: ContainerRecord.maxHeaderPayload)
        #expect(serialized(edge).count == 65_536)
        #expect(decodingError(Self.single(edge)) == nil)
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try encoder.entry(edge)

        let past = Self.header(serializingTo: ContainerRecord.maxHeaderPayload + 1)
        let pastRecord = rawRecord(kind: ContainerRecordKind.header.rawValue, payload: serialized(past))
        #expect(decodingError(pastRecord) == .recordLengthOutOfRange(kind: .header, length: 65_537))
        var refusing = ContainerEncoder(accepting: generous(), policy: .never)
        #expect(throws: ContainerError.recordLengthOutOfRange(kind: .header, length: 65_537)) {
            try refusing.entry(past)
        }
    }

    @Test("A chunk payload of 1 MiB decodes; one byte more is refused")
    func chunkSize() {
        let edge = ContainerRecord.maxChunkPayload
        #expect(edge == 1_048_576)
        #expect(
            decodingError(Self.single(plainFile("f", depth: 0, size: UInt64(edge)), bytes: Data(count: edge))) == nil)
        let past =
            headerRecord(plainFile("f", depth: 0, size: UInt64(edge + 1)))
            + rawRecord(kind: ContainerRecordKind.chunk.rawValue, payload: Data(count: edge + 1))
        #expect(decodingError(past) == .recordLengthOutOfRange(kind: .chunk, length: edge + 1))
    }

    @Test("An LZ4 chunk decompressing to 1 MiB decodes; declaring one byte more is refused")
    func lz4DecompressedSize() throws {
        let edge = ContainerRecord.maxChunkPayload
        let block = try #require(LZ4Block.compress(Data(count: edge)))
        let edgeContainer =
            headerRecord(lz4File("l", depth: 0, size: UInt64(edge)))
            + lz4ChunkRecord(declaredSize: UInt32(edge), block: block) + endRecord(entries: 1, bytes: UInt64(edge))
        #expect(decodingError(edgeContainer) == nil)

        let pastBlock = try #require(LZ4Block.compress(Data(count: edge + 1)))
        let past =
            headerRecord(lz4File("l", depth: 0, size: UInt64(edge + 1)))
            + lz4ChunkRecord(declaredSize: UInt32(edge + 1), block: pastBlock)
        #expect(decodingError(past) == .lz4(.sizeOutOfRange(declared: edge + 1, ceiling: edge)))
    }

    @Test("A zero run's payload is exactly 8 bytes")
    func zeroRunLength() {
        let header = headerRecord(plainFile("f", depth: 0, size: 100))
        for length in [0, 7, 9] {
            let container = header + rawRecord(kind: ContainerRecordKind.zeroRun.rawValue, payload: Data(count: length))
            #expect(decodingError(container) == .recordLengthOutOfRange(kind: .zeroRun, length: length))
        }
    }

    @Test("An LZ4 chunk's payload holds its size and at least one block byte")
    func lz4ChunkMinimum() {
        let header = headerRecord(lz4File("l", depth: 0, size: 100))
        let short = header + rawRecord(kind: ContainerRecordKind.lz4Chunk.rawValue, payload: littleEndian(UInt32(1)))
        #expect(decodingError(short) == .recordLengthOutOfRange(kind: .lz4Chunk, length: 4))
    }

    @Test("Unknown record kinds are refused", arguments: [UInt8(0), 6, 0xFF])
    func unknownKind(kind: UInt8) {
        #expect(decodingError(rawRecord(kind: kind, payload: Data())) == .unknownRecordKind(kind))
    }

    // MARK: Byte ceiling

    @Test("The byte ceiling counts every entry: a total at it decodes, one byte more is refused at the header")
    func byteCeiling() throws {
        let acceptance = ContainerAcceptance(storage: .folder, byteCeiling: 300, decmpfsTypes: [], acceptsLZ4: false)
        func container(secondSize: UInt64) -> Data {
            headerRecord(directory("d", depth: 0))
                + headerRecord(plainFile("a", depth: 1, size: 200)) + zeroRunRecord(200)
                + headerRecord(plainFile("b", depth: 1, size: secondSize)) + zeroRunRecord(secondSize)
                + endRecord(entries: 3, bytes: 200 + secondSize)
        }
        #expect(decodingError(container(secondSize: 100), accepting: acceptance) == nil)
        let refused = decodingError(container(secondSize: 101), accepting: acceptance)
        #expect(refused == .exceedsByteCeiling(declared: 301, ceiling: 300))
        #expect(refused?.errorCode == .tooLarge)

        var encoder = ContainerEncoder(accepting: acceptance, policy: .never)
        _ = try encoder.entry(directory("d", depth: 0))
        _ = try encoder.entry(plainFile("a", depth: 1, size: 200))
        _ = try encoder.bytes(Data(count: 200))
        #expect(throws: ContainerError.exceedsByteCeiling(declared: 301, ceiling: 300)) {
            try encoder.entry(plainFile("b", depth: 1, size: 101))
        }
    }

    @Test("A pull's acceptance comes from its PullRequest")
    func acceptanceFromPull() {
        var pull = PullRequest()
        pull.byteCeiling = 12
        pull.decmpfsTypes = [3, 4]
        pull.codecs = [.lz4]
        #expect(
            ContainerAcceptance(pull, storage: .file)
                == ContainerAcceptance(storage: .file, byteCeiling: 12, decmpfsTypes: [3, 4], acceptsLZ4: true))
        #expect(!ContainerAcceptance(PullRequest(), storage: .inline).acceptsLZ4)
    }

    // MARK: Counts

    @Test("The end record's counts must match: entries and bytes, each off by one")
    func endCounts() {
        let body = headerRecord(plainFile("f", depth: 0, size: 3)) + record(.chunk, Data("abc".utf8))
        #expect(decodingError(body + endRecord(entries: 1, bytes: 3)) == nil)
        let counted = ContainerError.Counts(entries: 1, bytes: 3)
        for (entries, bytes) in [(UInt64(0), UInt64(3)), (2, 3), (1, 2), (1, 4)] {
            #expect(
                decodingError(body + endRecord(entries: entries, bytes: bytes))
                    == .endCountsMismatch(stated: .init(entries: entries, bytes: bytes), counted: counted))
        }
    }

    @Test("A container with no entry, an end inside an entry, and bytes after the end are refused")
    func endPlacement() {
        #expect(decodingError(endRecord(entries: 0, bytes: 0)) == .noEntry)
        let open = headerRecord(plainFile("f", depth: 0, size: 3)) + record(.chunk, Data("ab".utf8))
        #expect(decodingError(open + endRecord(entries: 1, bytes: 2)) == .entryIncomplete(remaining: 1))
        let whole = Self.single(plainFile("f", depth: 0, size: 0))
        #expect(decodingError(whole + Data([0x00])) == .bytesAfterEnd)
        #expect(decodingError(whole + headerRecord(plainFile("g", depth: 0, size: 0))) == .bytesAfterEnd)
    }

    // MARK: Chunks

    @Test("Chunks fill their entry exactly: at its size it finishes, past it is refused")
    func chunkAgainstEntry() {
        let header = headerRecord(plainFile("f", depth: 0, size: 5))
        #expect(decodingError(header + zeroRunRecord(5) + endRecord(entries: 1, bytes: 5)) == nil)
        #expect(decodingError(header + zeroRunRecord(6)) == .chunkPastEntrySize(count: 6, remaining: 5))
        #expect(decodingError(header + record(.chunk, Data(count: 6))) == .chunkPastEntrySize(count: 6, remaining: 5))
        #expect(decodingError(header + zeroRunRecord(0)) == .emptyChunk)
        #expect(decodingError(record(.chunk, Data([1]))) == .chunkOutsideEntry)
        let empty = headerRecord(plainFile("e", depth: 0, size: 0))
        #expect(decodingError(empty + record(.chunk, Data([1]))) == .chunkOutsideEntry)
        let directoryRecord = headerRecord(directory("d", depth: 0))
        #expect(decodingError(directoryRecord + zeroRunRecord(1)) == .chunkOutsideEntry)
        #expect(
            decodingError(header + headerRecord(plainFile("g", depth: 0, size: 0))) == .entryIncomplete(remaining: 5))
    }

    @Test("LZ4 storage needs the pull's codec, and an LZ4 chunk needs LZ4 storage")
    func lz4Acceptance() {
        let noLZ4 = ContainerAcceptance(storage: .file, byteCeiling: 1 << 20, decmpfsTypes: [], acceptsLZ4: false)
        #expect(decodingError(Self.single(lz4File("l", depth: 0, size: 0)), accepting: noLZ4) == .lz4NotAccepted)
        let plain = headerRecord(plainFile("f", depth: 0, size: 32))
        #expect(decodingError(plain + GoldenVectorTests.lz4Chunk) == .lz4ChunkOutsideLZ4Storage)
        var encoder = ContainerEncoder(accepting: noLZ4, policy: .never)
        #expect(throws: ContainerError.lz4NotAccepted) { try encoder.entry(lz4File("l", depth: 0, size: 0)) }
    }

    @Test("A malformed LZ4 block is refused")
    func malformedBlock() {
        let container =
            headerRecord(lz4File("l", depth: 0, size: 32)) + lz4ChunkRecord(declaredSize: 32, block: Data([0x1F]))
        #expect(decodingError(container) == .lz4(.truncated))
    }

    // MARK: Structure

    @Test("Depth: at most the directories entered; the first entry at 0 and no other")
    func depth() {
        let root = headerRecord(directory("r", depth: 0))
        let atHeight = root + headerRecord(directory("a", depth: 1)) + headerRecord(plainFile("f", depth: 2, size: 0))
        #expect(decodingError(atHeight + endRecord(entries: 3, bytes: 0)) == nil)
        #expect(
            decodingError(root + headerRecord(plainFile("f", depth: 2, size: 0)))
                == .depthBeyondParent(depth: 2, enteredDirectories: 1))
        #expect(
            decodingError(
                headerRecord(plainFile("f", depth: 0, size: 0)) + headerRecord(plainFile("g", depth: 1, size: 0)))
                == .depthBeyondParent(depth: 1, enteredDirectories: 0))
        #expect(decodingError(headerRecord(plainFile("f", depth: 1, size: 0))) == .firstEntryNotAtRoot(depth: 1))
        #expect(decodingError(root + headerRecord(directory("s", depth: 0))) == .secondRootEntry)
    }

    @Test("A shallower entry leaves directories first, and the end leaves the rest")
    func leaveEvents() {
        let container =
            headerRecord(directory("r", depth: 0)) + headerRecord(directory("a", depth: 1))
            + headerRecord(directory("b", depth: 2)) + headerRecord(symlink("s", depth: 1, target: "a"))
            + endRecord(entries: 4, bytes: 0)
        let decoded = decode(container)
        #expect(decoded.error == nil)
        let shape: [String] = decoded.events.map {
            switch $0 {
            case .enterDirectory: "enter"
            case .leaveDirectory: "leave"
            case .symlink: "symlink"
            case .end: "end"
            default: "other"
            }
        }
        #expect(shape == ["enter", "enter", "enter", "leave", "leave", "symlink", "leave", "end"])
    }

    @Test("Entry types: unspecified and unknown are refused")
    func entryTypes() {
        var unspecified = plainFile("f", depth: 0, size: 0)
        unspecified.type = .unspecified
        #expect(decodingError(Self.single(unspecified)) == .unknownEntryType)
        var unknown = plainFile("f", depth: 0, size: 0)
        unknown.type = .UNRECOGNIZED(9)
        #expect(decodingError(Self.single(unknown)) == .unknownEntryType)
        #expect(decodingError(record(.header, Data([0xFF]))) == .headerUndecodable)
    }

    @Test("An end record that is not an EndRecord is refused")
    func undecodableEnd() {
        let container = headerRecord(plainFile("f", depth: 0, size: 0)) + record(.end, Data([0xFF]))
        #expect(decodingError(container) == .endUndecodable)
    }

    @Test("Storage must fit the entry type")
    func storageByType() {
        var directoryWithStorage = directory("d", depth: 0)
        directoryWithStorage.plain.size = 0
        #expect(decodingError(Self.single(directoryWithStorage)) == .storageNotAllowed(.directory))
        var fileWithout = plainFile("f", depth: 0, size: 0)
        fileWithout.storage = nil
        #expect(decodingError(Self.single(fileWithout)) == .storageNotAllowed(.file))
        var symlinkWithStorage = symlink("s", depth: 0, target: "t")
        symlinkWithStorage.plain.size = 0
        #expect(decodingError(Self.inFolder(symlinkWithStorage)) == .storageNotAllowed(.symlink))
    }

    @Test("Symlink targets: present, without NUL, and only on symlinks")
    func symlinkTargets() {
        #expect(decodingError(Self.inFolder(symlink("s", depth: 1, target: ""))) == .invalidSymlinkTarget)
        #expect(decodingError(Self.inFolder(symlink("s", depth: 1, target: "a\0b"))) == .invalidSymlinkTarget)
        var file = plainFile("f", depth: 0, size: 0)
        file.symlinkTarget = name("t")
        #expect(decodingError(Self.single(file)) == .invalidSymlinkTarget)
    }

    // MARK: Names

    @Test("A name of 255 bytes decodes; 256 is refused")
    func nameLength() {
        let edge = Data(repeating: 0x61, count: 255)
        var file = plainFile("", depth: 0, size: 0)
        file.name = edge
        #expect(decodingError(Self.single(file)) == nil)
        file.name = edge + Data([0x61])
        #expect(decodingError(Self.single(file)) == .invalidName)
    }

    @Test(
        "Refused names",
        arguments: [Data(), Data(".".utf8), Data("..".utf8), Data("a/b".utf8), Data("/".utf8), Data([0x61, 0x00])])
    func refusedNames(_ refused: Data) {
        var file = plainFile("", depth: 0, size: 0)
        file.name = refused
        #expect(decodingError(Self.single(file)) == .invalidName)
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        #expect(throws: ContainerError.invalidName) { try encoder.entry(file) }
    }

    @Test("Accepted names", arguments: [Data("...".utf8), Data(".a".utf8), Data("a..".utf8), Data([0xFF, 0xFE])])
    func acceptedNames(_ accepted: Data) {
        var file = plainFile("", depth: 0, size: 0)
        file.name = accepted
        #expect(decodingError(Self.single(file)) == nil)
    }

    // MARK: INLINE data

    @Test("An INLINE representation is one bare DATA entry at depth 0")
    func inlineRepresentation() {
        let bytes = Data("hello".utf8)
        let decoded = decode(Self.single(inlineData(size: 5), bytes: bytes))
        #expect(decoded.error == nil)
        #expect(content(of: decoded.events) == bytes)

        var named = inlineData(size: 0)
        named.name = name("x")
        #expect(decodingError(Self.single(named)) == .dataEntryNotBare)
        var moded = inlineData(size: 0)
        moded.mode = 0o644
        #expect(decodingError(Self.single(moded)) == .dataEntryNotBare)
        var decmpfs = inlineData(size: 0)
        decmpfs.decmpfs.attribute = decmpfsAttribute(type: 4, size: 1)
        #expect(decodingError(Self.single(decmpfs)) == .storageNotAllowed(.data))
        let atRoot = headerRecord(directory("d", depth: 0)) + headerRecord(inlineData(size: 0))
        #expect(decodingError(atRoot) == .dataEntryNotRoot)
    }
}

/// The `com.apple.decmpfs` attribute's header, checked against XNU's `decmpfs_disk_header`.
@Suite("decmpfs storage")
struct DecmpfsStorageTests {
    static func container(_ attribute: Data, accepting types: Set<UInt32> = [4]) -> ContainerError? {
        let acceptance = ContainerAcceptance(
            storage: .file, byteCeiling: 1 << 20, decmpfsTypes: types, acceptsLZ4: false)
        let header = decmpfsFile("c", depth: 0, attribute: attribute, resourceForkSize: 0)
        return decodingError(ContainerLimitTests.single(header), accepting: acceptance)
    }

    @Test("The header parses as magic, type and size, little-endian")
    func parses() throws {
        let header = try DecmpfsHeader(
            attribute: Data([
                0x66, 0x70, 0x6D, 0x63, 0x04, 0x00, 0x00, 0x00, 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0x0E,
            ]))
        #expect(header.compressionType == 4)
        #expect(header.uncompressedSize == 0x0EDC_BA98_7654_3210)
    }

    @Test("An attribute of 3,802 bytes decodes; 3,803 is refused")
    func attributeSize() {
        let edge = decmpfsAttribute(type: 4, size: 1, tail: Data(count: 3_802 - 16))
        #expect(edge.count == DecmpfsHeader.maxAttributeByteCount)
        #expect(Self.container(edge) == nil)
        let past = decmpfsAttribute(type: 4, size: 1, tail: Data(count: 3_803 - 16))
        #expect(Self.container(past) == .malformedDecmpfsAttribute(.tooLarge(byteCount: 3_803)))
    }

    @Test("An attribute of exactly the header decodes; one byte short is refused")
    func attributeHoldsHeader() {
        let whole = decmpfsAttribute(type: 4, size: 1)
        #expect(whole.count == DecmpfsHeader.byteCount)
        #expect(Self.container(whole) == nil)
        #expect(Self.container(whole.prefix(15)) == .malformedDecmpfsAttribute(.truncated(byteCount: 15)))
        #expect(Self.container(Data()) == .malformedDecmpfsAttribute(.truncated(byteCount: 0)))
    }

    @Test("The magic must be cmpf")
    func magic() {
        #expect(
            Self.container(decmpfsAttribute(type: 4, size: 1, magic: 0x636D_7067))
                == .malformedDecmpfsAttribute(.badMagic(0x636D_7067)))
        #expect(
            Self.container(decmpfsAttribute(type: 4, size: 1, magic: 0x6670_6D63))
                == .malformedDecmpfsAttribute(.badMagic(0x6670_6D63)))
    }

    @Test("The type must be one the pull accepted")
    func acceptedType() {
        #expect(Self.container(decmpfsAttribute(type: 4, size: 1), accepting: [3, 4]) == nil)
        let refused = Self.container(decmpfsAttribute(type: 8, size: 1), accepting: [3, 4])
        #expect(refused == .decmpfsTypeNotAccepted(8))
        #expect(refused?.errorCode == .itemDecmpfsRefused)
        #expect(Self.container(decmpfsAttribute(type: 4, size: 1), accepting: []) == .decmpfsTypeNotAccepted(4))
    }

    @Test("decmpfs storage is for regular files only")
    func regularFilesOnly() {
        var directoryEntry = directory("d", depth: 0)
        directoryEntry.decmpfs.attribute = decmpfsAttribute(type: 4, size: 1)
        #expect(decodingError(ContainerLimitTests.single(directoryEntry)) == .storageNotAllowed(.directory))
    }

    @Test("com.apple.decmpfs in the extended attribute list is refused")
    func notAnXattr() {
        var file = plainFile("f", depth: 0, size: 0)
        var xattr = Kernova_V2_Xattr()
        xattr.name = name("com.apple.decmpfs")
        xattr.value = decmpfsAttribute(type: 4, size: 1)
        file.xattrs = [xattr]
        #expect(decodingError(ContainerLimitTests.single(file)) == .xattrNotAllowed(name("com.apple.decmpfs")))
    }

    @Test("A decmpfs file's resource fork arrives as its chunks")
    func resourceFork() {
        let header = decmpfsFile("c", depth: 0, attribute: decmpfsAttribute(type: 4, size: 100), resourceForkSize: 3)
        let decoded = decode(headerRecord(header) + record(.chunk, Data([7, 8, 9])) + endRecord(entries: 1, bytes: 3))
        #expect(decoded.error == nil)
        #expect(content(of: decoded.events) == Data([7, 8, 9]))
    }
}
