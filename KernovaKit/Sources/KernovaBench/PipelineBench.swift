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

import Dispatch
import KernovaContainer
import KernovaContainerPipeline
import KernovaWire

/// `kernova-bench pipeline`: a tree's events encoded into a container and the container decoded back into events,
/// through the codec a transfer runs, per corpus and lane count, against the same tree sent plain.
///
/// Each corpus becomes a folder of files of `--entry-size` bytes, its events cut as a reader cuts them, and runs
/// through each path: plain storage through `ContainerEncoder` and `ContainerDecoder`; LZ4 storage through them,
/// every chunk tried in the caller; and LZ4 storage through `ContainerEncodePipeline` and `ContainerDecodePipeline`
/// on each lane count. Decoding feeds the container in pieces of `--feed-size`, as a transport hands it over.
/// Every path's decoded bytes are checked against the corpus before anything is timed.
struct PipelineBench {
    struct Options {
        var workers: [Int] = []
        var entrySize = 4 << 20
        var feedSize = WireConstants.maxRawDataPayload
        var runs = 5
        var abandonAfter: Int? = TransferCompression.abandonAfterUnshrunkChunks
        var corpora: [(name: String, source: CorpusSource)] = []

        init(parsing arguments: [String]) throws(UsageError) {
            var remaining = arguments[...]
            func value(for flag: String) throws(UsageError) -> String {
                guard let value = remaining.popFirst() else { throw UsageError(message: "\(flag) needs a value") }
                return value
            }
            func number(_ text: String, for flag: String, least: Int) throws(UsageError) -> Int {
                guard let number = Int(text), number >= least else {
                    throw UsageError(message: "\(flag) takes an integer of at least \(least), not \(text)")
                }
                return number
            }
            while let argument = remaining.popFirst() {
                switch argument {
                case "--entry-size": entrySize = try number(value(for: argument), for: argument, least: 1)
                case "--feed-size": feedSize = try number(value(for: argument), for: argument, least: 1)
                case "--runs": runs = try number(value(for: argument), for: argument, least: 1)
                case "--abandon-after":
                    let text = try value(for: argument)
                    abandonAfter = text == "never" ? nil : try number(text, for: argument, least: 1)
                case "--workers":
                    workers = []
                    for part in try value(for: argument).split(separator: ",") {
                        workers.append(try number(String(part), for: argument, least: 0))
                    }
                default:
                    corpora.append(try CorpusSource.parse(argument))
                }
            }
            guard !corpora.isEmpty else { throw UsageError(message: "no corpus named") }
            if workers.isEmpty { workers = defaultThreadCounts() }
        }
    }

    /// One way through the codec.
    enum Path: CustomStringConvertible {
        /// Plain storage, encoded and decoded in the caller.
        case plain
        /// LZ4 storage, every chunk tried and decompressed in the caller.
        case inCaller
        /// LZ4 storage through the pipelines, on this many lanes.
        case pipeline(Int)

        var description: String {
            switch self {
            case .plain: "plain"
            case .inCaller: "lz4, in caller"
            case .pipeline: "lz4, pipeline"
            }
        }

        var lanes: String {
            if case .pipeline(let count) = self { String(count) } else { "–" }
        }

        var storesLZ4: Bool {
            if case .plain = self { false } else { true }
        }
    }

    /// The times of one encode or decode.
    struct Sample {
        var wall: Double
        var cpu: Double?
    }

    let options: Options

    private var policy: ChunkCompressionPolicy {
        ChunkCompressionPolicy(attemptsLZ4: true, abandonAfterUnshrunkChunks: options.abandonAfter)
    }

    func run() {
        let info = ProcessInfo.processInfo
        print("kernova-bench pipeline")
        print("")
        print("- system: \(info.operatingSystemVersionString)")
        print("- active cores: \(info.activeProcessorCount)")
        print("- entry size: \(options.entrySize) bytes; chunk size: \(ContainerEncoder.chunkByteCount) bytes")
        print("- feed size: \(options.feedSize) bytes")
        print("- abandon after: \(options.abandonAfter.map(String.init) ?? "never") unshrunk chunks")
        print("- runs per cell: \(options.runs), after one untimed; medians")
        print("- CPU time: \(cpuSeconds() == nil ? "unavailable" : "user and system, every thread of the process")")
        print("- load before: \(loadAverage())")
        print("")
        print(
            "| Corpus | Path | Lanes | Encode MiB/s | Encode CPU s/GiB | Decode MiB/s | Decode CPU s/GiB "
                + "| Sent / input |"
        )
        print("|---|---|---|---|---|---|---|---|")
        for corpus in options.corpora {
            let bytes = corpus.source.load()
            guard !bytes.isEmpty else { KernovaBench.fail("\(corpus.name) is empty") }
            for path in [Path.plain, .inCaller] + options.workers.map(Path.pipeline) {
                measure(corpus.name, bytes, path)
            }
        }
        print("")
        print("- load after: \(loadAverage())")
    }

    private func measure(_ name: String, _ bytes: Data, _ path: Path) {
        let events = Self.events(of: bytes, entrySize: options.entrySize, lz4: path.storesLZ4)
        let acceptance = ContainerAcceptance(storage: .folder, byteCeiling: .max, decmpfsTypes: [], acceptsLZ4: true)
        var container = Data()
        var encodes: [Sample] = []
        var decodes: [Sample] = []
        for run in -1..<options.runs {
            let (encoded, encode) = timed { encode(events, acceptance, path) }
            let (decoded, decode) = timed { decode(encoded, acceptance, path) }
            if run < 0 {
                guard decoded == bytes.count, Self.decodedBytes(of: encoded, acceptance) == bytes else {
                    KernovaBench.fail("\(name), \(path) \(path.lanes): the container does not decode to the corpus")
                }
                container = encoded
                continue
            }
            encodes.append(encode)
            decodes.append(decode)
        }
        let gibibytes = Double(bytes.count) / Double(1 << 30)
        func rate(_ samples: [Sample]) -> String {
            fixed(Double(bytes.count) / (Spread(samples.map(\.wall))?.median ?? .nan) / Double(1 << 20), 1)
        }
        func cpu(_ samples: [Sample]) -> String {
            let cpus = samples.compactMap(\.cpu)
            return cpus.count == samples.count ? fixed((Spread(cpus)?.median ?? .nan) / gibibytes, 3) : "–"
        }
        let ratio = fixed(Double(container.count) / Double(bytes.count), 3)
        print(
            "| \(name) | \(path) | \(path.lanes) | \(rate(encodes)) | \(cpu(encodes)) "
                + "| \(rate(decodes)) | \(cpu(decodes)) | \(ratio) |"
        )
    }

    private func encode(_ events: [TreeEvent], _ acceptance: ContainerAcceptance, _ path: Path) -> Data {
        var container = Data()
        do {
            switch path {
            case .plain, .inCaller:
                var encoder = ContainerEncoder(accepting: acceptance, policy: path.storesLZ4 ? policy : .never)
                for event in events { container.append(try encoder.encode(event)) }
            case .pipeline(let lanes):
                let pipeline = ContainerEncodePipeline(accepting: acceptance, policy: policy, workers: lanes)
                for event in events { container.append(try pipeline.encode(event)) }
            }
        } catch {
            KernovaBench.fail("encoding failed: \(error)")
        }
        return container
    }

    /// Decodes `container` fed in pieces, returning the bytes its events carried.
    private func decode(_ container: Data, _ acceptance: ContainerAcceptance, _ path: Path) -> Int {
        var carried = 0
        func count(_ event: TreeEvent) {
            switch event {
            case .bytes(let bytes): carried += bytes.count
            case .zeros(let zeros): carried += Int(zeros)
            default: break
            }
        }
        do {
            switch path {
            case .plain, .inCaller:
                var decoder = ContainerDecoder(accepting: acceptance)
                for piece in pieces(of: container) {
                    decoder.feed(piece)
                    while let event = try decoder.next() { count(event) }
                }
                try decoder.finish()
            case .pipeline(let lanes):
                let pipeline = ContainerDecodePipeline(accepting: acceptance, workers: lanes)
                for piece in pieces(of: container) {
                    pipeline.feed(piece)
                    while let event = try pipeline.next() { count(event) }
                }
                pipeline.finish()
                while let event = try pipeline.next() { count(event) }
            }
        } catch {
            KernovaBench.fail("decoding failed: \(error)")
        }
        return carried
    }

    private func pieces(of container: Data) -> [Data] {
        stride(from: 0, to: container.count, by: options.feedSize).map {
            container[$0..<min($0 + options.feedSize, container.count)]
        }
    }

    /// The bytes `container`'s events carry, in order, decoded in the caller.
    private static func decodedBytes(of container: Data, _ acceptance: ContainerAcceptance) -> Data? {
        var decoder = ContainerDecoder(accepting: acceptance)
        decoder.feed(container)
        var bytes = Data()
        do {
            while let event = try decoder.next() {
                switch event {
                case .bytes(let chunk): bytes.append(chunk)
                case .zeros(let count): bytes.append(Data(count: Int(count)))
                default: break
                }
            }
            try decoder.finish()
        } catch {
            return nil
        }
        return bytes
    }

    /// A folder holding `bytes` as files of `entrySize` bytes, as a reader's events: each file's bytes in chunks.
    static func events(of bytes: Data, entrySize: Int, lz4: Bool) -> [TreeEvent] {
        var root = EntryHeader()
        root.type = .directory
        root.mode = 0o755
        var events: [TreeEvent] = [.enterDirectory(root)]
        for (index, start) in stride(from: 0, to: bytes.count, by: entrySize).enumerated() {
            let file = bytes[start..<min(start + entrySize, bytes.count)]
            var header = EntryHeader()
            header.depth = 1
            header.type = .file
            header.name = Data("file-\(index)".utf8)
            header.mode = 0o644
            if lz4 { header.lz4.size = UInt64(file.count) } else { header.plain.size = UInt64(file.count) }
            events.append(.beginFile(header))
            for chunk in stride(from: file.startIndex, to: file.endIndex, by: ContainerEncoder.chunkByteCount) {
                events.append(.bytes(file[chunk..<min(chunk + ContainerEncoder.chunkByteCount, file.endIndex)]))
            }
            events.append(.finishFile)
        }
        events += [.leaveDirectory, .end]
        return events
    }

    private func timed<Result>(_ body: () -> Result) -> (Result, Sample) {
        let cpuBefore = cpuSeconds()
        let start = DispatchTime.now().uptimeNanoseconds
        let result = body()
        let wall = Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-9
        let cpu = cpuSeconds().flatMap { after in cpuBefore.map { after - $0 } }
        return (result, Sample(wall: wall, cpu: cpu))
    }

    /// The process's user and system CPU seconds, every thread's, where the platform reports them.
    private func cpuSeconds() -> Double? {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        #if canImport(Glibc)
        // Glibc imports `RUSAGE_SELF` as a C enum, where Darwin and musl take an `Int32`.
        let who = __rusage_who_t(RUSAGE_SELF.rawValue)
        #else
        let who = RUSAGE_SELF
        #endif
        var usage = rusage()
        guard getrusage(who, &usage) == 0 else { return nil }
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) * 1e-6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
        #else
        return nil
        #endif
    }
}
