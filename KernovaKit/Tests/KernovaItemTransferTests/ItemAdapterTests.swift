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
import KernovaPortableTestSupport
import KernovaTreeTransfer
import KernovaWire
import Testing

/// The item adapters moving a representation from a source to a sink, effect by effect, as the core drives them.
@Suite("Item adapters")
struct ItemAdapterTests {
    @Test("a FILE lands under the landing's name, compressed or not", arguments: [PeerRole.host, .sessionPeer])
    func fileLands(_ server: PeerRole) async throws {
        let bench = try Bench()
        let content = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        try bench.write(content, to: "source/report.bin")
        let landing = ItemLanding.tree(directory: bench.path("landed"), name: .exactly(Data("chosen.bin".utf8)))
        let result = try await bench.transfer(
            .tree(path: bench.path("source/report.bin")), .file, landing,
            servedBy: server)
        #expect(result == .published(Bench.id, .named(Data("chosen.bin".utf8))))
        #expect(try bench.read("landed/chosen.bin") == content)
        #expect(try bench.names("landed") == ["chosen.bin"])
    }

    @Test("a FOLDER lands whole under its Keep Both name, past the folder that has its name")
    func folderKeepsBoth() async throws {
        let bench = try Bench()
        try bench.write(Data("a".utf8), to: "source/Folder/a.txt")
        try bench.write(Data(repeating: 9, count: 300_000), to: "source/Folder/sub/b.bin")
        try bench.makeDirectory("landed/Folder")
        let landing = ItemLanding.tree(directory: bench.path("landed"), name: .keepingBoth(Data("Folder".utf8)))
        let result = try await bench.transfer(
            .tree(path: bench.path("source/Folder")), .folder, landing)
        #expect(result == .published(Bench.id, .named(Data("Folder 2".utf8))))
        #expect(try bench.read("landed/Folder 2/a.txt") == Data("a".utf8))
        #expect(try bench.read("landed/Folder 2/sub/b.bin") == Data(repeating: 9, count: 300_000))
        #expect(try bench.names("landed") == ["Folder", "Folder 2"])
        #expect(try bench.names("landed/Folder").isEmpty)
    }

    @Test(
        "INLINE bytes are served from the provider and published as bytes", arguments: [PeerRole.host, .sessionPeer])
    func inlineLands(_ server: PeerRole) async throws {
        let bench = try Bench()
        let bytes = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let result = try await bench.transfer(.inline(bytes), .inline, .inline, servedBy: server)
        #expect(result == .published(Bench.id, .inline(bytes)))
    }

    @Test(
        "a container compresses exactly when a guest serves it", arguments: [PeerRole.host, .sessionPeer, .systemPeer])
    func compressesGuestToHost(_ server: PeerRole) async throws {
        let bytes = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let served = try await Bench.container(.inline(bytes), servedBy: server).reduce(0) { $0 + $1.count }
        if server == .host {
            #expect(served > bytes.count)
        } else {
            #expect(served < bytes.count / 4)
        }
    }

    @Test("two connections' pulls of one id land apart through one sink")
    func connectionsLandApart() async throws {
        let first = Data(repeating: 1, count: 300_000)
        let second = Data(repeating: 2, count: 200_000)
        let connections = (ItemConnection(role: .host), ItemConnection(role: .host))
        #expect(connections.0 != connections.1)
        let containers = (
            try await Bench.container(.inline(first), servedBy: .sessionPeer),
            try await Bench.container(.inline(second), servedBy: .sessionPeer)
        )
        let sink = ItemSinkAdapter(fileSystem: POSIXTreeFileSystem(), decodingWorkers: 2)
        let order = try sink.order(
            token: Data(count: 16), item: 0, representation: 0, byteCeiling: 1 << 30, landing: .inline)
        var representation = Representation()
        representation.storage = .inline
        let (firstReports, firstReporter) = Inbox<ItemSinkInput>.make { ItemSinkReporter(connections.0, $0) }
        let (secondReports, secondReporter) = Inbox<ItemSinkInput>.make { ItemSinkReporter(connections.1, $0) }
        sink.handle(.begin(Bench.id, order, representation), reporter: firstReporter)
        sink.handle(.begin(Bench.id, order, representation), reporter: secondReporter)
        for index in 0..<max(containers.0.count, containers.1.count) {
            if index < containers.0.count {
                sink.handle(.bytes(Bench.id, containers.0[index]), reporter: firstReporter)
                #expect(await firstReports.next() == .consumed(Bench.id, containers.0[index].count))
            }
            if index < containers.1.count {
                sink.handle(.bytes(Bench.id, containers.1[index]), reporter: secondReporter)
                #expect(await secondReports.next() == .consumed(Bench.id, containers.1[index].count))
            }
        }
        for (reports, reporter) in [(firstReports, firstReporter), (secondReports, secondReporter)] {
            sink.handle(.finish(Bench.id), reporter: reporter)
            #expect(await reports.next() == .verified(Bench.id))
            sink.handle(.commit(Bench.id), reporter: reporter)
        }
        #expect(await firstReports.next() == .published(Bench.id, .inline(first)))
        #expect(await secondReports.next() == .published(Bench.id, .inline(second)))
    }

    @Test("a publish onto a taken exact name fails EEXIST and leaves only what was there")
    func publishFails() async throws {
        let bench = try Bench()
        try bench.write(Data("new".utf8), to: "source/doc.txt")
        try bench.write(Data("old".utf8), to: "landed/doc.txt")
        let landing = ItemLanding.tree(directory: bench.path("landed"), name: .exactly(Data("doc.txt".utf8)))
        let result = try await bench.transfer(
            .tree(path: bench.path("source/doc.txt")), .file, landing)
        guard case .publishFailed(_, let error)? = result else {
            Issue.record("\(String(describing: result))")
            return
        }
        #expect(error.code == .writeFailed)
        #expect(error.posixErrno == EEXIST)
        #expect(try bench.read("landed/doc.txt") == Data("old".utf8))
        #expect(try bench.names("landed") == ["doc.txt"])
    }

    @Test("content the owner cannot produce, or of another storage, fails the serve")
    func contentRefused() async throws {
        let bench = try Bench()
        let unavailable = WireError(.itemRepresentationUnavailable, debugDetail: "gone")
        #expect(try await bench.serveFailure(.failure(unavailable), .file) == unavailable)
        #expect(
            try await bench.serveFailure(.success(.inline(Data("x".utf8))), .file)?.code
                == .itemRepresentationUnavailable)
        #expect(
            try await bench.serveFailure(
                .success(.tree(path: bench.path("missing/x"))), .file)?
                .code == .readFailed)
    }

    @Test(
        "an item is served by its own path, though the folder it lies in cannot be opened",
        .enabled(if: geteuid() != 0, "root reads past every permission bit, as the Linux CI container runs"))
    func servedThroughItsOwnPath() async throws {
        let bench = try Bench()
        let content = Data("granted".utf8)
        try bench.write(content, to: "source/locked/report.bin")
        try bench.write(Data("b".utf8), to: "source/locked/Folder/b.txt")
        // Searchable but unreadable: the item's path resolves, and opening the folder to read it fails, as
        // a sandboxed app's open of a dropped item's folder does.
        try #require(chmod(bench.path("source/locked"), 0o111) == 0)
        defer { _ = chmod(bench.path("source/locked"), 0o755) }
        try #require(open(bench.path("source/locked"), O_RDONLY | O_DIRECTORY) == -1)
        let file = try await bench.transfer(
            .tree(path: bench.path("source/locked/report.bin")), .file,
            ItemLanding.tree(directory: bench.path("landed"), name: .exactly(Data("report.bin".utf8))))
        #expect(file == .published(Bench.id, .named(Data("report.bin".utf8))))
        #expect(try bench.read("landed/report.bin") == content)
        let folder = try await bench.transfer(
            .tree(path: bench.path("source/locked/Folder")), .folder,
            ItemLanding.tree(directory: bench.path("landed"), name: .exactly(Data("Folder".utf8))))
        #expect(folder == .published(Bench.id, .named(Data("Folder".utf8))))
        #expect(try bench.read("landed/Folder/b.txt") == Data("b".utf8))
    }

    @Test("a container past the pull's byte ceiling fails the serve TOO_LARGE, naming the ceiling")
    func ceiling() async throws {
        let bench = try Bench()
        let error = try await bench.serveFailure(.success(.inline(Data(count: 5_000))), .inline, ceiling: 1_000)
        #expect(error?.code == .tooLarge)
        #expect(error?.limit == 1_000)
    }

    @Test("a pull order names LZ4 and, for a tree, the decmpfs types its landing's volume reads back")
    func order() throws {
        let bench = try Bench()
        try bench.makeDirectory("landed")
        let fileSystem = POSIXTreeFileSystem()
        let sink = ItemSinkAdapter(fileSystem: fileSystem)
        let landing = ItemLanding.tree(directory: bench.path("landed"), name: .keepingBoth(Data("x".utf8)))
        let tree = try sink.order(token: Data(count: 16), item: 1, representation: 2, byteCeiling: 9, landing: landing)
        let directory = try fileSystem.openDirectory(Array(bench.path("landed").utf8), in: AT_FDCWD)
        defer { fileSystem.close(directory) }
        #expect(tree.landing == landing)
        #expect(
            tree.request.decmpfsTypes
                == (try DecmpfsMatrix.acceptedTypes(landingIn: directory, on: fileSystem)).sorted())
        #expect(tree.request.codecs == [.lz4])
        #expect((tree.request.item, tree.request.representation, tree.request.byteCeiling) == (1, 2, 9))
        let inline = try sink.order(
            token: Data(count: 16), item: 0, representation: 0, byteCeiling: 9, landing: .inline)
        #expect(inline.landing == .inline)
        #expect(inline.request.decmpfsTypes.isEmpty)
        #expect(throws: WireError.self) {
            try sink.order(
                token: Data(), item: 0, representation: 0, byteCeiling: 9,
                landing: .tree(directory: bench.path("missing"), name: .exactly(Data("x".utf8))))
        }
    }
}

/// A scratch directory, and a source and a sink moving one pull through it.
final class Bench: Sendable {
    static let id = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2))

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

    /// Serves `content` as a representation of `storage` from a side of role `server` and lands it as `landing`
    /// on the far side, as the core would: the sink's publish report, or its refusal, or nil when the source
    /// failed.
    func transfer(
        _ content: ItemContent, _ storage: Representation.Storage, _ landing: ItemLanding,
        servedBy server: PeerRole = .sessionPeer
    ) async throws -> ItemSinkInput? {
        if case .tree(let directory, _) = landing {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let fileSystem = POSIXTreeFileSystem()
        let source = ItemSourceAdapter(fileSystem: fileSystem, sendingCores: 8) { _, _, _ in .success(content) }
        let sink = ItemSinkAdapter(fileSystem: fileSystem, decodingWorkers: 2)
        let order = try sink.order(
            token: Data(count: 16), item: 0, representation: 0, byteCeiling: 1 << 30, landing: landing)
        var representation = Representation()
        representation.storage = storage
        let puller: PeerRole = server == .host ? .sessionPeer : .host
        let (sources, sourceReporter) = Inbox<ItemSourceInput>.make {
            ItemSourceReporter(ItemConnection(role: server), $0)
        }
        let (sinks, sinkReporter) = Inbox<ItemSinkInput>.make { ItemSinkReporter(ItemConnection(role: puller), $0) }
        source.handle(.serve(Self.id, .clipboard, order.request, representation), reporter: sourceReporter)
        sink.handle(.begin(Self.id, order, representation), reporter: sinkReporter)
        defer { source.handle(.release(Self.id), reporter: sourceReporter) }
        reading: while true {
            source.handle(.read(Self.id, maxBytes: WireConstants.maxRawDataPayload), reporter: sourceReporter)
            switch await sources.next() {
            case .bytes(_, let bytes)?:
                sink.handle(.bytes(Self.id, bytes), reporter: sinkReporter)
                guard case .consumed? = await sinks.next() else { return nil }
            case .finished?:
                break reading
            default:
                return nil
            }
        }
        sink.handle(.finish(Self.id), reporter: sinkReporter)
        let verdict = await sinks.next()
        guard verdict == .verified(Self.id) else { return verdict }
        sink.handle(.commit(Self.id), reporter: sinkReporter)
        return await sinks.next()
    }

    /// The container a side of role `server` serves of INLINE `content` for a pull that takes LZ4, read by read.
    static func container(_ content: ItemContent, servedBy server: PeerRole) async throws -> [Data] {
        let source = ItemSourceAdapter(fileSystem: POSIXTreeFileSystem(), sendingCores: 8) { _, _, _ in
            .success(content)
        }
        var request = PullRequest()
        request.byteCeiling = 1 << 30
        request.codecs = [.lz4]
        var representation = Representation()
        representation.storage = .inline
        let (sources, reporter) = Inbox<ItemSourceInput>.make { ItemSourceReporter(ItemConnection(role: server), $0) }
        source.handle(.serve(id, .clipboard, request, representation), reporter: reporter)
        defer { source.handle(.release(id), reporter: reporter) }
        var reads: [Data] = []
        while true {
            source.handle(.read(id, maxBytes: WireConstants.maxRawDataPayload), reporter: reporter)
            switch await sources.next() {
            case .bytes(_, let bytes)?: reads.append(bytes)
            case .finished?: return reads
            case let report: throw WireError(.internal, debugDetail: "\(String(describing: report))")
            }
        }
    }

    /// The error a serve of `content` as a representation of `storage` fails with, or nil when it does not.
    func serveFailure(
        _ content: Result<ItemContent, WireError>, _ storage: Representation.Storage, ceiling: UInt64 = 1 << 30
    ) async throws -> WireError? {
        let source = ItemSourceAdapter(fileSystem: POSIXTreeFileSystem()) { _, _, _ in content }
        var request = PullRequest()
        request.byteCeiling = ceiling
        var representation = Representation()
        representation.storage = storage
        let (sources, reporter) = Inbox<ItemSourceInput>.make { ItemSourceReporter(ItemConnection(role: .host), $0) }
        source.handle(.serve(Self.id, .clipboard, request, representation), reporter: reporter)
        while true {
            source.handle(.read(Self.id, maxBytes: WireConstants.maxRawDataPayload), reporter: reporter)
            switch await sources.next() {
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

    /// The next report.
    func next() async -> Element? {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }
}
#endif
