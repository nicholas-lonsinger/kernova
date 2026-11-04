#if canImport(Darwin) || os(Linux)
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import Dispatch
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaAgentSimulation
import KernovaFileTree
import KernovaItemTransfer
import KernovaPortableTestSupport
import KernovaSynchronization
import KernovaWire
import Testing

/// A peer's DROP receiver against a real hub: the host offers files from a source folder, and the peer lands
/// them in its Downloads folder.
@Suite("Drop receiver")
struct DropReceiverTests {
    /// A hub serving DROP from `source`, and a peer runtime whose receiver lands in `downloads`.
    private final class Bench: Sendable {
        let scratch: PortableScratchDirectory
        let harness: HubHarness
        let runtime: PeerAgentRuntime
        let hostEvents = Recorder<ItemTransferEvent>()
        let landed = Recorder<[String]>()
        /// The name of each entry the host was asked to serve, as it was asked.
        let served = Recorder<String>()
        /// While held, each serve waits for `releaseServes()`.
        private let held: Locked<Bool>
        private let released = DispatchSemaphore(value: 0)

        var source: String { scratch.path + "/source" }
        var downloads: String { scratch.path + "/Downloads" }

        init(downloads landing: String? = nil, holdingServes: Bool = false) async throws {
            held = Locked(holdingServes)
            scratch = try PortableScratchDirectory(prefix: "drop-receiver")
            try FileManager.default.createDirectory(atPath: scratch.path + "/source", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                atPath: scratch.path + "/Downloads", withIntermediateDirectories: true)
            let (source, hostEvents, landed, served) = (scratch.path + "/source", hostEvents, landed, served)
            let (held, released) = (held, released)
            let hostRouter = ItemFeatureRouter<PeerHandle>(
                drop: ItemFeatureOwner(
                    usable: { _ in }, events: { _, event in hostEvents.record(event) },
                    content: { _, _, representation in
                        served.record(String(decoding: representation.name, as: UTF8.self))
                        if held.withLock({ $0 }) { released.wait() }
                        return .success(
                            .tree(path: source + "/" + String(decoding: representation.name, as: UTF8.self)))
                    }))
            harness = HubHarness(
                policy: SimItems.policy(PolicySnapshot()),
                items: ItemAdapters(
                    source: ItemSourceAdapter(fileSystem: POSIXTreeFileSystem()) {
                        hostRouter.content($0, $1, $2, $3)
                    },
                    sink: MemoryItems(), features: hostRouter.features),
                itemEvents: { hostRouter.deliver($0) })
            await harness.attached()
            let sink = ItemSinkAdapter(fileSystem: POSIXTreeFileSystem())
            let receiver = DropReceiver(
                directory: landing ?? scratch.path + "/Downloads", sink: sink, logger: Fixture.logger
            ) { names in landed.record(names.map { String(decoding: $0, as: UTF8.self) }) }
            let peerRouter = ItemFeatureRouter<Void>(drop: receiver.owner)
            runtime = PeerAgentRuntime(
                claim: Fixture.peerClaim, state: Fixture.peerState,
                registry: PeerFeatureRegistry(
                    items: ItemAdapters(
                        source: ItemSourceAdapter(fileSystem: POSIXTreeFileSystem()) {
                            peerRouter.content($0, $1, $2, $3)
                        },
                        sink: sink, features: peerRouter.features)),
                dialer: HubDialer(harness: harness), scheduler: SystemScheduler(), logger: Fixture.logger,
                handlers: PeerAgentRuntime.Handlers(event: { peerRouter.deliver($0) }, stop: { _ in }))
            receiver.attach(runtime)
            runtime.start()
            _ = await harness.snapshot { $0.consolePeers[.drop] != nil }
        }

        /// Lets every serve held so far, and every later one, go on.
        func releaseServes() {
            held.withLock { $0 = false }
            released.signal()
        }

        func write(_ contents: String, to relative: String) throws {
            try Data(contents.utf8).write(to: URL(fileURLWithPath: source + "/" + relative))
        }

        func read(_ relative: String) -> String? {
            FileManager.default.contents(atPath: downloads + "/" + relative).map { String(decoding: $0, as: UTF8.self) }
        }

        /// Offers the source entries `names` as one drop, each a FILE or, ending in `/`, a FOLDER.
        func drop(_ names: [String], token tag: UInt8 = 1) async -> Result<PeerHandle, WireError> {
            let items = names.map { name -> [Representation] in
                var representation = Representation()
                representation.storage = name.hasSuffix("/") ? .folder : .file
                representation.name = Data((name.hasSuffix("/") ? String(name.dropLast()) : name).utf8)
                return [representation]
            }
            return await withCheckedContinuation { continuation in
                harness.hub.offerItems(SimItems.offer(tag, items), feature: .drop) {
                    continuation.resume(returning: $0)
                }
            }
        }

        /// How the host's drop offer `tag` ended, once it has.
        func offerEnd(_ tag: UInt8 = 1) async -> StreamClosure {
            var waiter = hostEvents.waiter()
            let ended = await waiter.next {
                if case .offerEnded(.drop, .local, SimItems.token(tag), _) = $0 { true } else { false }
            }
            guard case .offerEnded(_, _, _, let closure) = ended else { preconditionFailure() }
            return closure
        }

        func close() async {
            await withCheckedContinuation { continuation in runtime.close { continuation.resume() } }
            harness.hub.close()
        }
    }

    @Test("A drop lands each item in Downloads under its offer name, Keep Both against what is there, then reveals")
    func landsKeepingBoth() async throws {
        let bench = try await Bench()
        try bench.write("new", to: "a.txt")
        try FileManager.default.createDirectory(atPath: bench.source + "/Album", withIntermediateDirectories: true)
        try bench.write("photo", to: "Album/p.jpg")
        try Data("old".utf8).write(to: URL(fileURLWithPath: bench.downloads + "/a.txt"))

        #expect(try await bench.drop(["a.txt", "Album/"]).get().rawValue > 0)

        var landed = bench.landed.waiter()
        #expect(await landed.next { _ in true } == ["a 2.txt", "Album"])
        #expect(bench.read("a.txt") == "old")
        #expect(bench.read("a 2.txt") == "new")
        #expect(bench.read("Album/p.jpg") == "photo")
        #expect(await bench.offerEnd() == .completed(remoteEndBody: DropLanded(items: [0, 1]).endBody))
        await bench.close()
    }

    @Test("A landing folder the peer cannot open refuses the drop with why, landing and revealing nothing")
    func unopenableFolderRefuses() async throws {
        let bench = try await Bench(downloads: "/nonexistent-\(UInt32.random(in: 0 ... .max))")
        try bench.write("a", to: "a.txt")

        _ = try await bench.drop(["a.txt"]).get()

        guard case .resetByPeer(let error) = await bench.offerEnd() else {
            Issue.record("the drop ended otherwise"); return
        }
        #expect(error.code == .writeFailed)
        #expect(error.posixErrno == ENOENT)
        await bench.harness.settled()
        #expect(bench.landed.elements.isEmpty)
        await bench.close()
    }

    @Test(
        "An item the host cannot serve is skipped, the rest of the drop lands, and the release names only what landed")
    func unservableItemIsSkipped() async throws {
        let bench = try await Bench()
        try bench.write("b", to: "b.txt")

        _ = try await bench.drop(["gone.txt", "b.txt"]).get()

        var landed = bench.landed.waiter()
        #expect(await landed.next { _ in true } == ["b.txt"])
        #expect(await bench.offerEnd() == .completed(remoteEndBody: DropLanded(items: [1]).endBody))
        await bench.close()
    }

    @Test(
        "A dropped folder the host cannot read all of, for an entry deep in it it may not open, is skipped",
        .enabled(if: geteuid() != 0, "root reads past every permission bit, as the Linux CI container runs"))
    func unreadableEntryInFolderIsSkipped() async throws {
        let bench = try await Bench()
        try FileManager.default.createDirectory(
            atPath: bench.source + "/Album/Private", withIntermediateDirectories: true)
        try bench.write("photo", to: "Album/p.jpg")
        try bench.write("secret", to: "Album/Private/s.txt")
        try bench.write("b", to: "b.txt")
        try #require(chmod(bench.source + "/Album/Private/s.txt", 0) == 0)
        defer { _ = chmod(bench.source + "/Album/Private/s.txt", 0o644) }

        _ = try await bench.drop(["Album/", "b.txt"]).get()

        var landed = bench.landed.waiter()
        #expect(await landed.next { _ in true } == ["b.txt"])
        #expect(await bench.offerEnd() == .completed(remoteEndBody: DropLanded(items: [1]).endBody))
        #expect(bench.read("Album/p.jpg") == nil)
        await bench.close()
    }

    @Test("A drop the host withdraws mid-drop lands nothing more and reveals nothing")
    func withdrawnDropStops() async throws {
        let bench = try await Bench(holdingServes: true)
        try bench.write("a", to: "a.txt")
        let peer = try await bench.drop(["a.txt", "a.txt"]).get()
        var served = bench.served.waiter()
        _ = await served.next { _ in true }

        bench.harness.hub.withdrawOffer(SimItems.token(1), from: peer)

        guard case .resetLocally(let error) = await bench.offerEnd() else {
            Issue.record("the drop ended otherwise"); return
        }
        #expect(error.code == .cancelled)
        bench.releaseServes()
        await bench.harness.settled()
        await flush(bench.runtime.queue)
        #expect(bench.landed.elements.isEmpty)
        #expect(bench.read("a.txt") == nil)
        #expect(bench.served.elements == ["a.txt"])
        await bench.close()
    }
}
#endif
