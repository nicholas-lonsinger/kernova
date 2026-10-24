import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

/// The drop agent carrying drags out of the guest over a real drop channel:
/// the offer, its withdrawal and the hand-off frames on the wire, the host's
/// pull served over the drop data port, and when the watcher runs at all.
@Suite("VsockGuestDropAgent drags out", .caseScoped)
@MainActor
struct VsockGuestDropAgentDragOutTests {
    private let scratch = TestScratchDirectory(prefix: "VsockGuestDropAgentDragOutTests")

    /// The agent under test over fakes of the guest's input and screen, and the
    /// host end of its channel.
    @MainActor
    private final class Harness {
        let agent: VsockGuestDropAgent
        let host: VsockChannel
        let dialled = DialledDataConnections()
        let input = FakeGuestDragInput()
        let surface = FakeCatcherSurface()
        let stagingRoot = TestStagingRoot()

        init(scratch: URL, capabilities: HostDropCapabilities) throws {
            let (agentFd, hostFd) = try makeRawSocketPair()
            host = VsockChannel(fileDescriptor: hostFd)
            host.start()

            let provided = AtomicInt()
            let client = VsockGuestClient(
                port: KernovaVsockPort.drop, label: "drop-drag-test",
                clock: MonotonicEngineClock(), retryInterval: 0.05
            ) { _, _ in
                provided.increment() == 1 ? .success(agentFd) : .failure(.transient("test: no fd"))
            }
            input.resolvesOnItsOwn = true
            agent = VsockGuestDropAgent(
                client: client, reporter: ClipboardTransferReporter(clock: TestEngineClock()),
                progressRevealDelay: 0, progressIdleGap: 0,
                downloadsDirectory: scratch.appendingPathComponent("Downloads", isDirectory: true),
                stagingRoot: stagingRoot.root, dataDialer: dialled.dialer, revealInFinder: { _ in },
                dragOutSystem: .faked(input: input, surface: surface))
            agent.applyHostCapabilities(capabilities)
        }

        /// Starts the agent with drag and drop on and waits for the connection
        /// to build its drag-out.
        func start() async throws {
            agent.start()
            agent.applyPolicy(enabled: true)
            try await input.changed.wait { input.connectionCount == 1 }
        }

        func tearDown() {
            agent.stop()
            host.close()
            dialled.closeAll()
        }

        /// A press dragging `urls`, read by the first tick; the offer follows
        /// once the resolve comes back.
        func drag(_ urls: [URL]) {
            input.press()
            input.drag(urls.map(fileItem))
            input.fireTick()
        }

        /// The next frame from the agent, which must be the drag offer.
        func awaitDragOffer() async throws -> Kernova_V1_DragOffer {
            let frame = try await nextFrame(from: host)
            guard case .dragOffer(let offer) = frame.payload else {
                throw TestFailure("Expected a DragOffer, got \(String(describing: frame.payload))")
            }
            return offer
        }
    }

    private static let both = HostDropCapabilities(supportsDropFiles: true, supportsDragOut: true)

    private func file(_ name: String, _ contents: Data) throws -> URL {
        let directory = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    @Test("a drag goes out as a DragOffer, and the host's pull of it is served over the data port")
    func aDragIsOfferedAndServed() async throws {
        let harness = try Harness(scratch: scratch.url, capabilities: Self.both)
        defer { harness.tearDown() }
        try await harness.start()
        try await harness.input.changed.wait { harness.input.isObservingPresses }

        let contents = Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        harness.drag([try file("notes.bin", contents)])
        let offer = try await harness.awaitDragOffer()
        let info = try #require(offer.repInfo.first)
        #expect(offer.repInfo.count == 1)
        #expect(info.filename == "notes.bin")
        #expect(info.byteCount == UInt64(contents.count))

        let transferID = ClipboardTransferID.make(
            generation: offer.generation, repIndex: 0, hostMinted: true)
        try harness.host.send(
            makeRequestFrame(generation: offer.generation, transferID: transferID, uti: info.uti))
        let transfer = try await collectOutboundTransfer(
            transferID: transferID, from: harness.dialled)

        #expect(transfer.reply.isArchive)
        #expect(transfer.isComplete)
        let unpacked = try extractedClipboardArchive(transfer.payload)
        #expect(try Data(contentsOf: unpacked.appendingPathComponent("notes.bin")) == contents)
    }

    @Test("the press ending withdraws the drag with a DragRelease")
    func pressEndSendsARelease() async throws {
        let harness = try Harness(scratch: scratch.url, capabilities: Self.both)
        defer { harness.tearDown() }
        try await harness.start()
        try await harness.input.changed.wait { harness.input.isObservingPresses }
        harness.drag([try file("dragged.bin", Data("dragged".utf8))])
        let offer = try await harness.awaitDragOffer()

        harness.input.release()
        harness.input.fireTick()

        let frame = try await nextFrame(from: harness.host)
        guard case .dragRelease(let release) = frame.payload else {
            throw TestFailure("Expected a DragRelease, got \(String(describing: frame.payload))")
        }
        #expect(release.generation == offer.generation)
    }

    @Test("a DragTake arms the catcher and reports armed; the host's DragComplete takes it down")
    func aTakeOverTheWire() async throws {
        let harness = try Harness(scratch: scratch.url, capabilities: Self.both)
        defer { harness.tearDown() }
        try await harness.start()
        try await harness.input.changed.wait { harness.input.isObservingPresses }
        harness.drag([try file("taken.bin", Data("taken".utf8))])
        let offer = try await harness.awaitDragOffer()

        try harness.host.send(.dragTake(generation: offer.generation))

        let frame = try await nextFrame(from: harness.host)
        guard case .dragHandOff(let handOff) = frame.payload else {
            throw TestFailure("Expected a DragHandOff, got \(String(describing: frame.payload))")
        }
        #expect(handOff.generation == offer.generation)
        #expect(ClipboardDragHandOffStep(handOff) == .armed)
        #expect(harness.surface.isShown)

        try harness.host.send(.dragComplete(generation: offer.generation))
        try await harness.surface.changed.wait { !harness.surface.isShown }
    }

    @Test("a DragCatcher stands the catcher down and shows it again, which reports armed")
    func catcherFramesOverTheWire() async throws {
        let harness = try Harness(scratch: scratch.url, capabilities: Self.both)
        defer { harness.tearDown() }
        try await harness.start()
        try await harness.input.changed.wait { harness.input.isObservingPresses }
        harness.drag([try file("taken.bin", Data("taken".utf8))])
        let offer = try await harness.awaitDragOffer()
        try harness.host.send(.dragTake(generation: offer.generation))
        _ = try await nextFrame(from: harness.host)

        try harness.host.send(.dragCatcher(generation: offer.generation, shown: false))
        try await harness.surface.changed.wait { !harness.surface.isShown }
        try harness.host.send(.dragCatcher(generation: offer.generation, shown: true))

        let frame = try await nextFrame(from: harness.host)
        guard case .dragHandOff(let handOff) = frame.payload else {
            throw TestFailure("Expected a DragHandOff, got \(String(describing: frame.payload))")
        }
        #expect(handOff.generation == offer.generation)
        #expect(ClipboardDragHandOffStep(handOff) == .armed)
        #expect(harness.surface.isShown)
    }

    @Test("a folder is offered at no size, and a DragTake sends its measured size after armed")
    func aFolderIsSizedOnlyOnceTaken() async throws {
        let harness = try Harness(scratch: scratch.url, capabilities: Self.both)
        defer { harness.tearDown() }
        try await harness.start()
        try await harness.input.changed.wait { harness.input.isObservingPresses }
        let tree = scratch.url.appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("Tree", isDirectory: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: tree.appendingPathComponent("a.txt"))
        try Data("beta".utf8).write(to: tree.appendingPathComponent("b.txt"))
        harness.drag([tree])
        let offer = try await harness.awaitDragOffer()
        let info = try #require(offer.repInfo.first)
        #expect(info.isDirectory)
        #expect(info.byteCount == 0)

        try harness.host.send(.dragTake(generation: offer.generation))
        guard case .dragHandOff(let handOff) = try await nextFrame(from: harness.host).payload,
            ClipboardDragHandOffStep(handOff) == .armed
        else { throw TestFailure("Expected ARMED first") }
        try await harness.input.changed.wait { !harness.input.pendingMeasureFolders.isEmpty }
        harness.input.deliverMeasures()

        let frame = try await nextFrame(from: harness.host)
        guard case .dragSizes(let sizes) = frame.payload else {
            throw TestFailure("Expected a DragSizes, got \(String(describing: frame.payload))")
        }
        #expect(sizes.generation == offer.generation)
        #expect(sizes.folderByteCounts == [0: 9])
    }

    @Test("a host that does not take drags out gets no watcher until it says it does")
    func theWatcherNeedsTheHostCapability() async throws {
        let harness = try Harness(
            scratch: scratch.url,
            capabilities: HostDropCapabilities(supportsDropFiles: true, supportsDragOut: false))
        defer { harness.tearDown() }
        try await harness.start()
        // The connection decides whether to watch in the same turn that builds
        // its drag-out, so the decision has been made by now.
        #expect(!harness.input.isObservingPresses)
        #expect(!harness.input.isHoldingActivity)

        harness.agent.applyHostCapabilities(Self.both)

        try await harness.input.changed.wait { harness.input.isObservingPresses }
        #expect(harness.input.isHoldingActivity)
    }

    @Test("drag and drop switched off stops the watcher")
    func policyOffStopsTheWatcher() async throws {
        let harness = try Harness(scratch: scratch.url, capabilities: Self.both)
        defer { harness.tearDown() }
        try await harness.start()
        try await harness.input.changed.wait { harness.input.isObservingPresses }

        harness.agent.applyPolicy(enabled: false)

        try await harness.input.changed.wait { !harness.input.isObservingPresses }
        #expect(!harness.input.isHoldingActivity)
    }
}
