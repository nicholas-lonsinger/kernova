#if canImport(Darwin) || os(Linux)
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
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaContainerPipeline
import KernovaFileTree
import KernovaItemTransfer
import KernovaLogging
import KernovaPortableTestSupport
import KernovaSynchronization
import KernovaTreeTransfer
import KernovaWire
import Testing

/// The item adapters moving a representation from a source to a sink, effect by effect, as the core drives them.
@Suite("Item adapters")
struct ItemAdapterTests {
    @Test("a termination discard after the pull's own abort still removes the landing before it returns")
    func discardAfterAbortRemoves() async throws {
        let bench = try Bench()
        // Incompressible, so the source sends every byte and the lane has them all to write.
        var generator = SplitMix64(seed: 1)
        try bench.write(generator.bytes(40_000_000), to: "source/big.bin")
        try bench.makeDirectory("landed")
        let fileSystem = POSIXTreeFileSystem()
        let source = ItemSourceAdapter(fileSystem: fileSystem, sendingCores: 8, logger: Bench.logger) { _, _, _, _ in
            .success(.tree(path: bench.path("source/big.bin")))
        }
        let sink = ItemSinkAdapter(fileSystem: fileSystem, decodingWorkers: 2)
        let order = try sink.order(
            token: Data(count: 16), item: 0, representation: 0, byteCeiling: 1 << 30,
            landing: .exactPath(bench.path("landed/big.bin")))
        var representation = Representation()
        representation.storage = .file
        let (sources, sourceReporter) = Inbox<ItemSourceInput>.make {
            ItemSourceReporter(ItemConnection(role: .sessionPeer), $0)
        }
        let (sinks, sinkReporter) = Inbox<ItemSinkInput>.make { ItemSinkReporter(ItemConnection(role: .host), $0) }
        source.handle(.serve(Bench.id, .clipboard, order.request, representation), reporter: sourceReporter)
        defer { source.handle(.release(Bench.id), reporter: sourceReporter) }
        sink.handle(.begin(Bench.id, order, representation), reporter: sinkReporter)
        // Land the first bytes, so the root exists under its final name.
        while (try? bench.names("landed"))?.isEmpty ?? true {
            source.handle(.read(Bench.id, maxBytes: WireConstants.maxRawDataPayload), reporter: sourceReporter)
            guard case .bytes(_, let bytes)? = try await sources.next() else {
                Issue.record("the source finished before the landing began")
                return
            }
            sink.handle(.bytes(Bench.id, bytes), reporter: sinkReporter)
            #expect(try await sinks.next() == .consumed(Bench.id, bytes.count))
        }
        // Queue more writes on the pull's lane, unawaited, as a pull mid-copy has.
        var queued: [Data] = []
        for _ in 0..<24 {
            source.handle(.read(Bench.id, maxBytes: WireConstants.maxRawDataPayload), reporter: sourceReporter)
            guard case .bytes(_, let bytes)? = try await sources.next() else { break }
            queued.append(bytes)
        }
        for bytes in queued { sink.handle(.bytes(Bench.id, bytes), reporter: sinkReporter) }
        // The hub queue's abort for the termination's own cancel lands first.
        sink.handle(.abort(Bench.id), reporter: sinkReporter)
        sink.discardForTermination()

        #expect(try bench.names("landed").isEmpty, "discardForTermination returned with a landing still on disk")
    }

    @Test("a pull begun after a termination discard opens nothing")
    func beginAfterDiscardOpensNothing() throws {
        let bench = try Bench()
        let sink = ItemSinkAdapter(fileSystem: POSIXTreeFileSystem(), decodingWorkers: 0)
        let reports = Locked<[ItemSinkInput]>([])
        let reporter = ItemSinkReporter(ItemConnection(role: .host)) { report in
            reports.withLock { $0.append(report) }
        }
        var representation = Representation()
        representation.storage = .file
        // A directory that does not exist: a pull that begins reports it refused.
        let order = ItemPullOrder(
            PullRequest(), landing: .staged(directory: bench.path("missing"), name: .exactly(Data("item".utf8))))
        sink.discardForTermination()

        sink.handle(.begin(Bench.id, order, representation), reporter: reporter)
        // Waits on every lane there is, so a lane the begin opened has run.
        sink.discardForTermination()

        #expect(reports.withLock { $0 }.isEmpty)
    }

    @Test("a tree that cannot be read is logged as an error naming its entry, whether it fails opening or midway")
    func readFailureLogged() async throws {
        let bench = try Bench()
        try bench.makeDirectory("source/Folder")
        try #require(mkfifo(bench.path("source/Folder/pipe"), 0o644) == 0)
        typealias Case = (
            content: String, storage: Representation.Storage, path: String, reason: TreeReadFailure.Reason
        )
        let cases: [Case] = [
            ("missing/x", .file, "x", .system(TreeFileSystemError(code: ENOENT))),
            ("source/Folder", .folder, "Folder/pipe", .notCarried(.type(.fifo))),
        ]
        for (content, storage, path, reason) in cases {
            let records = Locked<[(KernovaLogLevel, [LogSegment])]>([])
            let logger = KernovaLogger(
                subsystem: "app.kernova.tests", category: "ItemSource",
                sink: .init {
                    level, _, _, segments in
                    records.withLock { $0.append((level, segments)) }
                })
            let error = try await bench.serveFailure(
                .success(.tree(path: bench.path(content))), storage, logger: logger)
            #expect(error?.code == .readFailed, "\(content)")
            #expect(error?.debugDetail == reason.description, "\(content)")
            let logged = records.withLock { $0 }
            #expect(logged.count == 1, "\(content)")
            #expect(logged.first?.0 == .error, "\(content)")
            let segments = logged.first?.1 ?? []
            #expect(segments.contains(LogSegment(text: path, isPrivate: true)), "\(content): \(segments)")
            #expect(segments.contains(LogSegment(text: reason.description, isPrivate: false)), "\(content)")
        }
    }

    @Test("an exact path's order asks its volume through the path alone, leaving nothing there or beside it")
    func exactPathOrder() throws {
        let bench = try Bench()
        try bench.makeDirectory("landed")
        let fileSystem = POSIXTreeFileSystem()
        let sink = ItemSinkAdapter(fileSystem: fileSystem)
        let directory = try fileSystem.openDirectory(Array(bench.path("landed").utf8), in: AT_FDCWD)
        defer { fileSystem.close(directory) }

        let order = try sink.order(
            token: Data(count: 16), item: 0, representation: 0, byteCeiling: 9,
            landing: .exactPath(bench.path("landed/x.jpg")))

        #expect(
            order.request.decmpfsTypes
                == (try DecmpfsMatrix.acceptedTypes(landingIn: directory, on: fileSystem)).sorted())
        #expect(try bench.names("landed").isEmpty)
        try bench.write(Data("old".utf8), to: "landed/x.jpg")
        let taken = #expect(throws: WireError.self) {
            try sink.order(
                token: Data(count: 16), item: 0, representation: 0, byteCeiling: 9,
                landing: .exactPath(bench.path("landed/x.jpg")))
        }
        #expect(taken?.posixErrno == EEXIST)
        #expect(try bench.read("landed/x.jpg") == Data("old".utf8))
        #expect(throws: WireError.self) {
            try sink.order(
                token: Data(count: 16), item: 0, representation: 0, byteCeiling: 9, landing: .exactPath("x.jpg"))
        }
    }
}

/// A scratch directory, and a source and a sink moving one pull through it.
final class Bench: Sendable {
    static let id = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2))
    /// A logger that records nothing.
    static let logger = KernovaLogger(
        subsystem: "app.kernova.tests", category: "ItemSource", sink: .init { _, _, _, _ in })

    let scratch: PortableScratchDirectory

    init() throws {
        scratch = try PortableScratchDirectory(prefix: "item-adapters")
    }

    func path(_ relative: String) -> String { scratch.path + "/" + relative }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    func write(_ data: Data, to relative: String) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func read(_ relative: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: path(relative)))
    }

    func names(_ relative: String) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: path(relative)).sorted()
    }

    /// The error a serve of `content` as a representation of `storage` fails with, or nil when it does not.
    func serveFailure(
        _ content: Result<ItemContent, WireError>, _ storage: Representation.Storage, ceiling: UInt64 = 1 << 30,
        logger: KernovaLogger = Bench.logger
    ) async throws -> WireError? {
        let source = ItemSourceAdapter(fileSystem: POSIXTreeFileSystem(), logger: logger) { _, _, _, _ in content }
        var request = PullRequest()
        request.byteCeiling = ceiling
        var representation = Representation()
        representation.storage = storage
        let (sources, reporter) = Inbox<ItemSourceInput>.make { ItemSourceReporter(ItemConnection(role: .host), $0) }
        source.handle(.serve(Self.id, .clipboard, request, representation), reporter: reporter)
        while true {
            source.handle(.read(Self.id, maxBytes: WireConstants.maxRawDataPayload), reporter: reporter)
            switch try await sources.next() {
            case .failed(_, let error)?: return error
            case .bytes?: continue
            default: return nil
            }
        }
    }
}

/// The reports an adapter makes, in order, awaited one at a time.
struct Inbox<Element: Sendable>: Sendable {
    private let stream: AsyncStream<Element>

    static func make<Reporter>(_ reporter: (@escaping @Sendable (Element) -> Void) -> Reporter) -> (Inbox, Reporter) {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        return (Inbox(stream: stream), reporter { continuation.yield($0) })
    }

    /// The next report, or `nil` once the reporter is gone.
    func next(fileID: String = #fileID, line: Int = #line) async throws -> Element? {
        let stream = stream
        return try await Backstop("Inbox.next()", fileID: fileID, line: line).run {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
    }
}
#endif
