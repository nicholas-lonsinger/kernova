#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaContainer
import KernovaContainerPipeline
import KernovaPortableTestSupport
import KernovaSynchronization
import KernovaWire

/// Lanes whose work each runs after a spin of a random length, counting the work started, finished and running.
final class SpinningLanes: Sendable {
    private struct State {
        var random: SplitMix64
        var started = 0
        var finished = 0
        var sink: UInt64 = 0
    }

    private let state: Locked<State>
    private let maxSpin: Int

    /// Lanes spinning up to `maxSpin` steps before each piece of work, the lengths drawn from `seed`.
    init(seed: UInt64, maxSpin: Int = 20_000) {
        state = Locked(State(random: SplitMix64(seed: seed)))
        self.maxSpin = maxSpin
    }

    /// The work handed to the lanes that has started.
    var started: Int { state.withLock(\.started) }
    /// The work started and not yet returned.
    var running: Int { state.withLock { $0.started - $0.finished } }

    /// `count` lanes of these.
    func workers(_ count: Int) -> ChunkWorkers {
        ChunkWorkers(count: count) { _, work in
            let steps = self.state.withLock { state -> Int in
                state.started += 1
                return self.maxSpin == 0 ? 0 : Int(state.random.next() % UInt64(self.maxSpin + 1))
            }
            let spun = spin(steps)
            work()
            self.state.withLock { state in
                state.finished += 1
                state.sink &+= spun
            }
        }
    }
}

/// A value from `steps` rounds of arithmetic, taking time without sleeping.
func spin(_ steps: Int) -> UInt64 {
    var value: UInt64 = 0x9E37_79B9_7F4A_7C15
    for step in 0..<steps { value = value &* 6_364_136_223_846_793_005 &+ UInt64(step) }
    return value
}

/// A random tree of every entry type and storage, as the events a reader would produce, its files' bytes in pieces
/// of random sizes and some all-zero pieces as zero runs.
struct RandomTree {
    var storage: Representation.Storage
    var events: [TreeEvent]

    var acceptance: ContainerAcceptance { generous(storage) }

    init(seed: UInt64) {
        var random = SplitMix64(seed: seed)
        var events: [TreeEvent] = []
        func pick(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &random) }

        switch seed % 4 {
        case 0:
            storage = .inline
            let content = Self.content(size: pick(1...700_000), using: &random)
            var header = inlineData(size: UInt64(content.count))
            if pick(0...1) == 1 { header.lz4.size = UInt64(content.count) }
            events.append(.beginFile(header))
            events += Self.pieces(of: content, using: &random)
            events.append(.finishFile)
        case 1:
            storage = .file
            events += Self.file(depth: 0, kind: pick(0...2), using: &random)
        default:
            storage = .folder
            events.append(.enterDirectory(directory(depth: 0)))
            var entered = 1
            // A plain, an LZ4 and a decmpfs file first, so every tree holds every storage.
            let count = pick(3...10)
            for index in 0..<count {
                let depth = index < 3 ? entered : pick(1...entered)
                for _ in 0..<(entered - depth) { events.append(.leaveDirectory) }
                entered = depth
                let name = "e\(index)"
                switch index < 3 ? 3 + index : pick(0...9) {
                case 0, 1:
                    events.append(.enterDirectory(directory(name, depth: UInt32(depth))))
                    entered += 1
                case 2:
                    events.append(.symlink(symlink(name, depth: UInt32(depth), target: "elsewhere/\(index)")))
                case 3, 4, 5:
                    events += Self.file(
                        name, depth: UInt32(depth), kind: index < 3 ? index : pick(0...2), using: &random)
                default:
                    events += Self.file(name, depth: UInt32(depth), kind: pick(0...1), using: &random)
                }
            }
            for _ in 0..<entered { events.append(.leaveDirectory) }
        }
        events.append(.end)
        self.events = events
    }

    /// A file's events: `kind` 0 plain, 1 LZ4, 2 decmpfs; a plain or LZ4 file sometimes with a resource fork.
    private static func file(_ name: String = "", depth: UInt32, kind: Int, using random: inout SplitMix64)
        -> [TreeEvent]
    {
        var events: [TreeEvent] = []
        let fork =
            Int.random(in: 0...2, using: &random) == 0 || kind == 2
            ? content(size: Int.random(in: 1...300_000, using: &random), using: &random) : Data()
        let header: EntryHeader
        var data = Data()
        switch kind {
        case 2:
            let type: UInt32 = Int.random(in: 0...1, using: &random) == 0 ? 3 : 4
            let tail = type == 3 ? random.bytes(64) : Data()
            let attribute = decmpfsAttribute(type: type, size: UInt64(fork.count) * 3, tail: tail)
            header = decmpfsFile(name, depth: depth, attribute: attribute, resourceForkSize: UInt64(fork.count))
        default:
            data = content(size: Int.random(in: 0...700_000, using: &random), using: &random)
            let plain = plainFile(name, depth: depth, size: UInt64(data.count))
            header = withResourceFork(
                kind == 1 ? lz4File(name, depth: depth, size: UInt64(data.count)) : plain, size: UInt64(fork.count))
        }
        events.append(.beginFile(header))
        events += pieces(of: data, using: &random)
        if !fork.isEmpty {
            events.append(.resourceFork)
            events += pieces(of: fork, using: &random)
        }
        events.append(.finishFile)
        return events
    }

    /// `bytes` as `bytes` and `zeros` events of random sizes.
    private static func pieces(of bytes: Data, using random: inout SplitMix64) -> [TreeEvent] {
        var events: [TreeEvent] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = min(start + Int.random(in: 1...400_000, using: &random), bytes.endIndex)
            let piece = bytes[start..<end]
            if piece.allSatisfy({ $0 == 0 }) && Bool.random(using: &random) {
                events.append(.zeros(UInt64(piece.count)))
            } else {
                events.append(.bytes(piece))
            }
            start = end
        }
        return events
    }

    private static let words = ["agent", "guest", "host", "chunk", "entry", "stream", "the", "a", "container", "lane"]
        .map { Data(($0 + " ").utf8) }

    /// `size` bytes of one kind: random, text, zeros, sparse, or text and random by halves.
    private static func content(size: Int, using random: inout SplitMix64) -> Data {
        switch Int.random(in: 0...4, using: &random) {
        case 0:
            return random.bytes(size)
        case 1:
            return text(size: size, using: &random)
        case 2:
            return Data(count: size)
        case 3:
            var sparse = Data(count: size)
            for _ in 0..<4 where size > 0 {
                let start = Int.random(in: 0..<size, using: &random)
                let end = min(size, start + Int.random(in: 1...20_000, using: &random))
                sparse.replaceSubrange(start..<end, with: random.bytes(end - start))
            }
            return sparse
        default:
            return text(size: size / 2, using: &random) + random.bytes(size - size / 2)
        }
    }

    private static func text(size: Int, using random: inout SplitMix64) -> Data {
        var text = Data()
        text.reserveCapacity(size + 16)
        while text.count < size { text.append(words[Int(random.next() % UInt64(words.count))]) }
        return text.prefix(size)
    }
}

/// What encoding a tree's events came to.
struct Encoded: Equatable {
    var container = Data()
    var error: ContainerError?
}

/// `events` encoded by `ContainerEncoder`.
func sequentiallyEncoded(
    _ events: [TreeEvent], accepting acceptance: ContainerAcceptance, policy: ChunkCompressionPolicy
)
    -> Encoded
{
    var encoder = ContainerEncoder(accepting: acceptance, policy: policy)
    var result = Encoded()
    for event in events {
        do {
            result.container.append(try encoder.encode(event))
        } catch {
            result.error = error
            return result
        }
    }
    return result
}

/// `events` encoded by `pipeline`.
func pipelined(_ events: [TreeEvent], through pipeline: ContainerEncodePipeline) -> Encoded {
    var result = Encoded()
    for event in events {
        do {
            result.container.append(try pipeline.encode(event))
        } catch {
            result.error = error
            return result
        }
    }
    return result
}

/// The sizes of the pieces a container is fed in, drawn from `seed`: from a byte to a few records.
func feedSizes(seed: UInt64) -> [Int] {
    var random = SplitMix64(seed: seed)
    return (0..<64).map { _ in
        switch random.next() % 3 {
        case 0: Int(random.next() % 64) + 1
        case 1: Int(random.next() % 300_000) + 1
        default: Int(random.next() % 1_200_000) + 1
        }
    }
}

/// `container` cut into pieces of `sizes`, cycling through them.
func pieces(of container: Data, sizes: [Int]) -> [Data] {
    var pieces: [Data] = []
    var start = container.startIndex
    var index = 0
    while start < container.endIndex {
        let end = min(start + sizes[index % sizes.count], container.endIndex)
        pieces.append(container[start..<end])
        start = end
        index += 1
    }
    return pieces
}

/// `pieces` decoded by `ContainerDecoder`, fed one at a time and drained after each, then finished.
func sequentiallyDecoded(_ pieces: [Data], accepting acceptance: ContainerAcceptance) -> Decoded {
    var decoder = ContainerDecoder(accepting: acceptance)
    var result = Decoded()
    do {
        for piece in pieces {
            decoder.feed(piece)
            while let event = try decoder.next() { result.events.append(event) }
        }
        try decoder.finish()
    } catch {
        result.error = error
    }
    return result
}

/// `pieces` decoded by `pipeline`, fed one at a time and drained after each, then finished and drained. `observe`
/// runs after every call.
func pipelined(
    _ pieces: [Data], through pipeline: ContainerDecodePipeline, observe: (ContainerDecodePipeline) -> Void = { _ in }
) -> Decoded {
    var result = Decoded()
    do {
        for piece in pieces {
            pipeline.feed(piece)
            while let event = try pipeline.next() {
                result.events.append(event)
                observe(pipeline)
            }
            observe(pipeline)
        }
        pipeline.finish()
        while let event = try pipeline.next() {
            result.events.append(event)
            observe(pipeline)
        }
    } catch {
        result.error = error
    }
    return result
}

extension Decoded: Equatable {
    static func == (lhs: Decoded, rhs: Decoded) -> Bool { lhs.events == rhs.events && lhs.error == rhs.error }
}
