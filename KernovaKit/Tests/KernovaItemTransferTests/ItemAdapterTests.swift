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
import KernovaContainer
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
    @Test("a FILE lands under the landing's name, compressed or not", arguments: [PeerRole.host, .sessionPeer])
    func fileLands(_ server: PeerRole) async throws {
        let bench = try Bench()
        let content = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 / 7) })
        try bench.write(content, to: "source/report.bin")
        let landing = ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("chosen.bin".utf8)))
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
        let landing = ItemLanding.staged(directory: bench.path("landed"), name: .keepingBoth(Data("Folder".utf8)))
        let result = try await bench.transfer(
            .tree(path: bench.path("source/Folder")), .folder, landing)
        #expect(result == .published(Bench.id, .named(Data("Folder 2".utf8))))
        #expect(try bench.read("landed/Folder 2/a.txt") == Data("a".utf8))
        #expect(try bench.read("landed/Folder 2/sub/b.bin") == Data(repeating: 9, count: 300_000))
        #expect(try bench.names("landed") == ["Folder", "Folder 2"])
        #expect(try bench.names("landed/Folder").isEmpty)
    }

    @Test(
        "an item lands at exactly its own path though the folder above it cannot be opened, beside nothing",
        .enabled(if: geteuid() != 0, "root reads past every permission bit, as the Linux CI container runs"),
        arguments: [Representation.Storage.file, .folder])
    func exactPathLands(_ storage: Representation.Storage) async throws {
        let bench = try Bench()
        let name = storage == .file ? "IMG_0042.jpg" : "Folder"
        if storage == .file {
            try bench.write(Data(repeating: 7, count: 400_000), to: "source/\(name)")
        } else {
            try bench.write(Data("a".utf8), to: "source/Folder/a.txt")
            try bench.write(Data(repeating: 9, count: 300_000), to: "source/Folder/sub/b.bin")
        }
        try bench.makeDirectory("landed")
        // Writable and searchable, unreadable: the item's path resolves and takes a new entry, and an open of
        // the folder itself fails.
        try #require(chmod(bench.path("landed"), 0o300) == 0)
        defer { _ = chmod(bench.path("landed"), 0o755) }
        try #require(open(bench.path("landed"), O_RDONLY | O_DIRECTORY) == -1)

        let result = try await bench.transfer(
            .tree(path: bench.path("source/\(name)")), storage, .exactPath(bench.path("landed/\(name)")))

        #expect(result == .published(Bench.id, .named(Data(name.utf8))))
        try #require(chmod(bench.path("landed"), 0o755) == 0)
        #expect(try bench.names("landed") == [name])
        if storage == .file {
            #expect(try bench.read("landed/\(name)") == Data(repeating: 7, count: 400_000))
        } else {
            #expect(try bench.read("landed/Folder/a.txt") == Data("a".utf8))
            #expect(try bench.read("landed/Folder/sub/b.bin") == Data(repeating: 9, count: 300_000))
        }
    }

    @Test("a landing at an exact path that fails leaves nothing at the path")
    func exactPathFailureRemoves() async throws {
        let bench = try Bench()
        try bench.write(Data("a".utf8), to: "source/Folder/a.txt")
        try bench.write(Data(repeating: 9, count: 300_000), to: "source/Folder/sub/b.bin")
        try bench.makeDirectory("landed")

        // The sink accepts less than the folder's second file, which fails it once its root has landed.
        let result = try await bench.transfer(
            .tree(path: bench.path("source/Folder")), .folder, .exactPath(bench.path("landed/Folder")),
            sinkByteCeiling: 100_000)

        guard case .refused(_, let error)? = result else {
            Issue.record("\(String(describing: result))")
            return
        }
        #expect(error.code == .tooLarge)
        #expect(try bench.names("landed").isEmpty)
    }

    @Test("a termination discard removes a landing mid-write before it returns")
    func terminationDiscardRemoves() async throws {
        let bench = try Bench()
        try bench.write(Data(repeating: 3, count: 2_000_000), to: "source/big.bin")
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
        while (try? bench.names("landed"))?.isEmpty ?? true {
            source.handle(.read(Bench.id, maxBytes: WireConstants.maxRawDataPayload), reporter: sourceReporter)
            guard case .bytes(_, let bytes)? = await sources.next() else {
                Issue.record("the source finished before the landing began")
                return
            }
            sink.handle(.bytes(Bench.id, bytes), reporter: sinkReporter)
            #expect(await sinks.next() == .consumed(Bench.id, bytes.count))
        }

        sink.discardForTermination()

        #expect(try bench.names("landed").isEmpty)
    }

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
            guard case .bytes(_, let bytes)? = await sources.next() else {
                Issue.record("the source finished before the landing began")
                return
            }
            sink.handle(.bytes(Bench.id, bytes), reporter: sinkReporter)
            #expect(await sinks.next() == .consumed(Bench.id, bytes.count))
        }
        // Queue more writes on the pull's lane, unawaited, as a pull mid-copy has.
        var queued: [Data] = []
        for _ in 0..<24 {
            source.handle(.read(Bench.id, maxBytes: WireConstants.maxRawDataPayload), reporter: sourceReporter)
            guard case .bytes(_, let bytes)? = await sources.next() else { break }
            queued.append(bytes)
        }
        for bytes in queued { sink.handle(.bytes(Bench.id, bytes), reporter: sinkReporter) }
        // The hub queue's abort for the termination's own cancel lands first.
        sink.handle(.abort(Bench.id), reporter: sinkReporter)
        sink.discardForTermination()

        #expect(try bench.names("landed").isEmpty, "discardForTermination returned with a landing still on disk")
    }

    @Test(
        "the sink reports the logical bytes it landed as it lands them, ending at the content's size",
        arguments: [Representation.Storage.file, .folder, .inline], [0, 2])
    func reportsLogicalBytes(_ storage: Representation.Storage, decodingWorkers: Int) async throws {
        let bench = try Bench()
        // Compressible past one chunk, with one whole chunk of zeros, so LZ4 blocks and a zero run both land.
        let big = Data(
            (0..<700_000).map {
                (ContainerEncoder.chunkByteCount..<2 * ContainerEncoder.chunkByteCount).contains($0)
                    ? 0 : UInt8(truncatingIfNeeded: $0 / 7)
            })
        let content: ItemContent
        let landing: ItemLanding
        let size: UInt64
        switch storage {
        case .folder:
            try bench.write(Data("a".utf8), to: "source/Folder/a.txt")
            try bench.write(big, to: "source/Folder/sub/b.bin")
            content = .tree(path: bench.path("source/Folder"))
            landing = .staged(directory: bench.path("landed"), name: .exactly(Data("Folder".utf8)))
            size = 700_001
        case .inline:
            content = .inline(big)
            landing = .memory
            size = 700_000
        default:
            try bench.write(big, to: "source/b.bin")
            content = .tree(path: bench.path("source/b.bin"))
            landing = .staged(directory: bench.path("landed"), name: .exactly(Data("b.bin".utf8)))
            size = 700_000
        }
        let progress = LandingRecord()
        let consumed = Locked(0)

        let result = try await bench.transfer(
            content, storage, landing, decodingWorkers: decodingWorkers, progress: progress, consumed: consumed)

        guard case .published? = result else {
            Issue.record("\(String(describing: result))")
            return
        }
        let reports = progress.reports
        #expect(reports.last?.landed == size)
        #expect(reports.last?.declared == size)
        #expect(reports.allSatisfy { $0.landed <= $0.declared })
        #expect(zip(reports, reports.dropFirst()).allSatisfy { $0.landed <= $1.landed && $0.declared <= $1.declared })
        // The stream's credit counts the container's compressed bytes, a different unit.
        #expect(UInt64(consumed.withLock { $0 }) < size)
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

    @Test(
        "INLINE bytes are served from the provider and land as a file under the landing's name",
        arguments: [PeerRole.host, .sessionPeer])
    func inlineLands(_ server: PeerRole) async throws {
        let bench = try Bench()
        let bytes = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let landing = ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("content".utf8)))
        let result = try await bench.transfer(.inline(bytes), .inline, landing, servedBy: server)
        #expect(result == .published(Bench.id, .named(Data("content".utf8))))
        #expect(try bench.read("landed/content") == bytes)
        #expect(try bench.names("landed") == ["content"])
    }

    @Test("INLINE bytes landing in memory are published as their bytes, and nothing is written")
    func inlineLandsInMemory() async throws {
        let bench = try Bench()
        let bytes = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let result = try await bench.transfer(.inline(bytes), .inline, .memory)
        #expect(result == .published(Bench.id, .inline(bytes)))
        #expect(try bench.names("").isEmpty)
    }

    @Test("INLINE bytes landing in memory are charged to the order's budget, and kept once published")
    func inlineInMemoryChargesTheBudget() async throws {
        let bench = try Bench()
        let bytes = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 % 251) })
        let budget = ByteBudget(limit: 1_000_000)
        let result = try await bench.transfer(.inline(bytes), .inline, .memory, budget: budget)
        #expect(result == .published(Bench.id, .inline(bytes)))
        #expect(budget.remaining == 1_000_000 - UInt64(bytes.count))

        // The next landing sharing the budget finds less than it needs left.
        let refused = try await bench.transfer(.inline(bytes), .inline, .memory, budget: budget)
        guard case .refused(_, let error)? = refused else {
            Issue.record("landed over the budget: \(String(describing: refused))")
            return
        }
        #expect(error.code == .tooLarge)
        #expect(error.limit == 1_000_000)
        // A refused landing gives back what it charged.
        #expect(budget.remaining == 1_000_000 - UInt64(bytes.count))
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
        let bench = try Bench()
        try bench.makeDirectory("landed")
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
            token: Data(count: 16), item: 0, representation: 0, byteCeiling: 1 << 30,
            landing: ItemLanding.staged(directory: bench.path("landed"), name: .keepingBoth(Data("content".utf8))))
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
        // The two publishes race for the name, so either may keep it.
        let names = [await firstReports.next(), await secondReports.next()].map { report -> String? in
            guard case .published(_, .named(let name))? = report else { return nil }
            return String(decoding: name, as: UTF8.self)
        }
        #expect(Set(names) == ["content", "content 2"])
        let landed = try names.compactMap { $0 }.map { try bench.read("landed/" + $0) }
        #expect(landed == [first, second])
    }

    @Test("pulls sharing a budget land no more than it holds together: the one past it is refused TOO_LARGE")
    func budgetBoundsPullsTogether() async throws {
        let bench = try Bench()
        try bench.write(Data(repeating: 1, count: 600), to: "source/a.bin")
        try bench.write(Data(repeating: 2, count: 600), to: "source/b.bin")
        let budget = ByteBudget(limit: 1_000)
        let first = try await bench.transfer(
            .tree(path: bench.path("source/a.bin")), .file,
            ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("a.bin".utf8))), budget: budget)
        #expect(first == .published(Bench.id, .named(Data("a.bin".utf8))))
        #expect(budget.remaining == 400)

        let second = try await bench.transfer(
            .tree(path: bench.path("source/b.bin")), .file,
            ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("b.bin".utf8))), budget: budget)
        guard case .refused(_, let error)? = second else {
            Issue.record("\(String(describing: second))")
            return
        }
        #expect(error.code == .tooLarge)
        #expect(error.limit == 1_000)
        #expect(budget.remaining == 400)
        #expect(try bench.names("landed") == ["a.bin"])
    }

    @Test("a pull refused or failing after it charged the budget gives back what it charged")
    func failedPullGivesBack() async throws {
        let bench = try Bench()
        try bench.write(Data(repeating: 1, count: 300), to: "source/Folder/a.bin")
        try bench.write(Data(repeating: 2, count: 800), to: "source/Folder/b.bin")
        try bench.write(Data("new".utf8), to: "source/doc.txt")
        try bench.write(Data("old".utf8), to: "landed/doc.txt")
        let budget = ByteBudget(limit: 1_000)

        let folder = try await bench.transfer(
            .tree(path: bench.path("source/Folder")), .folder,
            ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("Folder".utf8))), budget: budget)
        guard case .refused(_, let error)? = folder else {
            Issue.record("\(String(describing: folder))")
            return
        }
        #expect(error.code == .tooLarge)
        #expect(budget.remaining == 1_000)

        let file = try await bench.transfer(
            .tree(path: bench.path("source/doc.txt")), .file,
            ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("doc.txt".utf8))), budget: budget)
        guard case .publishFailed? = file else {
            Issue.record("\(String(describing: file))")
            return
        }
        #expect(budget.remaining == 1_000)
        #expect(try bench.names("landed") == ["doc.txt"])
    }

    @Test("a publish onto a taken exact name fails EEXIST and leaves only what was there")
    func publishFails() async throws {
        let bench = try Bench()
        try bench.write(Data("new".utf8), to: "source/doc.txt")
        try bench.write(Data("old".utf8), to: "landed/doc.txt")
        let landing = ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("doc.txt".utf8)))
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
            let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "ItemSource") {
                level, _, _, segments in
                records.withLock { $0.append((level, segments)) }
            }
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
            ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("report.bin".utf8))))
        #expect(file == .published(Bench.id, .named(Data("report.bin".utf8))))
        #expect(try bench.read("landed/report.bin") == content)
        let folder = try await bench.transfer(
            .tree(path: bench.path("source/locked/Folder")), .folder,
            ItemLanding.staged(directory: bench.path("landed"), name: .exactly(Data("Folder".utf8))))
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
        let landing = ItemLanding.staged(directory: bench.path("landed"), name: .keepingBoth(Data("x".utf8)))
        let tree = try sink.order(token: Data(count: 16), item: 1, representation: 2, byteCeiling: 9, landing: landing)
        let directory = try fileSystem.openDirectory(Array(bench.path("landed").utf8), in: AT_FDCWD)
        defer { fileSystem.close(directory) }
        #expect(tree.landing == landing)
        #expect(
            tree.request.decmpfsTypes
                == (try DecmpfsMatrix.acceptedTypes(landingIn: directory, on: fileSystem)).sorted())
        #expect(tree.request.codecs == [.lz4])
        #expect((tree.request.item, tree.request.representation, tree.request.byteCeiling) == (1, 2, 9))
        let budget = ByteBudget(limit: 9)
        #expect(
            try sink.order(
                token: Data(count: 16), item: 0, representation: 0, byteCeiling: 9, landing: landing, budget: budget
            ).budget === budget)
        #expect(tree.budget == nil)
        #expect(throws: WireError.self) {
            try sink.order(
                token: Data(), item: 0, representation: 0, byteCeiling: 9,
                landing: ItemLanding.staged(directory: bench.path("missing"), name: .exactly(Data("x".utf8))))
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
/// Every report a pull's landing made, in order.
final class LandingRecord: ItemLandingProgress {
    private let all = Locked<[(landed: UInt64, declared: UInt64)]>([])

    var reports: [(landed: UInt64, declared: UInt64)] { all.withLock { $0 } }

    func advanced(landed: UInt64, declared: UInt64) {
        all.withLock { $0.append((landed, declared)) }
    }
}

final class Bench: Sendable {
    static let id = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2))
    /// A logger that records nothing.
    static let logger = KernovaLogger(subsystem: "app.kernova.tests", category: "ItemSource") { _, _, _, _ in }

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
    ///
    /// The sink accepts `sinkByteCeiling` bytes, by default what the source is asked for.
    func transfer(
        _ content: ItemContent, _ storage: Representation.Storage, _ landing: ItemLanding,
        servedBy server: PeerRole = .sessionPeer, sinkByteCeiling: UInt64 = 1 << 30, budget: ByteBudget? = nil,
        decodingWorkers: Int = 2, progress: (any ItemLandingProgress)? = nil, consumed: Locked<Int>? = nil
    ) async throws -> ItemSinkInput? {
        if case .staged(let directory, _) = landing {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
        let fileSystem = POSIXTreeFileSystem()
        let source = ItemSourceAdapter(fileSystem: fileSystem, sendingCores: 8, logger: Self.logger) { _, _, _, _ in
            .success(content)
        }
        let sink = ItemSinkAdapter(fileSystem: fileSystem, decodingWorkers: decodingWorkers)
        let order = try sink.order(
            token: Data(count: 16), item: 0, representation: 0, byteCeiling: 1 << 30, landing: landing)
        let sinkOrder = try sink.order(
            token: Data(count: 16), item: 0, representation: 0, byteCeiling: sinkByteCeiling, landing: landing,
            budget: budget, progress: progress)
        var representation = Representation()
        representation.storage = storage
        let puller: PeerRole = server == .host ? .sessionPeer : .host
        let (sources, sourceReporter) = Inbox<ItemSourceInput>.make {
            ItemSourceReporter(ItemConnection(role: server), $0)
        }
        let (sinks, sinkReporter) = Inbox<ItemSinkInput>.make { ItemSinkReporter(ItemConnection(role: puller), $0) }
        source.handle(.serve(Self.id, .clipboard, order.request, representation), reporter: sourceReporter)
        sink.handle(.begin(Self.id, sinkOrder, representation), reporter: sinkReporter)
        defer { source.handle(.release(Self.id), reporter: sourceReporter) }
        reading: while true {
            source.handle(.read(Self.id, maxBytes: WireConstants.maxRawDataPayload), reporter: sourceReporter)
            switch await sources.next() {
            case .bytes(_, let bytes)?:
                sink.handle(.bytes(Self.id, bytes), reporter: sinkReporter)
                let report = await sinks.next()
                guard case .consumed(_, let count)? = report else { return report }
                consumed?.withLock { $0 += count }
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
        let source = ItemSourceAdapter(
            fileSystem: POSIXTreeFileSystem(), sendingCores: 8, logger: logger
        ) { _, _, _, _ in .success(content) }
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
