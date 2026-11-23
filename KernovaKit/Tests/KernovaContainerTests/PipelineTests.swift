#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaContainer
import KernovaContainerPipeline
import KernovaPortableTestSupport
import KernovaSynchronization
import KernovaWire
import Testing

@Suite("Container pipelines", .offTaskWaitsReported)
struct PipelineTests {
    static let policies: [ChunkCompressionPolicy] = [
        .never,
        ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil),
        ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: 1),
        ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: 2),
    ]

    @Test(
        "the encode pipeline writes the sequential encoder's bytes for random trees and worker timing",
        arguments: Array(0..<8 as Range<UInt64>), [0, 1, 2, 4])
    func encodesAsSequential(seed: UInt64, workers: Int) {
        let tree = RandomTree(seed: seed)
        for (index, policy) in Self.policies.enumerated() {
            let expected = sequentiallyEncoded(tree.events, accepting: tree.acceptance, policy: policy)
            #expect(expected.error == nil)
            let lanes = SpinningLanes(seed: seed &* 31 &+ UInt64(index))
            let pipeline = ContainerEncodePipeline(
                accepting: tree.acceptance, policy: policy, workers: lanes.workers(workers))
            let encoded = pipelined(tree.events, through: pipeline)
            #expect(encoded == expected, "policy \(index)")
        }
    }

    @Test(
        "the decode pipeline yields the sequential decoder's events for random trees, feeds and worker timing",
        arguments: Array(0..<8 as Range<UInt64>), [0, 1, 2, 4])
    func decodesAsSequential(seed: UInt64, workers: Int) {
        let tree = RandomTree(seed: seed)
        let policy = ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: 2)
        let container = sequentiallyEncoded(tree.events, accepting: tree.acceptance, policy: policy).container
        let pieces = pieces(of: container, sizes: feedSizes(seed: seed))
        let expected = sequentiallyDecoded(pieces, accepting: tree.acceptance)
        #expect(expected.error == nil)
        #expect(coalesced(expected.events) == coalesced(tree.events))

        let lanes = SpinningLanes(seed: seed)
        let pipeline = ContainerDecodePipeline(accepting: tree.acceptance, workers: lanes.workers(workers))
        #expect(pipelined(pieces, through: pipeline) == expected)
    }

    @Test("chunks that finish in reverse order are still yielded in stream order")
    func keepsOrderWhenWorkFinishesBackwards() throws {
        // Four lanes; the first chunk handed to each lane but the last waits until the next lane's has finished,
        // so the first four finish last to first.
        let lanes = 4
        let gates = (0..<lanes).map { _ in DispatchSemaphore(value: 0) }
        let waits = OffTaskWaits()
        let firsts = Locked(Set<Int>())
        let workers = ChunkWorkers(count: lanes) { lane, work in
            let first = firsts.withLock { $0.insert(lane).inserted }
            if first && lane < lanes - 1 {
                waits.run { try Backstop("lane \(lane + 1)'s first chunk").wait(for: gates[lane + 1]) }
            }
            work()
            if first { gates[lane].signal() }
        }
        let size = ContainerEncoder.chunkByteCount
        var chunks: [Data] = []
        for index in 0..<10 {
            chunks.append(Data(String(repeating: "chunk \(index) ", count: size / 8).utf8.prefix(size)))
        }
        let content = chunks.reduce(Data(), +)
        let tree = [
            TreeEvent.beginFile(lz4File(depth: 0, size: UInt64(content.count))), .bytes(content), .finishFile,
            .end,
        ]
        let policy = ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil)
        let container = sequentiallyEncoded(tree, accepting: generous(.file), policy: policy).container
        #expect(recordOffsets(container).filter { $0.kind == .lz4Chunk }.count == chunks.count)

        let pipeline = ContainerDecodePipeline(accepting: generous(.file), workers: workers)
        let decoded = pipelined([container], through: pipeline)
        #expect(decoded.error == nil)
        let bytes = decoded.events.compactMap { event -> Data? in
            guard case .bytes(let bytes) = event else { return nil }
            return bytes
        }
        #expect(bytes == chunks)
    }

    @Test("an LZ4 chunk past a limit is refused before any lane decompresses it")
    func refusesBeforeHandingOut() throws {
        let block = try #require(LZ4Block.compress(Data(repeating: 0x61, count: 4_096)))
        let valid = lz4ChunkRecord(declaredSize: 4_096, block: block)
        var ceiling = generous(.file)
        ceiling.byteCeiling = 4_096 * 3
        let cases: [(Data, ContainerAcceptance, ContainerError)] = [
            // Declares more than the entry still owes.
            (
                headerRecord(lz4File(depth: 0, size: 4_096 * 2 + 100)) + valid + valid
                    + lz4ChunkRecord(declaredSize: 4_096, block: block),
                generous(.file), .chunkPastEntrySize(count: 4_096, remaining: 100)
            ),
            // Declares more than any chunk may hold.
            (
                headerRecord(lz4File(depth: 0, size: 1 << 22)) + valid
                    + lz4ChunkRecord(declaredSize: UInt32(ContainerRecord.maxChunkPayload + 1), block: block),
                generous(.file),
                .lz4SizeOutOfRange(declared: ContainerRecord.maxChunkPayload + 1)
            ),
            // An LZ4 chunk in an entry whose storage is plain.
            (
                headerRecord(plainFile(depth: 0, size: 4_096)) + valid, generous(.file),
                .lz4ChunkOutsideLZ4Storage
            ),
            // A header past the pull's byte ceiling.
            (
                headerRecord(lz4File(depth: 0, size: 4_096 * 4)) + valid, ceiling,
                .exceedsByteCeiling(declared: 4_096 * 4, ceiling: 4_096 * 3)
            ),
        ]
        for (container, acceptance, error) in cases {
            let expected = sequentiallyDecoded([container], accepting: acceptance)
            #expect(expected.error == error)
            let lanes = SpinningLanes(seed: 1)
            let pipeline = ContainerDecodePipeline(accepting: acceptance, workers: lanes.workers(2))
            let decoded = pipelined([container], through: pipeline)
            #expect(decoded == expected)
            // Only the valid chunks before the refusal reached a lane.
            let validChunks = decoded.events.filter { if case .bytes = $0 { true } else { false } }.count
            #expect(lanes.started == validChunks, "\(error)")
        }
    }
}
