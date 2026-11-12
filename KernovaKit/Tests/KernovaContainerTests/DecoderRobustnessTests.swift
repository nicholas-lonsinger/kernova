#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaPortableTestSupport
import KernovaWire
import Testing

@Suite("Container decoder robustness")
struct DecoderRobustnessTests {
    /// A small container with every record kind: a directory, an LZ4 chunk, a raw chunk, a zero run, a
    /// symlink, a decmpfs file and the end.
    static let small: Data = {
        var container = headerRecord(directory(depth: 0))
        container += headerRecord(lz4File("l", depth: 1, size: 32)) + GoldenVectorTests.lz4Chunk
        container += headerRecord(plainFile("f", depth: 1, size: 4_099)) + GoldenVectorTests.zeroRun
        container += record(.chunk, Data("abc".utf8))
        container += headerRecord(symlink("s", depth: 1, target: "f"))
        container += headerRecord(
            decmpfsFile("c", depth: 1, attribute: decmpfsAttribute(type: 4, size: 10), resourceForkSize: 2))
        container += record(.chunk, Data([1, 2]))
        container += endRecord(entries: 5, bytes: 32 + 4_099 + 2)
        return container
    }()

    @Test("A flipped bit in any record's checksum or payload is a checksum mismatch, in every record kind")
    func flippedChecksumBits() {
        let records = recordOffsets(Self.small)
        #expect(Set(records.map(\.kind)) == Set(ContainerRecordKind.allCases))
        for (index, (offset, kind)) in records.enumerated() {
            let end = index + 1 < records.count ? records[index + 1].offset : Self.small.count
            for bit in 0..<32 {
                var corrupted = Self.small
                corrupted[offset + 5 + bit / 8] ^= 1 << (bit % 8)
                #expect(decodingError(corrupted) == .checksumMismatch(kind: kind), "\(kind) checksum bit \(bit)")
            }
            for byte in (offset + ContainerRecord.prefixByteCount)..<end {
                var corrupted = Self.small
                corrupted[byte] ^= 0x10
                #expect(decodingError(corrupted) == .checksumMismatch(kind: kind), "\(kind) payload byte \(byte)")
            }
        }
    }

    @Test("After an error the decoder repeats it")
    func errorIsSticky() {
        var decoder = ContainerDecoder(accepting: generous())
        decoder.feed(Data([0x09]))
        #expect(throws: ContainerError.unknownRecordKind(9)) { try decoder.next() }
        decoder.feed(GoldenVectorTests.header)
        #expect(throws: ContainerError.unknownRecordKind(9)) { try decoder.next() }
        #expect(throws: ContainerError.unknownRecordKind(9)) { try decoder.finish() }
    }
}

@Suite("Container decoder memory ceiling")
struct DecoderMemoryCeilingTests {
    @Test(
        "Fed in pieces, the decoder holds less than one record and emits no event over a chunk",
        arguments: [1, 777, 65_536, 1_048_576])
    func boundedResidue(pieceSize: Int) throws {
        // A file whose chunks are each the largest a chunk may be, raw and LZ4.
        let big = UInt64(ContainerRecord.maxChunkPayload)
        var container = headerRecord(lz4File(depth: 0, size: 2 * big))
        var generator = SplitMix64(seed: 99)
        container += record(.chunk, generator.bytes(ContainerRecord.maxChunkPayload))
        container += lz4ChunkRecord(
            declaredSize: UInt32(big), block: try #require(LZ4Block.compress(Data(count: Int(big)))))
        container += endRecord(entries: 1, bytes: 2 * big)
        let decoded = decode(container, pieceSize: pieceSize)
        #expect(decoded.error == nil)
        #expect(decoded.largestEvent == ContainerRecord.maxChunkPayload)
        #expect(decoded.largestResidue < ContainerRecord.prefixByteCount + ContainerRecord.maxChunkPayload)

        let mixed = decode(try TreeFixture.mixed().encoded(), pieceSize: pieceSize)
        #expect(mixed.error == nil)
        #expect(mixed.largestEvent <= ContainerEncoder.chunkByteCount)
        #expect(mixed.largestResidue < ContainerRecord.prefixByteCount + ContainerEncoder.chunkByteCount)
    }

    @Test("A file larger than Int64.max bytes is refused at its header, whatever the ceiling")
    func fileTooLarge() {
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: .max, decmpfsTypes: [], acceptsLZ4: false)
        var decoder = ContainerDecoder(accepting: acceptance)
        decoder.feed(headerRecord(plainFile(depth: 0, size: UInt64(Int64.max) + 1)))
        #expect(throws: ContainerError.fileTooLarge(UInt64(Int64.max) + 1)) { try decoder.next() }
    }
}
