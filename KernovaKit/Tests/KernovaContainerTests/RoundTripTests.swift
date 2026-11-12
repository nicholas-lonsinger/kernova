#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaPortableTestSupport
import KernovaWire
import Testing

@Suite("Container round trips")
struct RoundTripTests {
    static let lz4Always = ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil)

    @Test("A chunk LZ4 does not shrink goes raw, and the policy abandons an entry after its limit")
    func abandonAfterUnshrunkChunks() throws {
        var generator = SplitMix64(seed: 5)
        let size = ContainerEncoder.chunkByteCount
        // Two incompressible chunks, then a compressible one.
        let bytes = generator.bytes(2 * size) + Data(repeating: 0x61, count: size)
        let fixture = TreeFixture(entries: [(lz4File(depth: 0, size: UInt64(bytes.count)), bytes)])
        func kinds(_ policy: ChunkCompressionPolicy) throws -> [ContainerRecordKind] {
            recordOffsets(try fixture.encoded(policy: policy, pieceSize: bytes.count)).map(\.kind)
        }
        #expect(try kinds(Self.lz4Always) == [.header, .chunk, .chunk, .lz4Chunk, .end])
        #expect(
            try kinds(.init(attemptsLZ4: true, abandonAfterUnshrunkChunks: 3)) == [
                .header, .chunk, .chunk, .lz4Chunk, .end,
            ])
        #expect(
            try kinds(.init(attemptsLZ4: true, abandonAfterUnshrunkChunks: 2)) == [
                .header, .chunk, .chunk, .chunk, .end,
            ])
        let decoded = decode(try fixture.encoded(policy: .init(attemptsLZ4: true, abandonAfterUnshrunkChunks: 2)))
        #expect(content(of: decoded.events) == bytes)
    }

    @Test("The encoder refuses bytes past an entry's size, an end with an entry incomplete, and records after the end")
    func encoderRefusals() throws {
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try encoder.entry(plainFile(depth: 0, size: 3))
        #expect(throws: ContainerError.chunkPastEntrySize(count: 4, remaining: 3)) { try encoder.bytes(Data(count: 4)) }
        _ = try encoder.bytes(Data([1, 2]))
        #expect(throws: ContainerError.entryIncomplete(remaining: 1)) { try encoder.end() }
        _ = try encoder.bytes(Data([3]))
        _ = try encoder.end()
        #expect(throws: ContainerError.bytesAfterEnd) { try encoder.entry(plainFile("g", depth: 1, size: 0)) }

        var empty = ContainerEncoder(accepting: generous(), policy: .never)
        #expect(throws: ContainerError.noEntry) { try empty.end() }
        var orphan = ContainerEncoder(accepting: generous(), policy: .never)
        #expect(throws: ContainerError.chunkOutsideEntry) { try orphan.bytes(Data([1])) }
        var deep = ContainerEncoder(accepting: generous(.folder), policy: .never)
        _ = try deep.entry(directory(depth: 0))
        #expect(throws: ContainerError.depthBeyondParent(depth: 2, enteredDirectories: 1)) {
            try deep.entry(plainFile("f", depth: 2, size: 0))
        }
    }
}
