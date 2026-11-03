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

@Suite("Container pipelines")
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
            #expect(pipeline.heldRecords == 0)
            #expect(pipeline.mostHeldRecords <= pipeline.windowCapacity)
            #expect(pipeline.mostHeldBytes <= pipeline.windowCapacity * 2 * ContainerEncoder.chunkByteCount)
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
        var mostHeld = 0
        let decoded = pipelined(pieces, through: pipeline) { mostHeld = max(mostHeld, $0.heldItems) }
        #expect(decoded == expected)
        #expect(mostHeld <= pipeline.windowCapacity)
        #expect(pipeline.mostHeldItems <= pipeline.windowCapacity)
        #expect(pipeline.mostHeldBytes <= pipeline.windowCapacity * 2 * ContainerEncoder.chunkByteCount)
        #expect(pipeline.heldItems == 0)
        #expect(pipeline.bufferedByteCount == 0)
    }

    @Test("the decode pipeline refuses a mutated container exactly where the sequential decoder does")
    func refusesAsSequential() {
        let tree = RandomTree(seed: 2)
        let policy = ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil)
        let container = sequentiallyEncoded(tree.events, accepting: tree.acceptance, policy: policy).container
        var random = SplitMix64(seed: 0x5EED)
        for round in 0..<48 {
            var mutated = container
            for _ in 0...(round % 3) {
                let offset = Int(random.next() % UInt64(mutated.count))
                mutated[offset] ^= UInt8(truncatingIfNeeded: random.next() | 1)
            }
            // A cut, every few rounds, so truncation is refused too.
            if round % 5 == 0 { mutated = mutated.prefix(Int(random.next() % UInt64(mutated.count))) }
            let pieces = pieces(of: mutated, sizes: feedSizes(seed: UInt64(round)))
            let expected = sequentiallyDecoded(pieces, accepting: tree.acceptance)
            let lanes = SpinningLanes(seed: UInt64(round))
            let pipeline = ContainerDecodePipeline(accepting: tree.acceptance, workers: lanes.workers(3))
            #expect(pipelined(pieces, through: pipeline) == expected, "round \(round)")
            #expect(lanes.running == 0)
        }
    }

    @Test("chunks that finish in reverse order are still yielded in stream order")
    func keepsOrderWhenWorkFinishesBackwards() throws {
        // Four lanes; the first chunk handed to each lane but the last waits until the next lane's has finished,
        // so the first four finish last to first.
        let lanes = 4
        let gates = (0..<lanes).map { _ in DispatchSemaphore(value: 0) }
        let firsts = Locked(Set<Int>())
        let workers = ChunkWorkers(count: lanes) { lane, work in
            let first = firsts.withLock { $0.insert(lane).inserted }
            if first && lane < lanes - 1 { gates[lane + 1].wait() }
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
            TreeEvent.beginFile(lz4File("item", depth: 0, size: UInt64(content.count))), .bytes(content), .finishFile,
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
                headerRecord(lz4File("f", depth: 0, size: 4_096 * 2 + 100)) + valid + valid
                    + lz4ChunkRecord(declaredSize: 4_096, block: block),
                generous(.file), .chunkPastEntrySize(count: 4_096, remaining: 100)
            ),
            // Declares more than any chunk may hold.
            (
                headerRecord(lz4File("f", depth: 0, size: 1 << 22)) + valid
                    + lz4ChunkRecord(declaredSize: UInt32(ContainerRecord.maxChunkPayload + 1), block: block),
                generous(.file),
                .lz4(
                    .sizeOutOfRange(
                        declared: ContainerRecord.maxChunkPayload + 1, ceiling: ContainerRecord.maxChunkPayload))
            ),
            // An LZ4 chunk in an entry whose storage is plain.
            (
                headerRecord(plainFile("f", depth: 0, size: 4_096)) + valid, generous(.file),
                .lz4ChunkOutsideLZ4Storage
            ),
            // A header past the pull's byte ceiling.
            (
                headerRecord(lz4File("f", depth: 0, size: 4_096 * 4)) + valid, ceiling,
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

    @Test("a failure mid-stream leaves no work running and nothing held, and latches")
    func failureReleasesEverything() throws {
        let size = ContainerEncoder.chunkByteCount
        let text = Data(String(repeating: "a guest sends a tree. ", count: size).utf8.prefix(size * 12))
        let tree: [TreeEvent] = [
            .beginFile(lz4File("item", depth: 0, size: UInt64(text.count))), .bytes(text), .finishFile, .end,
        ]
        let policy = ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil)
        var container = sequentiallyEncoded(tree, accepting: generous(.file), policy: policy).container
        // Corrupt the fourth chunk's block where its checksum still holds, so only decompression refuses it.
        let fourth = recordOffsets(container).filter { $0.kind == .lz4Chunk }[3].offset
        let length = Int(container[fourth + 1]) | Int(container[fourth + 2]) << 8 | Int(container[fourth + 3]) << 16
        let payloadStart = fourth + ContainerRecord.prefixByteCount
        var payload = container[payloadStart..<(payloadStart + length)]
        payload[payload.startIndex + ContainerRecord.lz4SizeByteCount] = 0xFF
        payload[payload.startIndex + ContainerRecord.lz4SizeByteCount + 1] = 0xFF
        container.replaceSubrange(fourth..<(payloadStart + length), with: record(.lz4Chunk, Data(payload)))

        let expected = sequentiallyDecoded([container], accepting: generous(.file))
        let error = try #require(expected.error)
        let lanes = SpinningLanes(seed: 9, maxSpin: 200_000)
        let pipeline = ContainerDecodePipeline(accepting: generous(.file), workers: lanes.workers(4))
        #expect(pipelined([container], through: pipeline) == expected)
        #expect(lanes.running == 0)
        #expect(pipeline.heldItems == 0)
        #expect(pipeline.heldBytes == 0)
        #expect(pipeline.bufferedByteCount == 0)
        pipeline.feed(container)
        #expect(throws: error) { try pipeline.next() }
        #expect(pipeline.bufferedByteCount == 0)

        // The encoder: an event past the entry's size, with attempts in flight.
        let overrun: [TreeEvent] = [tree[0], .bytes(text.prefix(size * 6)), .bytes(text.prefix(size * 7))]
        let refusal = try #require(sequentiallyEncoded(overrun, accepting: generous(.file), policy: policy).error)
        let encodeLanes = SpinningLanes(seed: 10, maxSpin: 200_000)
        let encoder = ContainerEncodePipeline(
            accepting: generous(.file), policy: policy, workers: encodeLanes.workers(4))
        #expect(pipelined(overrun, through: encoder).error == refusal)
        #expect(encodeLanes.started > 0)
        #expect(encodeLanes.running == 0)
        #expect(encoder.heldRecords == 0)
        #expect(throws: refusal) { try encoder.encode(.finishFile) }
    }

    @Test("releasing a pipeline mid-stream returns only once none of its work is running")
    func releaseWaitsForWork() throws {
        let size = ContainerEncoder.chunkByteCount
        let text = Data(String(repeating: "lanes and windows. ", count: size).utf8.prefix(size * 16))
        let tree: [TreeEvent] = [
            .beginFile(lz4File("item", depth: 0, size: UInt64(text.count))), .bytes(text), .finishFile, .end,
        ]
        let policy = ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil)
        let container = sequentiallyEncoded(tree, accepting: generous(.file), policy: policy).container

        let decodeLanes = SpinningLanes(seed: 3, maxSpin: 400_000)
        do {
            let pipeline = ContainerDecodePipeline(accepting: generous(.file), workers: decodeLanes.workers(4))
            pipeline.feed(container.prefix(container.count / 2))
            for _ in 0..<2 { _ = try pipeline.next() }
            withExtendedLifetime(pipeline) {}
        }
        #expect(decodeLanes.started > 0)
        #expect(decodeLanes.running == 0)

        let encodeLanes = SpinningLanes(seed: 4, maxSpin: 400_000)
        do {
            let pipeline = ContainerEncodePipeline(
                accepting: generous(.file), policy: policy, workers: encodeLanes.workers(4))
            _ = try pipeline.encode(tree[0])
            _ = try pipeline.encode(.bytes(text.prefix(size * 8)))
            withExtendedLifetime(pipeline) {}
        }
        #expect(encodeLanes.started > 0)
        #expect(encodeLanes.running == 0)
    }

    @Test("with lanes, encoding and decoding compressible bytes is no slower than in the caller")
    func parallelIsNotSlower() throws {
        let size = ContainerEncoder.chunkByteCount
        // Text of words drawn one at a time, so each chunk costs the encoder real work, and enough chunks that a
        // lane's scheduling latency on a busy runner is small beside them.
        var random = SplitMix64(seed: 11)
        let words = (0..<512).map { Data("word\($0) ".utf8) }
        var text = Data()
        text.reserveCapacity(size * 32 + 16)
        while text.count < size * 32 { text.append(words[Int(random.next() % 512)]) }
        text = text.prefix(size * 32)
        let tree: [TreeEvent] = [
            .beginFile(lz4File("item", depth: 0, size: UInt64(text.count))), .bytes(text), .finishFile, .end,
        ]
        let policy = ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: nil)
        let workers = 2
        /// The fastest of three runs, in nanoseconds.
        func best(_ body: () -> Void) -> UInt64 {
            var best = UInt64.max
            for _ in 0..<3 {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                best = min(best, DispatchTime.now().uptimeNanoseconds - start)
            }
            return best
        }
        let container = sequentiallyEncoded(tree, accepting: generous(.file), policy: policy).container
        let sequentialEncode = best { _ = sequentiallyEncoded(tree, accepting: generous(.file), policy: policy) }
        let parallelEncode = best {
            let pipeline = ContainerEncodePipeline(accepting: generous(.file), policy: policy, workers: workers)
            _ = pipelined(tree, through: pipeline)
        }
        let pieces = pieces(of: container, sizes: [1 << 20])
        let sequentialDecode = best { _ = sequentiallyDecoded(pieces, accepting: generous(.file)) }
        let parallelDecode = best {
            let pipeline = ContainerDecodePipeline(accepting: generous(.file), workers: workers)
            _ = pipelined(pieces, through: pipeline)
        }
        // Loose, so a runner whose cores other suites are using does not fail it: the lanes must not lose half
        // again, not win.
        #expect(parallelEncode <= sequentialEncode * 3 / 2, "\(parallelEncode) ns against \(sequentialEncode) ns")
        #expect(parallelDecode <= sequentialDecode * 3 / 2, "\(parallelDecode) ns against \(sequentialDecode) ns")
    }
}
