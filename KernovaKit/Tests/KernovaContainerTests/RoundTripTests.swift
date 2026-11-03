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

    @Test(
        "Every entry type and storage survives encoding and decoding",
        arguments: [ChunkCompressionPolicy.never, lz4Always], [1_000, 100_000, 1_000_000])
    func mixedTree(policy: ChunkCompressionPolicy, pieceSize: Int) throws {
        let fixture = TreeFixture.mixed()
        let container = try fixture.encoded(policy: policy, pieceSize: pieceSize)
        let decoded = decode(container, pieceSize: 65_536)
        #expect(decoded.error == nil)
        #expect(coalesced(decoded.events) == fixture.expectedEvents)
    }

    @Test("A compressible chunk of an LZ4 entry goes as an LZ4 chunk only when the policy tries it")
    func lz4OnlyWhenPolicyTries() throws {
        let fixture = TreeFixture.mixed()
        let tried = try fixture.encoded(policy: Self.lz4Always)
        #expect(recordOffsets(tried).contains { $0.kind == .lz4Chunk })
        #expect(tried.count < (try fixture.encoded(policy: .never)).count)
        #expect(!recordOffsets(try fixture.encoded(policy: .never)).contains { $0.kind == .lz4Chunk })
    }

    @Test("Plain storage never carries an LZ4 chunk, whatever the policy")
    func plainStorageStaysRaw() throws {
        let text = Data(String(repeating: "plain ", count: 10_000).utf8)
        let fixture = TreeFixture(entries: [(plainFile(depth: 0, size: UInt64(text.count)), text)])
        let container = try fixture.encoded(policy: Self.lz4Always)
        #expect(!recordOffsets(container).contains { $0.kind == .lz4Chunk })
    }

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

    @Test("Consecutive all-zero chunks become one zero run, written before the next data or at the entry's end")
    func zeroRuns() throws {
        let size = ContainerEncoder.chunkByteCount
        var bytes = Data(count: 4 * size + 10)
        bytes[2 * size] = 1
        let fixture = TreeFixture(entries: [(plainFile(depth: 0, size: UInt64(bytes.count)), bytes)])
        let container = try fixture.encoded(pieceSize: bytes.count)
        #expect(recordOffsets(container).map(\.kind) == [.header, .zeroRun, .chunk, .zeroRun, .end])
        let decoded = decode(container)
        #expect(decoded.error == nil)
        #expect(decoded.events.contains(.zeros(UInt64(2 * size))))
        #expect(decoded.events.contains(.zeros(UInt64(size + 10))))
        #expect(content(of: decoded.events) == bytes)
    }

    @Test("A zero run spans the encoder's calls")
    func zeroRunAcrossCalls() throws {
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        var container = try encoder.entry(plainFile(depth: 0, size: 300))
        for _ in 0..<3 {
            let records = try encoder.bytes(Data(count: 100))
            container += records
        }
        container += try encoder.end()
        #expect(recordOffsets(container).map(\.kind) == [.header, .zeroRun, .end])
        #expect(decode(container).events.contains(.zeros(300)))
    }

    @Test("A declared zero run lands as exactly that run, merged with the zeros beside it, however short")
    func declaredZeros() throws {
        var encoder = ContainerEncoder(accepting: generous(), policy: .never)
        var container = try encoder.entry(plainFile(depth: 0, size: 4096 * 3 + 300))
        container += try encoder.bytes(Data(repeating: 7, count: 4096))
        container += try encoder.zeros(4096)
        container += try encoder.bytes(Data(count: 100))
        container += try encoder.zeros(4096)
        container += try encoder.bytes(Data(repeating: 9, count: 200))
        container += try encoder.end()
        #expect(recordOffsets(container).map(\.kind) == [.header, .chunk, .zeroRun, .chunk, .end])
        let decoded = decode(container)
        #expect(decoded.error == nil)
        #expect(decoded.events.contains(.zeros(4096 * 2 + 100)))

        var trailing = ContainerEncoder(accepting: generous(), policy: .never)
        var ending = try trailing.entry(plainFile(depth: 0, size: 5000))
        ending += try trailing.bytes(Data([1]))
        ending += try trailing.zeros(4999)
        #expect(recordOffsets(ending).map(\.kind) == [.header, .chunk, .zeroRun])
        #expect(throws: ContainerError.chunkOutsideEntry) { try trailing.zeros(1) }
    }

    @Test("Encoding a tree's events writes what the encoder's own calls write, and refuses a file finished short")
    func encodesEvents() throws {
        let fixture = TreeFixture.mixed()
        // Each file's bytes in one call, as `expectedEvents` carries them.
        let direct = try fixture.encoded(pieceSize: 1 << 40)
        var encoder = ContainerEncoder(accepting: generous(for: direct), policy: .never)
        var container = Data()
        for event in fixture.expectedEvents { container += try encoder.encode(event) }
        #expect(container == direct)

        var short = ContainerEncoder(accepting: generous(), policy: .never)
        _ = try short.encode(.beginFile(plainFile(depth: 0, size: 2)))
        _ = try short.encode(.bytes(Data([1])))
        #expect(throws: ContainerError.entryIncomplete(remaining: 1)) { try short.encode(.finishFile) }
    }

    @Test("INLINE data round-trips as one bare DATA entry")
    func inline() throws {
        let bytes = Data("clipboard text".utf8)
        let fixture = TreeFixture(entries: [(inlineData(size: UInt64(bytes.count)), bytes)])
        let decoded = decode(try fixture.encoded())
        #expect(coalesced(decoded.events) == fixture.expectedEvents)
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

    @Test("Seeded random trees round-trip", arguments: 0..<20)
    func randomTrees(seed: UInt64) throws {
        var generator = SplitMix64(seed: seed)
        var entries: [(header: EntryHeader, bytes: Data)] = [(directory(depth: 0), Data())]
        var entered = 1
        for index in 0..<Int.random(in: 1...30, using: &generator) {
            let depth = UInt32(Int.random(in: 1...entered, using: &generator))
            entered = Int(depth)
            switch Int.random(in: 0..<4, using: &generator) {
            case 0:
                entries.append((directory("d\(index)", depth: depth), Data()))
                entered += 1
            case 1:
                entries.append((symlink("s\(index)", depth: depth, target: "t"), Data()))
            default:
                let size = Int.random(in: 0...600_000, using: &generator)
                var bytes = Bool.random(using: &generator) ? generator.bytes(size) : Data(count: size)
                if size > 0, Bool.random(using: &generator) { bytes[size / 2] = 0x41 }
                let header =
                    Bool.random(using: &generator)
                    ? lz4File("f\(index)", depth: depth, size: UInt64(size))
                    : plainFile("f\(index)", depth: depth, size: UInt64(size))
                entries.append((header, bytes))
            }
        }
        let fixture = TreeFixture(entries: entries)
        let container = try fixture.encoded(
            policy: Self.lz4Always, pieceSize: Int.random(in: 1_000...400_000, using: &generator))
        let decoded = decode(container, pieceSize: Int.random(in: 1...300_000, using: &generator))
        #expect(decoded.error == nil)
        #expect(coalesced(decoded.events) == fixture.expectedEvents)
    }
}
