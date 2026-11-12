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
        var container = headerRecord(directory(depth: 0)) + headerRecord(entry)
        if !bytes.isEmpty { container += record(.chunk, bytes) }
        return container + endRecord(entries: 2, bytes: UInt64(bytes.count))
    }

    // MARK: Record sizes

    /// A FILE header padded with an extended attribute to serialize to exactly `byteCount` bytes.
    static func header(serializingTo byteCount: Int) -> EntryHeader {
        var header = plainFile(depth: 0, size: 0)
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
            decodingError(Self.single(plainFile(depth: 0, size: UInt64(edge)), bytes: Data(count: edge))) == nil)
        let past =
            headerRecord(plainFile(depth: 0, size: UInt64(edge + 1)))
            + rawRecord(kind: ContainerRecordKind.chunk.rawValue, payload: Data(count: edge + 1))
        #expect(decodingError(past) == .recordLengthOutOfRange(kind: .chunk, length: edge + 1))
    }

    @Test("A zero run's payload is exactly 8 bytes")
    func zeroRunLength() {
        let header = headerRecord(plainFile(depth: 0, size: 100))
        for length in [0, 7, 9] {
            let container = header + rawRecord(kind: ContainerRecordKind.zeroRun.rawValue, payload: Data(count: length))
            #expect(decodingError(container) == .recordLengthOutOfRange(kind: .zeroRun, length: length))
        }
    }

    @Test("An LZ4 chunk's payload holds its size and at least one block byte")
    func lz4ChunkMinimum() {
        let header = headerRecord(lz4File(depth: 0, size: 100))
        let short = header + rawRecord(kind: ContainerRecordKind.lz4Chunk.rawValue, payload: littleEndian(UInt32(1)))
        #expect(decodingError(short) == .recordLengthOutOfRange(kind: .lz4Chunk, length: 4))
    }

    // MARK: Byte ceiling

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
        let body = headerRecord(plainFile(depth: 0, size: 3)) + record(.chunk, Data("abc".utf8))
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
        let open = headerRecord(plainFile(depth: 0, size: 3)) + record(.chunk, Data("ab".utf8))
        #expect(decodingError(open + endRecord(entries: 1, bytes: 2)) == .entryIncomplete(remaining: 1))
        let whole = Self.single(plainFile(depth: 0, size: 0))
        #expect(decodingError(whole + Data([0x00])) == .bytesAfterEnd)
        #expect(decodingError(whole + headerRecord(plainFile(depth: 0, size: 0))) == .bytesAfterEnd)
    }

    // MARK: Chunks

    @Test("Chunks fill their entry exactly: at its size it finishes, past it is refused")
    func chunkAgainstEntry() {
        let header = headerRecord(plainFile(depth: 0, size: 5))
        #expect(decodingError(header + zeroRunRecord(5) + endRecord(entries: 1, bytes: 5)) == nil)
        #expect(decodingError(header + zeroRunRecord(6)) == .chunkPastEntrySize(count: 6, remaining: 5))
        #expect(decodingError(header + record(.chunk, Data(count: 6))) == .chunkPastEntrySize(count: 6, remaining: 5))
        #expect(decodingError(header + zeroRunRecord(0)) == .emptyChunk)
        #expect(decodingError(record(.chunk, Data([1]))) == .chunkOutsideEntry)
        let empty = headerRecord(plainFile(depth: 0, size: 0))
        #expect(decodingError(empty + record(.chunk, Data([1]))) == .chunkOutsideEntry)
        let directoryRecord = headerRecord(directory(depth: 0))
        #expect(decodingError(directoryRecord + zeroRunRecord(1)) == .chunkOutsideEntry)
        #expect(
            decodingError(header + headerRecord(plainFile(depth: 0, size: 0))) == .entryIncomplete(remaining: 5))
    }

    @Test("LZ4 storage needs the pull's codec, and an LZ4 chunk needs LZ4 storage")
    func lz4Acceptance() {
        let noLZ4 = ContainerAcceptance(storage: .file, byteCeiling: 1 << 20, decmpfsTypes: [], acceptsLZ4: false)
        #expect(decodingError(Self.single(lz4File(depth: 0, size: 0)), accepting: noLZ4) == .lz4NotAccepted)
        let plain = headerRecord(plainFile(depth: 0, size: 32))
        #expect(decodingError(plain + GoldenVectorTests.lz4Chunk) == .lz4ChunkOutsideLZ4Storage)
        var encoder = ContainerEncoder(accepting: noLZ4, policy: .never)
        #expect(throws: ContainerError.lz4NotAccepted) { try encoder.entry(lz4File(depth: 0, size: 0)) }
    }

    @Test("A malformed LZ4 block is refused")
    func malformedBlock() {
        let container =
            headerRecord(lz4File(depth: 0, size: 32)) + lz4ChunkRecord(declaredSize: 32, block: Data([0x1F]))
        #expect(decodingError(container) == .lz4(.truncated))
    }

    // MARK: Structure

    @Test("Depth: at most the directories entered; the first entry at 0 and no other")
    func depth() {
        let root = headerRecord(directory(depth: 0))
        let atHeight = root + headerRecord(directory("a", depth: 1)) + headerRecord(plainFile("f", depth: 2, size: 0))
        #expect(decodingError(atHeight + endRecord(entries: 3, bytes: 0)) == nil)
        #expect(
            decodingError(root + headerRecord(plainFile("f", depth: 2, size: 0)))
                == .depthBeyondParent(depth: 2, enteredDirectories: 1))
        #expect(
            decodingError(
                headerRecord(plainFile(depth: 0, size: 0)) + headerRecord(plainFile("g", depth: 1, size: 0)))
                == .depthBeyondParent(depth: 1, enteredDirectories: 0))
        #expect(decodingError(headerRecord(plainFile("f", depth: 1, size: 0))) == .firstEntryNotAtRoot(depth: 1))
        #expect(decodingError(root + headerRecord(directory(depth: 0))) == .secondRootEntry)
    }

    @Test("Entry types: unspecified and unknown are refused")
    func entryTypes() {
        var unspecified = plainFile(depth: 0, size: 0)
        unspecified.type = .unspecified
        #expect(decodingError(Self.single(unspecified)) == .unknownEntryType)
        var unknown = plainFile(depth: 0, size: 0)
        unknown.type = .UNRECOGNIZED(9)
        #expect(decodingError(Self.single(unknown)) == .unknownEntryType)
        #expect(decodingError(record(.header, Data([0xFF]))) == .headerUndecodable)
    }

    @Test("Symlink targets: present, without NUL, and only on symlinks")
    func symlinkTargets() {
        #expect(decodingError(Self.inFolder(symlink("s", depth: 1, target: ""))) == .invalidSymlinkTarget)
        #expect(decodingError(Self.inFolder(symlink("s", depth: 1, target: "a\0b"))) == .invalidSymlinkTarget)
        var file = plainFile(depth: 0, size: 0)
        file.symlinkTarget = name("t")
        #expect(decodingError(Self.single(file)) == .invalidSymlinkTarget)
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
        let atRoot = headerRecord(directory(depth: 0)) + headerRecord(inlineData(size: 0))
        #expect(decodingError(atRoot) == .dataEntryNotRoot)
    }
}

/// The `com.apple.decmpfs` attribute's header, checked against XNU's `decmpfs_disk_header`.
@Suite("decmpfs storage")
struct DecmpfsStorageTests {
    /// The error a FILE container of one decmpfs entry with `attribute` and a `fork`-byte resource fork comes
    /// to.
    static func container(_ attribute: Data, fork: Int = 0, accepting types: Set<UInt32> = [3, 4]) -> ContainerError? {
        let acceptance = ContainerAcceptance(
            storage: .file, byteCeiling: 1 << 20, decmpfsTypes: types, acceptsLZ4: false)
        let header = decmpfsFile(depth: 0, attribute: attribute, resourceForkSize: UInt64(fork))
        let chunks = fork > 0 ? record(.chunk, Data(repeating: 1, count: fork)) : Data()
        return decodingError(
            headerRecord(header) + chunks + endRecord(entries: 1, bytes: UInt64(fork)), accepting: acceptance)
    }

    /// An attribute of `type` holding `payload` bytes after its header.
    static func inline(_ type: UInt32, payload: Int = 1) -> Data {
        decmpfsAttribute(type: type, size: 1, tail: Data(repeating: 0xCC, count: payload))
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
        let edge = Self.inline(3, payload: 3_802 - 16)
        #expect(edge.count == DecmpfsHeader.maxAttributeByteCount)
        #expect(Self.container(edge) == nil)
        let past = Self.inline(3, payload: 3_803 - 16)
        #expect(Self.container(past) == .malformedDecmpfsAttribute(.tooLarge(byteCount: 3_803)))
    }

    @Test("An attribute of exactly the header parses; one byte short is refused")
    func attributeHoldsHeader() {
        let whole = decmpfsAttribute(type: 4, size: 1)
        #expect(whole.count == DecmpfsHeader.byteCount)
        #expect(Self.container(whole, fork: 1) == nil)
        #expect(Self.container(whole.prefix(15)) == .malformedDecmpfsAttribute(.truncated(byteCount: 15)))
        #expect(Self.container(Data()) == .malformedDecmpfsAttribute(.truncated(byteCount: 0)))
    }

    @Test(
        "A type that keeps its bytes in the attribute needs one past the header",
        arguments: [UInt32(1), 3, 7, 9, 11, 13, 15])
    func attributePayload(type: UInt32) {
        #expect(Self.container(Self.inline(type, payload: 0), accepting: [type]) == .decmpfsPayloadMissing(type))
        #expect(Self.container(Self.inline(type, payload: 1), accepting: [type]) == nil)
    }

    @Test("decmpfs storage is for regular files only")
    func regularFilesOnly() {
        var directoryEntry = directory(depth: 0)
        directoryEntry.decmpfs.attribute = decmpfsAttribute(type: 4, size: 1)
        #expect(decodingError(ContainerLimitTests.single(directoryEntry)) == .storageNotAllowed(.directory))
    }
}
