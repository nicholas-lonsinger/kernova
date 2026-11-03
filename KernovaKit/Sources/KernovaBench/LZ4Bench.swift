#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@preconcurrency import Dispatch
import KernovaSynchronization

/// `kernova-bench lz4`: block encode and decode throughput per corpus and thread count.
///
/// Each cell runs pairs of samples, one per coder, alternating which goes first, over the same blocks. A sample
/// is every thread taking blocks from a shared counter until the sample's share is done, timed by the wall
/// clock. On a loaded machine the absolute rates move with the load; the per-pair ratio of the two coders,
/// timed back to back over the same blocks, moves far less.
struct LZ4Bench {
    struct Options {
        var blockSize = 262_144
        var threads: [Int] = []
        var pairs = 25
        var encodeSample = 8 << 20
        var decodeSample = 32 << 20
        var corpora: [(name: String, source: CorpusSource)] = []

        init(parsing arguments: [String]) throws(UsageError) {
            var remaining = arguments[...]
            func value(for flag: String) throws(UsageError) -> String {
                guard let value = remaining.popFirst() else { throw UsageError(message: "\(flag) needs a value") }
                return value
            }
            func positive(_ text: String, for flag: String) throws(UsageError) -> Int {
                guard let number = Int(text), number > 0 else {
                    throw UsageError(message: "\(flag) takes a positive integer, not \(text)")
                }
                return number
            }
            while let argument = remaining.popFirst() {
                switch argument {
                case "--block-size": blockSize = try positive(value(for: argument), for: argument)
                case "--pairs": pairs = try positive(value(for: argument), for: argument)
                case "--encode-sample": encodeSample = try positive(value(for: argument), for: argument)
                case "--decode-sample": decodeSample = try positive(value(for: argument), for: argument)
                case "--threads":
                    threads = []
                    for part in try value(for: argument).split(separator: ",") {
                        threads.append(try positive(String(part), for: argument))
                    }
                default:
                    corpora.append(try CorpusSource.parse(argument))
                }
            }
            guard !corpora.isEmpty else { throw UsageError(message: "no corpus named") }
            if threads.isEmpty { threads = defaultThreadCounts() }
        }
    }

    let options: Options

    func run() {
        let info = ProcessInfo.processInfo
        print("kernova-bench lz4")
        print("system\t\(info.operatingSystemVersionString)\tactive cores \(info.activeProcessorCount)")
        print("block size\t\(options.blockSize)")
        print("coders\t\(Coder.allCases.map(\.rawValue).joined(separator: ", "))")
        print("pairs per cell\t\(options.pairs)")
        let workspaces = (0..<(options.threads.max() ?? 1)).map { _ in Workspace(blockSize: options.blockSize) }
        for corpus in options.corpora {
            run(corpus.name, corpus.source.load(), workspaces: workspaces)
        }
        print("sink\t\(workspaces.reduce(0) { $0 &+ $1.sink })")
    }

    private func run(_ name: String, _ bytes: Data, workspaces: [Workspace]) {
        let blocks = stride(from: 0, to: bytes.count, by: options.blockSize).map {
            Data(bytes[$0..<min($0 + options.blockSize, bytes.count)])
        }
        guard !blocks.isEmpty else { KernovaBench.fail("\(name) is empty") }
        print("")
        print("corpus\t\(name)\t\(bytes.count) bytes\t\(blocks.count) blocks")
        print("load before\t\(loadAverage())")

        // Every coder's output decodes through every coder to the original block before anything is timed.
        let workspace = workspaces[0]
        var encodedSizes: [Coder: Int] = [:]
        var shrunk: [(index: Int, block: Data)] = []
        var digest = FNV1a()
        for (index, block) in blocks.enumerated() {
            for encoder in Coder.allCases {
                guard let encoded = encoder.encoded(block, in: workspace) else {
                    encodedSizes[encoder, default: 0] += block.count
                    continue
                }
                encodedSizes[encoder, default: 0] += encoded.count
                if encoder == .swift {
                    shrunk.append((index, encoded))
                    digest.add(encoded)
                }
                for decoder in Coder.allCases where decoder.decoded(encoded, size: block.count, in: workspace) != block
                {
                    KernovaBench.fail(
                        "\(name) block \(index): \(encoder.rawValue)'s block does not decode through \(decoder.rawValue)"
                    )
                }
            }
        }
        let swiftBlocks = shrunk
        for coder in Coder.allCases {
            let ratio = Double(encodedSizes[coder, default: 0]) / Double(bytes.count)
            print("ratio\t\(coder.rawValue)\t\(fixed(ratio, 3))")
        }
        print("swift blocks\t\(swiftBlocks.count) of \(blocks.count) shrink\tdigest \(digest.hex)")

        print("op\tthreads\tcoder\tGiB/s median [IQR]\tswift/apple per pair, median [IQR]")
        for threads in options.threads {
            let encode = cell(
                items: blocks.map(\.count), threads: threads, sampleBytes: options.encodeSample,
                workspaces: workspaces
            ) { coder, item, workspace in
                coder.encode(blocks[item], in: workspace)
            }
            report("encode", threads, encode)
            guard !swiftBlocks.isEmpty else {
                print("decode\t\(threads)\tno block shrinks")
                continue
            }
            let decode = cell(
                items: swiftBlocks.map { blocks[$0.index].count }, threads: threads, sampleBytes: options.decodeSample,
                workspaces: workspaces
            ) { coder, item, workspace in
                coder.decode(swiftBlocks[item].block, size: blocks[swiftBlocks[item].index].count, in: workspace)
            }
            report("decode", threads, decode)
        }
        print("load after\t\(loadAverage())")
    }

    private struct Cell {
        var rates: [Coder: [Double]] = [:]
        /// Swift's rate over Apple's within each pair.
        var ratios: [Double] = []
    }

    private func report(_ operation: String, _ threads: Int, _ cell: Cell) {
        let ratio = Spread(cell.ratios).map { $0.formatted(3) } ?? "–"
        for coder in Coder.allCases {
            let rates = Spread(cell.rates[coder, default: []]).map { $0.formatted(3) } ?? "–"
            print("\(operation)\t\(threads)\t\(coder.rawValue)\t\(rates)\t\(coder == .swift ? ratio : "")")
        }
    }

    /// Times `options.pairs` pairs of samples over `items`, whose decoded sizes are given, after one untimed pair.
    private func cell(
        items: [Int], threads: Int, sampleBytes: Int, workspaces: [Workspace],
        work: @escaping @Sendable (Coder, Int, Workspace) -> Int
    ) -> Cell {
        let perThread = max(1, sampleBytes / options.blockSize)
        let sampleCount = perThread * threads
        var result = Cell()
        for pair in -1..<options.pairs {
            let start = (max(pair, 0) * sampleCount) % items.count
            let sample = (0..<sampleCount).map { (start + $0) % items.count }
            let sampleBytes = sample.reduce(0) { $0 + items[$1] }
            var order = Coder.allCases
            if pair & 1 == 1 { order.reverse() }
            var rates: [Coder: Double] = [:]
            for coder in order {
                let next = Locked(0)
                let started = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.concurrentPerform(iterations: threads) { thread in
                    let workspace = workspaces[thread]
                    while true {
                        let taken = next.withLock { taken -> Int in
                            defer { taken += 1 }
                            return taken
                        }
                        guard taken < sample.count else { return }
                        workspace.sink &+= work(coder, sample[taken], workspace)
                    }
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) * 1e-9
                rates[coder] = Double(sampleBytes) / elapsed / Double(1 << 30)
            }
            guard pair >= 0 else { continue }
            for (coder, rate) in rates { result.rates[coder, default: []].append(rate) }
            #if canImport(Compression)
            if let swift = rates[.swift], let apple = rates[.apple] { result.ratios.append(swift / apple) }
            #endif
        }
        return result
    }
}

/// FNV-1a over every Swift-encoded block, so runs of two builds can show they wrote the same bytes.
struct FNV1a {
    private var state: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func add(_ bytes: Data) {
        for byte in bytes {
            state = (state ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }

    var hex: String {
        let digits = String(state, radix: 16)
        return String(repeating: "0", count: 16 - digits.count) + digits
    }
}
