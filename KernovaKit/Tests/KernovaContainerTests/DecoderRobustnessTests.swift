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
        var container = headerRecord(directory("d", depth: 0))
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

    @Test("The small container decodes, whole and a byte at a time, to the same events")
    func wholeAndBytewise() {
        let whole = decode(Self.small)
        #expect(whole.error == nil)
        #expect(whole.events.last == .end)
        let bytewise = decode(Self.small, pieceSize: 1)
        #expect(bytewise.error == nil)
        #expect(bytewise.events == whole.events)
    }

    @Test("A container cut at every byte offset never succeeds and never yields more than the whole")
    func cutAtEveryOffset() {
        let whole = decode(Self.small).events
        for cut in 0..<Self.small.count {
            let decoded = decode(Self.small.prefix(cut))
            #expect(decoded.error != nil, "cut at \(cut) succeeded")
            #expect(Array(whole.prefix(decoded.events.count)) == decoded.events, "cut at \(cut)")
            #expect(!decoded.events.contains(.end), "cut at \(cut)")
        }
    }

    @Test("A cut container reports truncation once its bytes run out")
    func cutReportsTruncation() {
        let records = recordOffsets(Self.small)
        for (offset, _) in records.dropFirst() {
            #expect(decodingError(Self.small.prefix(offset)) == .truncated, "cut at record boundary \(offset)")
        }
        #expect(decodingError(Data()) == .truncated)
    }

    @Test("The large fixture cut at every record boundary and inside every record never succeeds")
    func cutLargeFixture() throws {
        let container = try TreeFixture.mixed().encoded(
            policy: .init(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil))
        for (offset, _) in recordOffsets(container) {
            for cut in [offset, offset + 1, offset + 5, offset + 9, offset + 10] where cut < container.count {
                #expect(decode(container.prefix(cut)).error != nil, "cut at \(cut)")
            }
        }
    }

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

    @Test("A flipped bit in a record's length is refused")
    func flippedLengthBits() {
        for (offset, kind) in recordOffsets(Self.small) {
            for bit in 0..<32 {
                var corrupted = Self.small
                corrupted[offset + 1 + bit / 8] ^= 1 << (bit % 8)
                #expect(decodingError(corrupted) != nil, "\(kind) length bit \(bit)")
            }
        }
    }

    @Test("Seeded random mutations are refused, never crash, and never decode to other events")
    func randomMutations() {
        var generator = SplitMix64(seed: 0xC0_47A1)
        let original = decode(Self.small).events
        for round in 0..<3_000 {
            var mutated = Self.small
            for _ in 0..<Int.random(in: 1...4, using: &generator) {
                let position = Int.random(in: 0..<mutated.count, using: &generator)
                switch Int.random(in: 0..<4, using: &generator) {
                case 0:
                    mutated[position] ^= UInt8(1) << UInt8.random(in: 0..<8, using: &generator)
                case 1:
                    mutated[position] = UInt8.random(in: 0...255, using: &generator)
                case 2:
                    mutated.insert(UInt8.random(in: 0...255, using: &generator), at: position)
                default:
                    if mutated.count > 1 { mutated.remove(at: position) }
                }
            }
            let decoded = decode(mutated, pieceSize: Int.random(in: 1...64, using: &generator))
            if decoded.succeeded {
                #expect(decoded.events == original, "round \(round) decoded to other events")
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
        var container = headerRecord(lz4File("max", depth: 0, size: 2 * big))
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

    @Test("A record declaring a payload over its kind's limit is refused from its 5-byte prefix")
    func oversizeRecordRefusedFromPrefix() {
        for kind in ContainerRecordKind.allCases {
            let length = UInt32(kind.payloadLengths.upperBound + 1)
            var decoder = ContainerDecoder(accepting: generous())
            decoder.feed(Data([kind.rawValue]) + littleEndian(length))
            #expect(throws: ContainerError.recordLengthOutOfRange(kind: kind, length: Int(length))) {
                try decoder.next()
            }
        }
        var decoder = ContainerDecoder(accepting: generous())
        decoder.feed(Data([ContainerRecordKind.chunk.rawValue]) + littleEndian(UInt32.max))
        #expect(throws: ContainerError.recordLengthOutOfRange(kind: .chunk, length: Int(UInt32.max))) {
            try decoder.next()
        }
        #expect(decoder.bufferedByteCount == 5)
    }

    @Test("An LZ4 chunk declaring more than its entry owes is refused before it is decompressed")
    func lz4DeclaredSizeCheckedBeforeDecompressing() {
        // A block that would fail to decompress if the size check came second.
        let garbage = Data([0xFF, 0xFF, 0xFF])
        let container =
            headerRecord(lz4File("l", depth: 0, size: 10)) + lz4ChunkRecord(declaredSize: 1_048_576, block: garbage)
        #expect(decodingError(container) == .chunkPastEntrySize(count: 1_048_576, remaining: 10))
    }

    @Test("An entry whose size passes the ceiling is refused at its header, before any chunk")
    func ceilingCheckedAtHeader() {
        let acceptance = ContainerAcceptance(storage: .file, byteCeiling: 100, decmpfsTypes: [], acceptsLZ4: false)
        var decoder = ContainerDecoder(accepting: acceptance)
        decoder.feed(headerRecord(plainFile("f", depth: 0, size: UInt64.max)))
        #expect(throws: ContainerError.exceedsByteCeiling(declared: UInt64.max, ceiling: 100)) { try decoder.next() }
    }
}
