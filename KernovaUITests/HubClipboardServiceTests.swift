import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaCommandModel
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// A VM's clipboard over the guest agent's CLIPBOARD items, driven through its agent hub with a probe standing in
/// for the guest's connection: what the hub is asked to send, and what the host makes of what the guest sends.
@MainActor
@Suite("Hub clipboard service", .caseScoped)
struct HubClipboardServiceTests {
    private static let claim = PeerClaim(
        role: .sessionPeer, scope: .user, os: .macOS, architecture: .arm64, payloadHash: Data(),
        versionLabel: "1.0 (1)", instanceID: Data(repeating: 1, count: 16))
    private static let onConsole = PeerSessionState(console: .on, sessionID: "1", userName: "pbear")
    private static let offConsole = PeerSessionState(console: .off, sessionID: "1", userName: "pbear")
    private static let clipboard = FeatureStatusTable([(feature: .clipboard, status: .available(Data()))])
    private static let guestToken = Data(repeating: 7, count: 16)

    /// A running macOS VM whose hub's one connection is a session peer on the console carrying CLIPBOARD.
    private func connected(_ probe: AgentHubProbe) async throws -> VMInstance {
        let instance = VMInstanceFixture.make(
            guestOS: .macOS, phase: .running(sessionID: UUID()), agentConnector: probe)
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connect())
        probe.deliver(.helloReceived(Self.claim, Self.onConsole), fromConnection: 0)
        probe.deliver(.featuresChanged(Self.clipboard), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected && instance.clipboardRoute != .none }
        return instance
    }

    /// Every clipboard offer the hub sent the connection, in order.
    private func offers(_ probe: AgentHubProbe) -> [(id: ItemRequestID, offer: ItemOffer)] {
        probe.commands.compactMap {
            if case .items(.offer(let id, let offer, .clipboard)) = $0 { (id, offer) } else { nil }
        }
    }

    private func reads(_ probe: AgentHubProbe) -> [(id: ItemRequestID, item: UInt32)] {
        probe.commands.compactMap { if case .items(.read(let id, _, let item)) = $0 { (id, item) } else { nil } }
    }

    private func pulls(_ probe: AgentHubProbe) -> [(id: ItemRequestID, order: ItemPullOrder)] {
        probe.commands.compactMap { if case .items(.pull(let id, let order)) = $0 { (id, order) } else { nil } }
    }

    private func cancels(_ probe: AgentHubProbe) -> [ItemPullID] {
        probe.commands.compactMap { if case .items(.cancel(let id)) = $0 { id } else { nil } }
    }

    /// Has the guest open the pull the hub asked for in `request`, as pull `stream`.
    private func open(_ request: ItemRequestID, stream: UInt32, on probe: AgentHubProbe) -> ItemPullID {
        let pull = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: stream))
        probe.deliver(.itemReply(request, .pulled(.success(pull))), fromConnection: 0)
        return pull
    }

    /// Has the guest end its offer, its clipboard having moved on.
    private func endGuestOffer(on probe: AgentHubProbe) {
        probe.deliver(
            .items(.offerEnded(.clipboard, .remote, token: Self.guestToken, .resetByPeer(WireError(.cancelled)))),
            fromConnection: 0)
    }

    private static func representation(_ uti: String, _ storage: Representation.Storage, name: String = "")
        -> Representation
    {
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: uti)
        representation.storage = storage
        representation.name = Data(name.utf8)
        return representation
    }

    private static func item(_ representations: Representation...) -> OfferedItem {
        var item = OfferedItem()
        item.representations = representations
        return item
    }

    /// Has the guest offer `items`, answering the hub's reads of them, and waits for the buffer to show them.
    private func receive(_ items: OfferedItem..., on probe: AgentHubProbe, into instance: VMInstance) async throws {
        let header = ItemSetHeaderValue(
            feature: .clipboard, token: Self.guestToken, concealed: false, count: items.count)
        probe.deliver(.items(.offerReceived(header)), fromConnection: 0)
        try await probe.changed.wait { reads(probe).count == items.count }
        for (id, item) in reads(probe) { probe.deliver(.itemReply(id, .read(items[Int(item)])), fromConnection: 0) }
        try await waitForChange { instance.hubClipboard.inboundOfferSeq == 1 }
    }

    // MARK: - Host → guest

    /// Has passthrough forward a copy of `text` on the Mac, returning the offer the console peer was sent.
    private func forwardMacCopy(
        _ text: String, _ instance: VMInstance, _ probe: AgentHubProbe
    ) async throws -> (offer: ItemOffer, pasteboard: FakePasteboard, coordinator: ClipboardPassthroughCoordinator) {
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        let coordinator = ClipboardPassthroughCoordinator(
            instance: instance, publisher: instance.hostClipboardPublisher, reporter: instance.clipboardTransfers)
        // The first poll marks where this connection's copies begin.
        coordinator.pollHostClipboard()
        #expect(pasteboard.setString(text, forType: .string))
        coordinator.pollHostClipboard()
        try await probe.changed.wait { !offers(probe).isEmpty }
        return (try #require(offers(probe).last).offer, pasteboard, coordinator)
    }

    /// The guest's pull of `offer`'s first representation, as the hub's source asks the exchange for it.
    private func pull(_ offer: ItemOffer, from instance: VMInstance) async -> Result<ItemContent, WireError> {
        var request = PullRequest()
        request.token = offer.token
        let exchange = instance.hubClipboard.exchange
        let representation = offer.items[0].representations[0]
        let pull = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2))
        return await Task.detached { exchange.content(pull, request, representation) }.value
    }

    @Test("A copy on the Mac is offered from its types alone, its bytes read only when the guest pulls them")
    func hostCopyIsOffered() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let (offer, pasteboard, _) = try await forwardMacCopy("from the Mac", instance, probe)

        #expect(offer.items.count == 1)
        #expect(offer.items[0].representations.map(\.storage) == [.inline])
        #expect(offer.items[0].representations[0].type.appleUTI == ClipboardContent.utf8TextUTI)
        // The copy read nothing, so a privacy prompt can come only with a paste in the guest.
        #expect(pasteboard.residentReads.isEmpty)
        // The buffer is not the copy: showing it would read it.
        #expect(instance.hubClipboard.clipboardContent.isEmpty)

        #expect(await pull(offer, from: instance) == .success(.inline(Data("from the Mac".utf8))))
        #expect(pasteboard.residentReads == [.string])
    }

    @Test("A pull after the Mac's clipboard moved on fails ITEM_REPRESENTATION_UNAVAILABLE")
    func pullAfterTheCopyMovedOn() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let (offer, pasteboard, _) = try await forwardMacCopy("from the Mac", instance, probe)

        // A newer copy, not yet polled: the offer still stands, but what it was read from is gone.
        #expect(pasteboard.setString("copied since", forType: .string))
        guard case .failure(let error) = await pull(offer, from: instance) else {
            Issue.record("the pull was served")
            return
        }
        #expect(error.code == .itemRepresentationUnavailable)
        #expect(pasteboard.residentReads.isEmpty)
    }

    @Test("A console peer arriving is offered the host's clipboard again, under a fresh token")
    func newConsolePeerIsOfferedAgain() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        instance.hubClipboard.clipboardContent = ClipboardContent(text: "kept")
        #expect(instance.hubClipboard.grabIfChanged() == .settled)
        try await probe.changed.wait { offers(probe).count == 1 }
        probe.deliver(.itemReply(offers(probe)[0].id, .offered(nil)), fromConnection: 0)

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }

        try await probe.changed.wait { offers(probe).count == 2 }
        let (first, second) = (offers(probe)[0].offer, offers(probe)[1].offer)
        #expect(first.token != second.token)
        #expect(first.items == second.items)
    }

    // MARK: - Guest → host

    @Test("A guest's offer is shown in the buffer and published to the Mac pasteboard, pulling nothing")
    func guestOfferIsPublished() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let text = ClipboardContent.utf8TextUTI
        try await receive(Self.item(Self.representation(text, .inline)), on: probe, into: instance)

        #expect(instance.hubClipboard.clipboardContent.representations.map(\.isPendingRemote) == [true])
        let outcome = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        guard case .written = outcome else {
            Issue.record("not written: \(outcome)")
            return
        }
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.promisedTypes == [NSPasteboard.PasteboardType(text)])
        #expect(pulls(probe).isEmpty)
    }

    @Test("A paste of a guest's file pulls it into the clipboard staging root, under the offer's name")
    func pasteLandsInStaging() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(
            Self.item(Self.representation("public.data", .file, name: "notes.bin")), on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)

        // The paste holds its thread until the pull lands, so it fires off the main actor.
        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        let (requestID, order) = try #require(pulls(probe).first)
        let directory = order.landing.directory
        guard case .exactly(let name) = order.landing.name else {
            Issue.record("landing \(order.landing)")
            return
        }
        #expect(directory.hasPrefix(ClipboardFileStaging.processRoot.url.path + "/"))
        #expect(name == Data("notes.bin".utf8))
        #expect(order.request.token == Self.guestToken)
        #expect(order.request.byteCeiling == UInt64(instance.effectiveClipboardMaxPasteBytes))

        let pull = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 3))
        probe.deliver(.itemReply(requestID, .pulled(.success(pull))), fromConnection: 0)
        probe.deliver(.items(.pullEnded(.clipboard, pull, .landed(.named(name)))), fromConnection: 0)

        let served = try #require(await paste.value)
        let url = try #require(URL(string: String(decoding: served, as: UTF8.self)))
        #expect(url.path == directory + "/notes.bin")
    }

    @Test("A guest pull that opens and never ends is cancelled when the guest's offer ends, and the paste gets nothing")
    func stalledPullEndsWithItsOffer() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(
            Self.item(Self.representation("public.data", .file, name: "notes.bin")), on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        let pull = open(pulls(probe)[0].id, stream: 3, on: probe)

        // The guest sends nothing more, and then its clipboard moves on.
        endGuestOffer(on: probe)

        #expect(await paste.value == nil)
        try await probe.changed.wait { cancels(probe) == [pull] }
    }

    @Test("A pull the guest opens only after its offer ended is cancelled as it opens, the paste already answered")
    func pullOpeningAfterItsOfferEndedIsCancelled() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(
            Self.item(Self.representation("public.data", .file, name: "notes.bin")), on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        try await probe.changed.wait { !pulls(probe).isEmpty }

        endGuestOffer(on: probe)
        #expect(await paste.value == nil)
        let pull = open(pulls(probe)[0].id, stream: 3, on: probe)
        try await probe.changed.wait { cancels(probe) == [pull] }
    }

    @Test("Every file pull of one guest offer lands against one budget: the paste ceiling as the first pull read it")
    func filePullsShareOneBudget() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(
            Self.item(Self.representation("public.data", .file, name: "a.bin")),
            Self.item(Self.representation("public.data", .file, name: "b.bin")), on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)

        let first = Task.detached { pasteboard.invokeProvider(forType: .fileURL, itemIndex: 0) }
        let second = Task.detached { pasteboard.invokeProvider(forType: .fileURL, itemIndex: 1) }
        try await probe.changed.wait { pulls(probe).count == 2 }
        let orders = pulls(probe).map(\.order)
        let budget = try #require(orders[0].budget)
        #expect(orders[1].budget === budget)
        #expect(budget.limit == UInt64(instance.effectiveClipboardMaxPasteBytes))
        // Each pull asks for no more than the budget holds as it is ordered.
        #expect(orders.map(\.request.byteCeiling) == [budget.limit, budget.limit])

        endGuestOffer(on: probe)
        #expect(await first.value == nil)
        #expect(await second.value == nil)
    }

    @Test("A pull reads the paste ceiling in force, though it changed after the guest's offer was published")
    func pullReadsTheCeilingInForce() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let text = ClipboardContent.utf8TextUTI
        try await receive(Self.item(Self.representation(text, .inline)), on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)

        let lowered = ClipboardPasteLimit.choices[0]
        #expect(lowered != instance.effectiveClipboardMaxPasteBytes)
        instance.preferences.clipboardMaxPasteBytes = lowered
        let paste = Task.detached { pasteboard.invokeProvider(forType: NSPasteboard.PasteboardType(text)) }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        #expect(pulls(probe)[0].order.request.byteCeiling == UInt64(lowered))

        endGuestOffer(on: probe)
        #expect(await paste.value == nil)
    }

    @Test("A paste joining a smaller preview's pull pulls again when that one is too large, and lands as a file")
    func largerAskRepullsAndLandsInStaging() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(
            Self.item(Self.representation(ClipboardContent.utf8TextUTI, .inline)), on: probe, into: instance)
        let remote = try #require(instance.hubClipboard.exchange.remote)
        let content = Data("the guest's text".utf8)

        let preview = Task { await remote.previewBytes(item: 0, representation: 0, byteCeiling: 4) }
        try await probe.changed.wait { pulls(probe).count == 1 }
        #expect(pulls(probe)[0].order.request.byteCeiling == 4)
        let pasted = Locked<Data?>(nil)
        let landed = AsyncGate()
        remote.pullBytes(item: 0, representation: 0) { data in
            pasted.withLock { $0 = data }
            landed.notify()
        }
        // The paste joined the preview's pull rather than opening one of its own.
        #expect(pulls(probe).count == 1)

        let refused = open(pulls(probe)[0].id, stream: 3, on: probe)
        probe.deliver(
            .items(.pullEnded(.clipboard, refused, .failed(WireError(.tooLarge, limit: 4)))), fromConnection: 0)
        #expect(await preview.value == nil)
        try await probe.changed.wait { pulls(probe).count == 2 }
        let (requestID, order) = pulls(probe)[1]
        #expect(order.request.byteCeiling == UInt64(instance.effectiveClipboardMaxPasteBytes))
        #expect(order.budget == nil)

        // The INLINE representation lands as a file in clipboard staging, and the paste is served from it.
        #expect(order.landing.directory.hasPrefix(ClipboardFileStaging.processRoot.url.path + "/"))
        guard case .exactly(let name) = order.landing.name else {
            Issue.record("landing \(order.landing)")
            return
        }
        try content.write(
            to: URL(fileURLWithPath: order.landing.directory)
                .appendingPathComponent(String(decoding: name, as: UTF8.self)))
        let pull = open(requestID, stream: 5, on: probe)
        probe.deliver(.items(.pullEnded(.clipboard, pull, .landed(.named(name)))), fromConnection: 0)
        try await landed.wait { pasted.withLock { $0 } == content }

        // What landed answers each later ask its ceiling admits, pulling nothing more.
        #expect(await remote.previewBytes(item: 0, representation: 0, byteCeiling: 1024) == content)
        #expect(await remote.previewBytes(item: 0, representation: 0, byteCeiling: 4) == nil)
        #expect(pulls(probe).count == 2)
    }

    @Test("The guest's offer is released once the buffer and the Mac pasteboard have both moved on")
    func releasedWhenThePasteboardMovesOn() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(
            Self.item(Self.representation(ClipboardContent.utf8TextUTI, .inline)), on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        func released() -> Bool { probe.commands.contains(.items(.release(token: Self.guestToken))) }

        // The Mac pasteboard still holds the guest's copy: a paste may still pull it.
        instance.hubClipboard.clipboardContent = ClipboardContent(text: "edited in the window")
        await drainMainQueue()
        #expect(!released())

        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.setString("copied on the Mac", forType: .string))
        instance.hubClipboard.clipboardContent = ClipboardContent(text: "copied on the Mac")
        try await probe.changed.wait { released() }
    }
}
