#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
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

    // MARK: Record sizes

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

    // MARK: Counts

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

    @Test("The header parses as magic, type and size, little-endian")
    func parses() throws {
        let header = try DecmpfsHeader(
            attribute: Data([
                0x66, 0x70, 0x6D, 0x63, 0x04, 0x00, 0x00, 0x00, 0x10, 0x32, 0x54, 0x76, 0x98, 0xBA, 0xDC, 0x0E,
            ]))
        #expect(header.compressionType == 4)
        #expect(header.uncompressedSize == 0x0EDC_BA98_7654_3210)
    }

    @Test("An attribute of exactly the header parses; one byte short is refused")
    func attributeHoldsHeader() {
        let whole = decmpfsAttribute(type: 4, size: 1)
        #expect(whole.count == DecmpfsHeader.byteCount)
        #expect(Self.container(whole, fork: 1) == nil)
        #expect(Self.container(whole.prefix(15)) == .malformedDecmpfsAttribute(.truncated(byteCount: 15)))
        #expect(Self.container(Data()) == .malformedDecmpfsAttribute(.truncated(byteCount: 0)))
    }
}
