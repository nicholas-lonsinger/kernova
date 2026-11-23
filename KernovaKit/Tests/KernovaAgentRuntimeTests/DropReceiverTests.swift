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
@Suite("Drop receiver", .offTaskWaitsReported)
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
            let (held, released, waits) = (held, released, OffTaskWaits())
            let hostRouter = ItemFeatureRouter<PeerHandle>(
                drop: ItemFeatureOwner(
                    usable: { _ in }, events: { _, event in hostEvents.record(event) },
                    content: { _, _, representation in
                        served.record(String(decoding: representation.name, as: UTF8.self))
                        if held.withLock({ $0 }) {
                            waits.run { try Backstop("the held serve's release").wait(for: released) }
                        }
                        return .success(
                            .tree(path: source + "/" + String(decoding: representation.name, as: UTF8.self)))
                    }), logger: Fixture.logger)
            harness = HubHarness(
                policy: SimItems.policy(PolicySnapshot()),
                items: ItemAdapters(
                    source: ItemSourceAdapter(fileSystem: POSIXTreeFileSystem(), logger: Fixture.logger) {
                        hostRouter.content($0, $1, $2, $3)
                    },
                    sink: MemoryItems(), features: hostRouter.features),
                itemEvents: { hostRouter.deliver($0) })
            try await harness.attached()
            let sink = ItemSinkAdapter(fileSystem: POSIXTreeFileSystem())
            let receiver = DropReceiver(
                directory: landing ?? scratch.path + "/Downloads", sink: sink, logger: Fixture.logger
            ) { names in landed.record(names.map { String(decoding: $0, as: UTF8.self) }) }
            let peerRouter = ItemFeatureRouter<Void>(drop: receiver.owner, logger: Fixture.logger)
            runtime = PeerAgentRuntime(
                claim: Fixture.peerClaim, state: Fixture.peerState,
                registry: PeerFeatureRegistry(
                    items: ItemAdapters(
                        source: ItemSourceAdapter(fileSystem: POSIXTreeFileSystem(), logger: Fixture.logger) {
                            peerRouter.content($0, $1, $2, $3)
                        },
                        sink: sink, features: peerRouter.features)),
                dialer: HubDialer(harness: harness), scheduler: SystemScheduler(), logger: Fixture.logger,
                handlers: PeerAgentRuntime.Handlers(event: { peerRouter.deliver($0) }, stop: { _ in }))
            receiver.attach(runtime)
            runtime.start()
            _ = try await harness.snapshot { $0.consolePeers[.drop] != nil }
        }

        func write(_ contents: String, to relative: String) throws {
            try Data(contents.utf8).write(to: URL(fileURLWithPath: source + "/" + relative))
        }

        func read(_ relative: String) -> String? {
            FileManager.default.contents(atPath: downloads + "/" + relative).map { String(decoding: $0, as: UTF8.self) }
        }

        /// Offers the source entries `names` as one drop, each a FILE or, ending in `/`, a FOLDER.
        func drop(_ names: [String], token tag: UInt8 = 1) async throws -> Result<PeerHandle, WireError> {
            let items = names.map { name -> [Representation] in
                var representation = Representation()
                representation.storage = name.hasSuffix("/") ? .folder : .file
                representation.name = Data((name.hasSuffix("/") ? String(name.dropLast()) : name).utf8)
                return [representation]
            }
            return try await Backstop("harness.hub.offerItems").park { resume in
                harness.hub.offerItems(SimItems.offer(tag, items), feature: .drop) {
                    resume($0)
                }
            }
        }

        /// How the host's drop offer `tag` ended, once it has.
        func offerEnd(_ tag: UInt8 = 1, fileID: String = #fileID, line: Int = #line) async throws -> StreamClosure {
            var waiter = hostEvents.waiter()
            let ended = try await waiter.next(fileID: fileID, line: line) {
                if case .offerEnded(.drop, .local, SimItems.token(tag), _) = $0 { true } else { false }
            }
            guard case .offerEnded(_, _, _, let closure) = ended else { preconditionFailure() }
            return closure
        }

        func close() async throws {
            try await Backstop("runtime.close").park { resume in runtime.close { resume(()) } }
            harness.hub.close()
        }
    }

    @Test(
        "An item the host cannot serve is skipped, the rest of the drop lands, and the release counts only what landed")
    func unservableItemIsSkipped() async throws {
        let bench = try await Bench()
        try bench.write("b", to: "b.txt")

        _ = try await bench.drop(["gone.txt", "b.txt"]).get()

        var landed = bench.landed.waiter()
        #expect(try await landed.next { _ in true } == ["b.txt"])
        #expect(try await bench.offerEnd() == .completed(remoteEndBody: Data([0x10, 1])))
        try await bench.close()
    }
}
#endif
