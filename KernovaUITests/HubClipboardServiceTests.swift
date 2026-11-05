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
    private let scratch = TestScratchDirectory(prefix: "HubClipboardServiceTests")
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

    /// Has the connection open the last clipboard offer the hub sent, returning it once the exchange heard it
    /// opened.
    @discardableResult
    private func acceptLastOffer(_ probe: AgentHubProbe) async throws -> ItemOffer {
        let (id, offer) = try #require(offers(probe).last)
        probe.deliver(.itemReply(id, .offered(nil)), fromConnection: 0)
        await probe.settle()
        return offer
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

    /// Has the guest land `content` where `order` lands it, as pull `stream` of the hub's `request`.
    private func land(
        _ content: Data, for order: ItemPullOrder, request: ItemRequestID, stream: UInt32, on probe: AgentHubProbe
    ) throws {
        let landed: LandedItem
        switch order.landing {
        case .memory:
            landed = .inline(content)
        case .staged(let directory, .exactly(let name)):
            try content.write(
                to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
            landed = .named(name)
        case .staged:
            Issue.record("landing \(order.landing)")
            return
        }
        let pull = open(request, stream: stream, on: probe)
        probe.deliver(.items(.pullEnded(.clipboard, pull, .landed(landed))), fromConnection: 0)
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

    /// Has the guest offer `items` under `token`, made after it received the host offer `after`, answering the
    /// hub's reads of them, and waits for the host to take them.
    private func receive(
        _ items: OfferedItem..., on probe: AgentHubProbe, into instance: VMInstance, token: Data = guestToken,
        after: Data = Data(), concealed: Bool = false
    ) async throws {
        let shown = instance.hubClipboard.inboundOfferSeq
        let readsBefore = reads(probe).count
        deliverOffer(on: probe, token: token, after: after, concealed: concealed, count: items.count)
        try await probe.changed.wait { reads(probe).count == readsBefore + items.count }
        for (id, item) in reads(probe).dropFirst(readsBefore) {
            probe.deliver(.itemReply(id, .read(items[Int(item)])), fromConnection: 0)
        }
        try await waitForChange { instance.hubClipboard.inboundOfferSeq == shown + 1 }
    }

    private func deliverOffer(
        on probe: AgentHubProbe, token: Data, after: Data = Data(), concealed: Bool = false, count: Int = 1
    ) {
        let header = ItemSetHeaderValue(
            feature: .clipboard, token: token, concealed: concealed, count: count, after: after)
        probe.deliver(.items(.offerReceived(header)), fromConnection: 0)
    }

    private static let text = item(representation(ClipboardContent.utf8TextUTI, .inline))

    /// Installs a running passthrough on `instance`, as turning the setting on does.
    private func startPassthrough(_ instance: VMInstance) throws -> ClipboardPassthroughCoordinator {
        let context = try #require(instance.sessionContext)
        let coordinator = ClipboardPassthroughCoordinator(
            instance: instance, publisher: instance.hostClipboardPublisher, reporter: instance.clipboardTransfers)
        context.clipboardPassthroughCoordinator = coordinator
        coordinator.start()
        return coordinator
    }

    /// Has passthrough run on `instance` without its poll or its publish of the guest's offers, which the test
    /// drives itself: the host takes a guest offer only while passthrough runs.
    @discardableResult
    private func runPassthroughByHand(_ instance: VMInstance) throws -> ClipboardPassthroughCoordinator {
        let context = try #require(instance.sessionContext)
        let coordinator = ClipboardPassthroughCoordinator(
            instance: instance, publisher: instance.hostClipboardPublisher, reporter: instance.clipboardTransfers)
        context.clipboardPassthroughCoordinator = coordinator
        return coordinator
    }

    private func hostPasteboard(_ instance: VMInstance) throws -> FakePasteboard {
        try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
    }

    private func released(_ token: Data, _ probe: AgentHubProbe) -> Bool {
        probe.commands.contains(.items(.release(token: token)))
    }

    private func withdrawn(_ token: Data, _ probe: AgentHubProbe) -> Bool {
        probe.commands.contains(.items(.withdraw(token: token)))
    }

    // MARK: - Host → guest

    /// Has passthrough forward a copy of `text` on the Mac, returning the offer the console peer was sent.
    private func forwardMacCopy(
        _ text: String, _ instance: VMInstance, _ probe: AgentHubProbe
    ) async throws -> (offer: ItemOffer, pasteboard: FakePasteboard, coordinator: ClipboardPassthroughCoordinator) {
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        let coordinator = try runPassthroughByHand(instance)
        coordinator.pollHostClipboard()
        #expect(pasteboard.setString(text, forType: .string))
        coordinator.pollHostClipboard()
        try await probe.changed.wait { !offers(probe).isEmpty }
        let offer = try await acceptLastOffer(probe)
        await probe.settle()
        return (offer, pasteboard, coordinator)
    }

    /// The guest's pull of representation `index` of `offer`'s first item, as the hub's source asks the exchange
    /// for it.
    private func pull(_ offer: ItemOffer, representation index: Int = 0, from instance: VMInstance) async
        -> Result<ItemContent, WireError>
    {
        var request = PullRequest()
        request.token = offer.token
        request.representation = UInt32(index)
        let exchange = instance.hubClipboard.exchange
        let representation = offer.items[0].representations[index]
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

    // MARK: - One current clipboard

    @Test("A console peer returning after a newer guest copy is offered nothing stale")
    func noStaleReoffer() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let (first, _, _) = try await forwardMacCopy("older Mac copy", instance, probe)
        // The guest copies something newer, made after it received the Mac's copy.
        try await receive(Self.text, on: probe, into: instance, after: first.token)
        #expect(withdrawn(first.token, probe))
        #expect(instance.hubClipboard.exchange.localSource == nil)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }
        await probe.settle()
        #expect(offers(probe).count == 1)
    }

    @Test("With passthrough on, a guest clipboard clear retracts its landed bytes from the Mac")
    func passthroughRetractsClearedGuestContent() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        let text = ClipboardContent.utf8TextUTI
        try await receive(Self.text, on: probe, into: instance, concealed: true)
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)

        // One paste on the Mac lands the guest's text.
        let paste = Task.detached { pasteboard.invokeProvider(forType: NSPasteboard.PasteboardType(text)) }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        let (requestID, order) = try #require(pulls(probe).first)
        try land(Data("hunter2".utf8), for: order, request: requestID, stream: 3, on: probe)
        #expect(await paste.value == Data("hunter2".utf8))

        // The guest's password manager clears the guest clipboard: the guest withdraws its offer, no successor.
        probe.deliver(
            .items(.offerEnded(.clipboard, .remote, token: Self.guestToken, .resetByPeer(WireError(.cancelled)))),
            fromConnection: 0)
        try await hostPasteboard(instance).changed.wait { !instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
        #expect(pasteboard.promisedTypes.isEmpty)
        // Passthrough on: nothing is reported.
        #expect(instance.clipboardTransferReport == .idle)
    }

    @Test("A paste of the guest's concealed text lands it in memory, creating nothing under the staging root")
    func concealedPasteStagesNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try runPassthroughByHand(instance)
        try await receive(Self.text, on: probe, into: instance, concealed: true)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        let pasteboard = try hostPasteboard(instance)

        let password = Data("hunter2".utf8)
        let paste = Task.detached {
            pasteboard.invokeProvider(forType: NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI))
        }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        let (requestID, order) = try #require(pulls(probe).first)
        #expect(order.landing == .memory)
        try land(password, for: order, request: requestID, stream: 3, on: probe)

        #expect(await paste.value == password)
        let exchangeStaging = ClipboardFileStaging.processRoot.url
            .appendingPathComponent("host-\(instance.configuration.id.uuidString)")
        #expect(!FileManager.default.fileExists(atPath: exchangeStaging.path))
    }

    @Test("A guest offer made before it received the host's latest is refused unread; one naming it is taken")
    func crossingOfferLoses() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let (hostOffer, _, _) = try await forwardMacCopy("copied on the Mac", instance, probe)

        let crossing = Data(repeating: 3, count: 16)
        deliverOffer(on: probe, token: crossing)
        try await probe.changed.wait { released(crossing, probe) }
        #expect(reads(probe).isEmpty)
        #expect(instance.hubClipboard.exchange.localSource != nil)

        try await receive(Self.text, on: probe, into: instance, after: hostOffer.token)
        #expect(withdrawn(hostOffer.token, probe))
    }

    @Test("A guest offer crossing a Mac copy passthrough has not sent yet loses, and the Mac copy goes at once")
    func crossingUnsentMacCopyLoses() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        #expect(pasteboard.setString("copied on the Mac", forType: .string))

        let crossing = Data(repeating: 3, count: 16)
        deliverOffer(on: probe, token: crossing)
        try await probe.changed.wait { released(crossing, probe) && !offers(probe).isEmpty }
        #expect(reads(probe).isEmpty)
        let offered = try await acceptLastOffer(probe)
        await probe.settle()
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied on the Mac".utf8))))
    }

    @Test(
        "A lost connection retracts the guest's copy from the Mac; its return sends nothing, and the next copy crosses")
    func linkLossRetractsThenSendsNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        try await receive(Self.text, on: probe, into: instance)
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        await probe.settle()
        #expect(try hostPasteboard(instance).promisedTypes.isEmpty)
        #expect(offers(probe).isEmpty)
        // Passthrough on: nothing is reported.
        #expect(instance.clipboardTransferReport == .idle)

        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.setString("copied during the outage", forType: .string))
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }
        coordinator.pollHostClipboard()
        await probe.settle()
        #expect(offers(probe).isEmpty)

        #expect(pasteboard.setString("copied after the return", forType: .string))
        try await probe.changed.wait { !offers(probe).isEmpty }
        let offered = try await acceptLastOffer(probe)
        await probe.settle()
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied after the return".utf8))))
    }

    @Test("A connection's return with no Mac copy since offers nothing, and the guest's next copy is written")
    func linkReturnTakesTheGuestsNextCopy() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        try await receive(Self.text, on: probe, into: instance)
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }
        coordinator.pollHostClipboard()
        await probe.settle()
        #expect(offers(probe).isEmpty)

        try await receive(Self.text, on: probe, into: instance, token: Data(repeating: 8, count: 16))
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
    }

    @Test("A Mac copy that offers nothing withdraws the host's offer")
    func emptyMacCopyWithdraws() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.setString("copied on the Mac", forType: .string))
        try await probe.changed.wait { !offers(probe).isEmpty }
        let offered = try await acceptLastOffer(probe)
        await probe.settle()

        #expect(
            pasteboard.setItem([
                (.string, Data("a password".utf8)),
                (NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI), Data()),
            ]))
        try await probe.changed.wait { withdrawn(offered.token, probe) }
        #expect(offers(probe).count == 1)
    }

    @Test("With passthrough on, a Mac copy replaces the guest's clipboard: its offer released")
    func macCopySupersedesGuestOffer() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        try await receive(Self.text, on: probe, into: instance)
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }

        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.setString("copied on the Mac", forType: .string))
        try await probe.changed.wait { released(Self.guestToken, probe) && !offers(probe).isEmpty }
        #expect(instance.hubClipboard.exchange.remote == nil)
    }

    @Test(
        "A guest offer arriving while passthrough is off is let go unwritten, and turning passthrough on writes nothing"
    )
    func guestOfferWhilePassthroughOffIsLetGo() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let seq = instance.hubClipboard.inboundOfferSeq
        deliverOffer(on: probe, token: Self.guestToken)
        try await probe.changed.wait { reads(probe).count == 1 }
        probe.deliver(.itemReply(reads(probe)[0].id, .read(Self.text)), fromConnection: 0)
        try await probe.changed.wait { released(Self.guestToken, probe) }
        #expect(instance.hubClipboard.inboundOfferSeq == seq)
        #expect(instance.hubClipboard.exchange.remote == nil)

        let changeCount = try hostPasteboard(instance).changeCount
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        coordinator.pollHostClipboard()
        await probe.settle()
        #expect(try hostPasteboard(instance).changeCount == changeCount)
        #expect(offers(probe).isEmpty)
    }

    @Test("Turning passthrough on sends nothing of the Mac's copy standing; the next Mac copy crosses")
    func passthroughOnSendsNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.setString("copied on the Mac before", forType: .string))

        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        coordinator.pollHostClipboard()
        await probe.settle()
        #expect(offers(probe).isEmpty)

        #expect(pasteboard.setString("copied on the Mac after", forType: .string))
        try await probe.changed.wait { !offers(probe).isEmpty }
        let offered = try await acceptLastOffer(probe)
        await probe.settle()
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied on the Mac after".utf8))))
    }

    // MARK: - Guest → host

    @Test("A guest's offer is published to the Mac pasteboard, pulling nothing")
    func guestOfferIsPublished() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try runPassthroughByHand(instance)
        let text = ClipboardContent.utf8TextUTI
        try await receive(Self.item(Self.representation(text, .inline)), on: probe, into: instance)

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
        try runPassthroughByHand(instance)
        try await receive(
            Self.item(Self.representation("public.data", .file, name: "notes.bin")), on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)

        // The paste holds its thread until the pull lands, so it fires off the main actor.
        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        let (requestID, order) = try #require(pulls(probe).first)
        guard case .staged(let directory, .exactly(let name)) = order.landing else {
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
        try runPassthroughByHand(instance)
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
        try runPassthroughByHand(instance)
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
        try runPassthroughByHand(instance)
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
        try runPassthroughByHand(instance)
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

    // MARK: - Copy Mac Clipboard to Guest

    /// The finished report's failure under `gesture`, waiting for it.
    private func reported(_ instance: VMInstance, _ gesture: ClipboardTransferGesture) async throws
        -> ClipboardTransferFailure?
    {
        try await waitForChange {
            if case .finished(let finish) = instance.clipboardTransferReport {
                finish.gesture == gesture
            } else {
                false
            }
        }
        guard case .finished(let finish) = instance.clipboardTransferReport else { return nil }
        return finish.failure
    }

    /// Runs Copy Mac Clipboard to Guest, returning the copy the guest was sent.
    private func copyToGuest(_ instance: VMInstance, _ probe: AgentHubProbe) async throws -> ItemOffer {
        let before = offers(probe).count
        instance.copyMacClipboardToGuest()
        try await probe.changed.wait { offers(probe).count == before + 1 }
        return try #require(offers(probe).last).offer
    }

    @Test("Copy to Guest sends a copy of the Mac's text read at the command, served after the Mac's clipboard moves on")
    func copyToGuestSendsASnapshot() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try hostPasteboard(instance)
        #expect(pasteboard.setString("from the Mac", forType: .string))

        let copy = try await copyToGuest(instance, probe)
        #expect(copy.copy == .snapshot)
        #expect(copy.items.map { $0.representations.map(\.storage) } == [[.inline]])
        // Its bytes crossed at the command, so their size is known.
        #expect(copy.items[0].representations[0].sizeEstimate == UInt64("from the Mac".utf8.count))
        #expect(pasteboard.residentReads == [.string])

        // A later copy on the Mac never touches the snapshot, and withdraws nothing.
        #expect(pasteboard.setString("copied since", forType: .string))
        #expect(await pull(copy, from: instance) == .success(.inline(Data("from the Mac".utf8))))
        #expect(!withdrawn(copy.token, probe))
        #expect(instance.hubClipboard.exchange.localSource == nil)
    }

    @Test("Copy to Guest sends every type on the Mac's clipboard as it is")
    func copyToGuestIsUnfiltered() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try hostPasteboard(instance)
        #expect(
            pasteboard.setItem([
                (.string, Data("plain".utf8)), (.rtf, Data("{\\rtf1 rich}".utf8)), (.html, Data("<b>html</b>".utf8)),
                (NSPasteboard.PasteboardType("com.example.private-flavor"), Data([1, 2, 3])),
            ]))

        let copy = try await copyToGuest(instance, probe)
        #expect(
            copy.items[0].representations.map(\.type.appleUTI) == [
                "public.utf8-plain-text", "public.rtf", "public.html", "com.example.private-flavor",
            ])
    }

    @Test("Copy to Guest sends a file as a reference to the Mac's disk, served when pasted, after the Mac moves on")
    func copyToGuestDefersFiles() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("notes.bin")
        try Data("file bytes".utf8).write(to: file)
        let pasteboard = try hostPasteboard(instance)
        #expect(pasteboard.setFiles([file]))

        let copy = try await copyToGuest(instance, probe)
        #expect(copy.items.map { $0.representations.map(\.storage) } == [[.file]])
        #expect(pasteboard.setString("copied since", forType: .string))
        guard case .success(.tree(let path)) = await pull(copy, from: instance) else {
            Issue.record("the file was not served")
            return
        }
        #expect(path.hasSuffix("/notes.bin"))
    }

    @Test(
        "Copy to Guest reports the guest leaving its clipboard alone, and a copy over its ceiling",
        arguments: [
            (WireError(.clipboardChanged), ClipboardTransferFailure.clipboardChanged),
            (WireError(.tooLarge, limit: 1024), .tooLarge(limitBytes: 1024)),
        ])
    func copyToGuestRefusalIsReported(error: WireError, failure: ClipboardTransferFailure) async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        #expect(try hostPasteboard(instance).setString("from the Mac", forType: .string))
        let copy = try await copyToGuest(instance, probe)
        try await acceptLastOffer(probe)

        probe.deliver(
            .items(.offerEnded(.clipboard, .local, token: copy.token, .resetByPeer(error))), fromConnection: 0)
        #expect(try await reported(instance, .send) == failure)
    }

    @Test("Copy to Guest with nothing on the Mac's clipboard sends nothing and says so")
    func copyToGuestOfNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try hostPasteboard(instance).clearContents()

        instance.copyMacClipboardToGuest()
        #expect(try await reported(instance, .send) == .nothingToCopy)
        #expect(offers(probe).isEmpty)
    }

    @Test("A copy sent to the guest is served no more once its connection ends")
    func copyToGuestEndsWithTheLink() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        #expect(try hostPasteboard(instance).setString("from the Mac", forType: .string))
        let copy = try await copyToGuest(instance, probe)

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        guard case .failure(let error) = await pull(copy, from: instance) else {
            Issue.record("the copy was served after its connection ended")
            return
        }
        #expect(error.code == .itemRepresentationUnavailable)
    }

    // MARK: - Copy Guest Clipboard to Mac

    private static let copyToken = Data(repeating: 5, count: 16)

    /// Runs Copy Guest Clipboard to Mac and answers its ask with `items` as the guest's copy, the hub's reads of
    /// them answered; returns the ask.
    private func copyToMac(
        _ items: OfferedItem..., on probe: AgentHubProbe, into instance: VMInstance,
        before answering: () throws -> Void = {}
    ) async throws -> ItemOffer {
        let offersBefore = offers(probe).count
        instance.copyGuestClipboardToMac()
        try await probe.changed.wait { offers(probe).count == offersBefore + 1 }
        let ask = try #require(offers(probe).last).offer
        try answering()
        guard !items.isEmpty else {
            try await acceptLastOffer(probe)
            probe.deliver(
                .items(
                    .offerEnded(
                        .clipboard, .local, token: ask.token, .resetByPeer(WireError(.clipboardNothingToCopy)))),
                fromConnection: 0)
            return ask
        }
        let readsBefore = reads(probe).count
        probe.deliver(
            .items(
                .offerReceived(
                    ItemSetHeaderValue(
                        feature: .clipboard, token: Self.copyToken, concealed: false, count: items.count,
                        after: ask.token, copy: .snapshot))),
            fromConnection: 0)
        try await probe.changed.wait { reads(probe).count == readsBefore + items.count }
        for (id, item) in reads(probe).dropFirst(readsBefore) {
            probe.deliver(.itemReply(id, .read(items[Int(item)])), fromConnection: 0)
        }
        return ask
    }

    private static let textAndFile = item(
        representation(ClipboardContent.utf8TextUTI, .inline), representation("public.data", .file, name: "a.bin"))

    @Test("Copy to Mac asks the guest, lands its text at once, and writes it as data with the file promised")
    func copyToMacWritesDataAndPromisesFiles() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let ask = try await copyToMac(Self.textAndFile, on: probe, into: instance)
        #expect(ask.copy == .ask && ask.items.isEmpty)

        // Only the text is pulled now; the file waits for a paste.
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        #expect(order.request.representation == 0)
        try land(Data("the guest's".utf8), for: order, request: requestID, stream: 3, on: probe)

        let pasteboard = try hostPasteboard(instance)
        try await pasteboard.changed.wait { !pasteboard.dataByItem.isEmpty }
        #expect(
            pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("the guest's".utf8))
        #expect(pasteboard.promisedTypes == [.fileURL])
        #expect(pulls(probe).count == 1)
        #expect(!released(Self.copyToken, probe))
    }

    @Test("Copy to Mac leaves a Mac clipboard that changed after the command alone, and says so")
    func copyToMacLeavesAChangedClipboard() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try hostPasteboard(instance)
        _ = try await copyToMac(Self.text, on: probe, into: instance) {
            #expect(pasteboard.setString("copied meanwhile", forType: .string))
        }
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        try land(Data("the guest's".utf8), for: order, request: requestID, stream: 3, on: probe)

        #expect(try await reported(instance, .copy) == .clipboardChanged)
        #expect(pasteboard.items.first?.data(forType: .string) == Data("copied meanwhile".utf8))
        try await probe.changed.wait { released(Self.copyToken, probe) }
    }

    @Test("Copy to Mac's files stay served until the Mac's clipboard lets them go, and the copy is released then")
    func copyToMacReleasesWhenTheMacMovesOn() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(Self.textAndFile, on: probe, into: instance)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        try land(Data("the guest's".utf8), for: order, request: requestID, stream: 3, on: probe)
        let pasteboard = try hostPasteboard(instance)
        try await pasteboard.changed.wait { pasteboard.promisedTypes == [.fileURL] }
        await probe.settle()
        #expect(!released(Self.copyToken, probe))

        #expect(pasteboard.setString("the user's next copy", forType: .string))
        try await probe.changed.wait { released(Self.copyToken, probe) }
    }

    @Test("A copy of only text is released once written: nothing of it is left to pull")
    func copyToMacOfTextReleasesAtOnce() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(Self.text, on: probe, into: instance)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        try land(Data("the guest's".utf8), for: order, request: requestID, stream: 3, on: probe)
        try await probe.changed.wait { released(Self.copyToken, probe) }
        #expect(try hostPasteboard(instance).promisedTypes.isEmpty)
    }

    @Test("Copy to Mac's pending files are retracted when the guest's connection ends, its text kept, and that is said")
    func copyToMacRetractedWithTheLink() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(Self.textAndFile, on: probe, into: instance)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        try land(Data("the guest's".utf8), for: order, request: requestID, stream: 3, on: probe)
        let pasteboard = try hostPasteboard(instance)
        try await pasteboard.changed.wait { pasteboard.promisedTypes == [.fileURL] }

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await pasteboard.changed.wait { pasteboard.promisedTypes.isEmpty }
        #expect(
            pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("the guest's".utf8))
        #expect(try await reported(instance, .copy) == .disconnectedFilesRetracted)
    }

    @Test("Copy to Mac of files alone, its connection ending, clears what it wrote")
    func copyToMacOfFilesRetractedWithTheLink() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(
            Self.item(Self.representation("public.data", .file, name: "a.bin")), on: probe, into: instance)
        let pasteboard = try hostPasteboard(instance)
        try await pasteboard.changed.wait { pasteboard.promisedTypes == [.fileURL] }

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await pasteboard.changed.wait { pasteboard.promisedTypes.isEmpty }
        #expect(pasteboard.dataByItem.isEmpty)
        #expect(try await reported(instance, .copy) == .disconnectedCopyRetracted)
    }

    @Test("Copy to Mac from a guest clipboard holding nothing writes nothing and says so")
    func copyToMacOfNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(on: probe, into: instance)
        #expect(try await reported(instance, .copy) == .nothingToCopy)
        #expect(try hostPasteboard(instance).prepareCount == 0)
    }

    @Test("A guest copy answering no ask of the host's is refused unread")
    func unaskedCopyIsRefused() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        probe.deliver(
            .items(
                .offerReceived(
                    ItemSetHeaderValue(
                        feature: .clipboard, token: Self.copyToken, concealed: false, count: 1, copy: .snapshot))),
            fromConnection: 0)
        try await probe.changed.wait { released(Self.copyToken, probe) }
        #expect(reads(probe).isEmpty)
        #expect(instance.hubClipboard.exchange.copies.isEmpty)
    }

    // MARK: - The paste ceiling

    @Test("Copy to Mac of one file over the paste ceiling reports it too large and writes nothing")
    func copyToMacOfAnOversizeFile() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        var file = Self.representation("public.data", .file, name: "big.bin")
        file.sizeEstimate = 3 << 30
        var item = OfferedItem()
        item.representations = [file]
        _ = try await copyToMac(item, on: probe, into: instance)
        #expect(try await reported(instance, .copy) == .tooLarge(limitBytes: instance.effectiveClipboardMaxPasteBytes))
        #expect(try hostPasteboard(instance).prepareCount == 0)
        try await probe.changed.wait { released(Self.copyToken, probe) }
    }

    @Test("Copy to Mac of text and a file over the paste ceiling writes the text and says the file was left out")
    func copyToMacLeavesOutAnOversizeFile() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        var file = Self.representation("public.data", .file, name: "big.bin")
        file.sizeEstimate = 3 << 30
        _ = try await copyToMac(
            Self.item(Self.representation(ClipboardContent.utf8TextUTI, .inline), file), on: probe, into: instance)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        try land(Data("the guest's".utf8), for: order, request: requestID, stream: 3, on: probe)

        #expect(
            try await reported(instance, .copy)
                == .filesLeftOut(count: 1, limitBytes: instance.effectiveClipboardMaxPasteBytes))
        let pasteboard = try hostPasteboard(instance)
        #expect(
            pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("the guest's".utf8))
        #expect(pasteboard.promisedTypes.isEmpty)
    }

    @Test("A guest that wrote Copy to Guest without its files has that said, with the limit")
    func copyToGuestFilesWithheldIsReported() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("notes.bin")
        try Data("file bytes".utf8).write(to: file)
        #expect(try hostPasteboard(instance).setFiles([file]))
        let copy = try await copyToGuest(instance, probe)
        try await acceptLastOffer(probe)

        probe.deliver(
            .items(
                .offerEnded(
                    .clipboard, .local, token: copy.token,
                    .resetByPeer(WireError(.clipboardFilesWithheld, limit: 1024)))),
            fromConnection: 0)
        #expect(try await reported(instance, .send) == .filesLeftOut(count: 1, limitBytes: 1024))
    }

    @Test("Every pull of a guest copy lands against the copy's one budget, its staged text included")
    func copyPullsShareOneBudget() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(Self.textAndFile, on: probe, into: instance)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let order = pulls(probe)[0].order
        guard case .staged = order.landing else {
            Issue.record("the text landed \(order.landing)")
            return
        }
        let budget = try #require(order.budget)
        #expect(budget.limit == UInt64(instance.effectiveClipboardMaxPasteBytes))
    }

    @Test(
        "A copy sent to the guest serves each of its bytes once: the guest lands them, and the copy holds them no more")
    func copyToGuestServesItsBytesOnce() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        #expect(try hostPasteboard(instance).setString("from the Mac", forType: .string))
        let copy = try await copyToGuest(instance, probe)

        #expect(await pull(copy, from: instance) == .success(.inline(Data("from the Mac".utf8))))
        guard case .failure(let error) = await pull(copy, from: instance) else {
            Issue.record("the copy served its bytes twice")
            return
        }
        #expect(error.code == .itemRepresentationUnavailable)
    }

    // MARK: - Repeats, pauses and ends

    @Test("A second Copy to Mac while the first waits joins it: one ask, one write, no failure")
    func secondCopyToMacJoinsTheFirst() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let report = instance.clipboardTransferReport
        _ = try await copyToMac(Self.text, on: probe, into: instance) {
            instance.copyGuestClipboardToMac()
        }
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        try land(Data("the guest's".utf8), for: order, request: requestID, stream: 3, on: probe)
        try await waitForChange { instance.runningClipboardCommands.isEmpty }
        #expect(offers(probe).filter { $0.offer.copy == .ask }.count == 1)
        #expect(instance.clipboardTransferReport == report)
        #expect(
            try hostPasteboard(instance).dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("the guest's".utf8))
    }

    @Test("An ask ends with its connection: Copy to Mac reports it not copied, and can run again")
    func askEndsWithTheLink() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        instance.copyGuestClipboardToMac()
        try await probe.changed.wait { !offers(probe).isEmpty }

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        #expect(try await reported(instance, .copy) == .transferFailed)
        try await waitForChange { instance.runningClipboardCommands.isEmpty }
    }

    // MARK: - A clipboard this process wrote

    /// Turns passthrough off the way the setting does, once the hub sent what that asks of it.
    private func stopPassthrough(_ instance: VMInstance, _ probe: AgentHubProbe) async {
        instance.refreshClipboardPassthrough()
        #expect(instance.sessionContext?.clipboardPassthroughCoordinator == nil)
        await probe.settle()
    }

    @Test(
        "Turning passthrough off withdraws the host's offer, so the guest's write of it goes, and Copy to Mac says so")
    func passthroughOffWithdrawsTheHostsOffer() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("A.bin")
        try Data("file A".utf8).write(to: file)
        let pasteboard = try hostPasteboard(instance)
        _ = try startPassthrough(instance)
        #expect(pasteboard.setFiles([file]))
        try await probe.changed.wait { offers(probe).count == 1 }
        let hostOffer = try await acceptLastOffer(probe)

        await stopPassthrough(instance, probe)
        // The guest hears its clipboard's offer end, and retracts its promised write of it.
        #expect(withdrawn(hostOffer.token, probe))
        guard case .failure = await pull(hostOffer, from: instance) else {
            Issue.record("the withdrawn offer still served A")
            return
        }

        // With passthrough off, the Mac's next copy crosses nothing; Copy to Mac asks for the guest's clipboard,
        // which no longer holds A, and says what it found.
        #expect(pasteboard.setString("B", forType: .string))
        let macHoldsB = pasteboard.changeCount
        _ = try await copyToMac(on: probe, into: instance)
        #expect(try await reported(instance, .copy) == .nothingToCopy)
        #expect(pasteboard.changeCount == macHoldsB)
    }

    @Test("Turning passthrough off lets the guest's offer go, and retracts the Mac's write of it, its data kept")
    func passthroughOffRetractsTheGuestsOffer() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try startPassthrough(instance)
        let pasteboard = try hostPasteboard(instance)
        try await receive(Self.textAndFile, on: probe, into: instance)
        try await pasteboard.changed.wait { !pasteboard.promisedTypes.isEmpty }

        await stopPassthrough(instance, probe)
        #expect(released(Self.guestToken, probe))
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(instance.hubClipboard.exchange.remote == nil)
        // Nothing passthrough wrote remains promised, so nothing of the guest's can be pulled from the Mac.
        #expect(instance.hostClipboardPublisher.retractWrite(servingOffer: Self.guestToken) == nil)
    }

    @Test(
        "Copy to Guest of a Mac clipboard holding this VM's write of the guest's offer names it by reference, reading no promise"
    )
    func copyToGuestNamesTheGuestsOffer() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try runPassthroughByHand(instance)
        try await receive(Self.text, on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)

        let copy = try await copyToGuest(instance, probe)
        let reference = try #require(copy.items.first?.representations.first?.reference)
        #expect(reference.offer == Self.guestToken && reference.item == 0 && reference.representation == 0)
        #expect(pulls(probe).isEmpty)
        #expect(try hostPasteboard(instance).providerInvocations == 0)
        #expect(!released(Self.guestToken, probe))
    }

    @Test(
        "Copy to Guest of a Mac clipboard holding this VM's copy write sends its data and names its file by reference")
    func copyToGuestOfTheGuestsCopy() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(Self.textAndFile, on: probe, into: instance)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (textRequest, textOrder) = pulls(probe)[0]
        try land(Data("the guest's".utf8), for: textOrder, request: textRequest, stream: 3, on: probe)
        let pasteboard = try hostPasteboard(instance)
        try await pasteboard.changed.wait { pasteboard.promisedTypes == [.fileURL] }
        try await waitForChange { instance.runningClipboardCommands.isEmpty }

        let copy = try await copyToGuest(instance, probe)
        #expect(copy.copy == .snapshot)
        #expect(copy.items.map { $0.representations.map(\.storage) } == [[.inline, .file]])
        #expect(!copy.items[0].representations[0].hasReference)
        #expect(copy.items[0].representations[1].reference.offer == Self.copyToken)
        #expect(pulls(probe).count == 1)
        #expect(pasteboard.providerInvocations == 0)
        #expect(await pull(copy, from: instance) == .success(.inline(Data("the guest's".utf8))))
    }

    /// A FILE of the guest's copy naming item 0's first representation of the host's `copy` by reference.
    private static func reference(to copy: Data) -> Representation {
        var named = representation("public.data", .file, name: "notes.bin")
        var reference = RepresentationReference()
        reference.offer = copy
        named.reference = reference
        return named
    }

    @Test("A round trip: Copy to Guest, a new Mac copy, then Copy to Mac puts the guest's copy back on the Mac")
    func roundTripPutsTheGuestsCopyBack() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("notes.bin")
        try Data("file bytes".utf8).write(to: file)
        let pasteboard = try hostPasteboard(instance)
        #expect(pasteboard.setFiles([file]))
        let hostCopy = try await copyToGuest(instance, probe)
        try await acceptLastOffer(probe)
        try await waitForChange { instance.runningClipboardCommands.isEmpty }

        // A new copy on the Mac; the guest's clipboard still holds the file, which its copy names by reference.
        #expect(pasteboard.setString("copied since", forType: .string))
        _ = try await copyToMac(
            Self.item(Self.reference(to: hostCopy.token)), on: probe, into: instance)
        try await waitForChange { instance.runningClipboardCommands.isEmpty }
        #expect(pasteboard.dataByItem.first?[.fileURL] == Data(file.absoluteString.utf8))
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pulls(probe).isEmpty)
        await probe.settle()
        #expect(released(Self.copyToken, probe))
    }

    @Test("Copy to Mac of only references to what the Mac's clipboard still holds changes nothing, and says nothing")
    func copyToMacOfStandingReferencesChangesNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("notes.bin")
        try Data("file bytes".utf8).write(to: file)
        let pasteboard = try hostPasteboard(instance)
        #expect(pasteboard.setFiles([file]))
        let hostCopy = try await copyToGuest(instance, probe)
        try await acceptLastOffer(probe)
        try await waitForChange { instance.runningClipboardCommands.isEmpty }
        let before = pasteboard.changeCount
        let report = instance.clipboardTransferReport

        _ = try await copyToMac(Self.item(Self.reference(to: hostCopy.token)), on: probe, into: instance)
        try await waitForChange { instance.runningClipboardCommands.isEmpty }
        #expect(pasteboard.changeCount == before)
        #expect(instance.clipboardTransferReport == report)
        await probe.settle()
        #expect(
            probe.commands.contains(.items(.refuse(token: Self.copyToken, WireError(.clipboardAlreadyHeld)))))
    }

    @Test("Copy to Mac's reference the host can no longer fill is left out, and that is said")
    func copyToMacOfAGoneReference() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try hostPasteboard(instance)
        #expect(pasteboard.setString("the Mac's", forType: .string))
        let before = pasteboard.changeCount

        _ = try await copyToMac(
            Self.item(Self.reference(to: Data(repeating: 3, count: 16))), on: probe, into: instance)
        #expect(try await reported(instance, .copy) == .partsGone)
        #expect(pasteboard.changeCount == before)
    }

    // MARK: - Passthrough starts with nothing

    /// Ends the console peer's connection and brings it back.
    private func bounceLink(_ instance: VMInstance, _ probe: AgentHubProbe) async throws {
        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }
    }

    @Test(
        "Passthrough off, a guest copy, a newer Mac copy, a sharing bounce, then passthrough on: each clipboard stays as it was"
    )
    func passthroughOnAfterBounceSendsNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try hostPasteboard(instance)
        // A guest offer crossing passthrough's being off is let go: the guest's own agent offers nothing.
        deliverOffer(on: probe, token: Self.guestToken)
        try await probe.changed.wait { reads(probe).count == 1 }
        probe.deliver(.itemReply(reads(probe)[0].id, .read(Self.text)), fromConnection: 0)
        try await probe.changed.wait { released(Self.guestToken, probe) }
        #expect(pasteboard.setString("the Mac's newer copy", forType: .string))
        let macHolds = pasteboard.changeCount
        try await bounceLink(instance, probe)

        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        coordinator.pollHostClipboard()
        await probe.settle()
        #expect(offers(probe).isEmpty)
        #expect(pasteboard.changeCount == macHolds)
        #expect(pasteboard.items.first?.data(forType: .string) == Data("the Mac's newer copy".utf8))
    }

    @Test("With passthrough on, a returning guest is sent nothing, and the next Mac copy crosses, each time")
    func restartedGuestGetsTheNextCopyEachTime() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        #expect(try hostPasteboard(instance).setString("the Mac's copy", forType: .string))
        try await probe.changed.wait { offers(probe).count == 1 }
        try await acceptLastOffer(probe)
        await probe.settle()

        for round in 1...2 {
            try await bounceLink(instance, probe)
            coordinator.pollHostClipboard()
            await probe.settle()
            #expect(offers(probe).count == round)

            let text = "the Mac's copy after return \(round)"
            #expect(try hostPasteboard(instance).setString(text, forType: .string))
            try await probe.changed.wait { offers(probe).count == 1 + round }
            let offered = try await acceptLastOffer(probe)
            await probe.settle()
            #expect(await pull(offered, from: instance) == .success(.inline(Data(text.utf8))))
        }
    }

    @Test("A Kernova launch's first connection sends nothing of the Mac's copy standing; the next copy crosses")
    func firstConnectionSendsNothing() async throws {
        let probe = AgentHubProbe()
        let instance = VMInstanceFixture.make(
            guestOS: .macOS, phase: .running(sessionID: UUID()), agentConnector: probe)
        instance.beginSessionContextForTesting()
        let pasteboard = try hostPasteboard(instance)
        #expect(pasteboard.setString("copied before the launch's connection", forType: .string))
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }

        instance.attachAgentTransport(probe)
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connect())
        probe.deliver(.helloReceived(Self.claim, Self.onConsole), fromConnection: 0)
        probe.deliver(.featuresChanged(Self.clipboard), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected && instance.clipboardRoute != .none }
        coordinator.pollHostClipboard()
        await probe.settle()
        #expect(offers(probe).isEmpty)

        #expect(pasteboard.setString("copied after", forType: .string))
        try await probe.changed.wait { !offers(probe).isEmpty }
    }

    // MARK: - Lower findings

    @Test("A host offer the connection refused is not the host's latest: a guest offer naming none is taken")
    func refusedHostOfferIsNotTheLatest() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try runPassthroughByHand(instance)
        coordinator.pollHostClipboard()
        #expect(try hostPasteboard(instance).setString("from the Mac", forType: .string))
        coordinator.pollHostClipboard()
        try await probe.changed.wait { !offers(probe).isEmpty }
        probe.deliver(.itemReply(offers(probe)[0].id, .offered(WireError(.internal))), fromConnection: 0)
        await probe.settle()
        #expect(instance.hubClipboard.exchange.localSource == nil)

        try await receive(Self.text, on: probe, into: instance)
    }

    @Test("A concealed guest offer's in-memory pulls land against the offer's one budget")
    func memoryPullsShareTheBudget() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try runPassthroughByHand(instance)
        try await receive(
            Self.item(
                Self.representation(ClipboardContent.utf8TextUTI, .inline), Self.representation("public.rtf", .inline)),
            on: probe, into: instance, concealed: true)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        let pasteboard = try hostPasteboard(instance)

        let first = Task.detached {
            pasteboard.invokeProvider(forType: NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI))
        }
        let second = Task.detached { pasteboard.invokeProvider(forType: .rtf) }
        try await probe.changed.wait { pulls(probe).count == 2 }
        let orders = pulls(probe).map(\.order)
        #expect(orders.allSatisfy { $0.landing == .memory })
        let budget = try #require(orders[0].budget)
        #expect(orders[1].budget === budget)
        #expect(budget.limit == UInt64(instance.effectiveClipboardMaxPasteBytes))

        endGuestOffer(on: probe)
        #expect(await first.value == nil)
        #expect(await second.value == nil)
    }

    // MARK: - Another VM's write on the Mac

    /// Another VM's offer: answers every INLINE pull with `bytes` and every file pull with `file`, until it ends.
    private final class OtherVMPuller: ClipboardItemPulling {
        let bytes: Data
        let file: URL?
        private let state = Locked<(ended: Bool, handlers: [@Sendable () -> Void])>((false, []))
        init(bytes: Data, file: URL? = nil) {
            self.bytes = bytes
            self.file = file
        }
        func pullBytes(item: Int, representation: Int, completion: @escaping @Sendable (Data?) -> Void) {
            completion(state.withLock { $0.ended } ? nil : bytes)
        }
        func pullFile(item: Int, representation: Int, completion: @escaping @Sendable (URL?) -> Void) {
            completion(state.withLock { $0.ended } ? nil : file)
        }
        func whenEnded(_ handler: @escaping @Sendable () -> Void) {
            let ended = state.withLock { state -> Bool in
                if !state.ended { state.handlers.append(handler) }
                return state.ended
            }
            if ended { handler() }
        }
        /// Ends the offer, as VM A's exchange does releasing its copy once the Mac lets it go.
        func end() {
            let handlers = state.withLock { state -> [@Sendable () -> Void] in
                state.ended = true
                defer { state.handlers = [] }
                return state.handlers
            }
            for handler in handlers { handler() }
        }
    }

    @Test("Copy to Guest of another VM's passthrough text sends that text as data, read at the command")
    func copyToGuestOfAnotherVMsPassthroughWrite() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try hostPasteboard(instance)
        // VM A's host publisher writes its guest's passthrough offer of text to the Mac pasteboard this VM's
        // commands read.
        let otherVM = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        #expect(
            otherVM.publish(
                [Self.text], concealed: false, puller: OtherVMPuller(bytes: Data("from VM A".utf8)),
                serving: .init(token: Data(repeating: 0xA1, count: 16), connection: ClipboardConnectionID())))

        let copy = try await copyToGuest(instance, probe)
        let representation = try #require(copy.items.first?.representations.first)
        #expect(!representation.hasReference)
        #expect(representation.sizeEstimate == UInt64("from VM A".utf8.count))
        #expect(pasteboard.providerInvocations == 0)
        try await acceptLastOffer(probe)
        #expect(await pull(copy, from: instance) == .success(.inline(Data("from VM A".utf8))))
    }

    /// VM A's Copy Guest Clipboard to Mac of text and `file`, written to `pasteboard` and pulled through
    /// `puller`, which ends once the Mac lets the write's file go, as A's exchange releases its copy then.
    private func writeAnotherVMsCopy(of file: URL, on pasteboard: FakePasteboard) -> OtherVMPuller {
        let otherVM = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        let puller = OtherVMPuller(bytes: Data(), file: file)
        let (written, promised) = otherVM.publishCopy(
            [Self.textAndFile], concealed: false, servingFileURLs: true,
            held: { _, representation in representation == 0 ? .bytes(Data("VM A's text".utf8)) : nil },
            puller: puller,
            serving: .init(token: Data(repeating: 0xA2, count: 16), connection: ClipboardConnectionID()),
            onReleased: { puller.end() })
        #expect(written && promised)
        return puller
    }

    private func anotherVMsFile() throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("a.bin")
        try Data("VM A's file".utf8).write(to: file)
        return file
    }

    @Test("Copy to Guest of another VM's copy sends its text as data and serves its file from that VM's copy")
    func copyToGuestOfAnotherVMsCopyWrite() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let file = try anotherVMsFile()
        _ = writeAnotherVMsCopy(of: file, on: try hostPasteboard(instance))

        let copy = try await copyToGuest(instance, probe)
        let representations = try #require(copy.items.first?.representations)
        #expect(representations.map(\.hasReference) == [false, false])
        #expect(representations.map(\.storage) == [.inline, .file])
        try await acceptLastOffer(probe)
        #expect(await pull(copy, from: instance) == .success(.inline(Data("VM A's text".utf8))))
        // The guest's paste of the file gets VM A's.
        #expect(await pull(copy, representation: 1, from: instance) == .success(.tree(path: file.path)))
    }

    @Test("Another VM's copy ending, the Mac having moved on, withdraws this VM's copy of it, so the guest retracts it")
    func anotherVMsCopyEndingWithdrawsTheCopy() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try hostPasteboard(instance)
        _ = writeAnotherVMsCopy(of: try anotherVMsFile(), on: pasteboard)
        let copy = try await copyToGuest(instance, probe)
        try await acceptLastOffer(probe)
        #expect(!withdrawn(copy.token, probe))

        // A new copy on the Mac replaces VM A's write, and VM A's copy ends.
        #expect(pasteboard.setString("copied since", forType: .string))
        try await probe.changed.wait { withdrawn(copy.token, probe) }
        guard case .failure = await pull(copy, representation: 1, from: instance) else {
            Issue.record("the copy's file was served after its upstream ended")
            return
        }
    }

    @Test("A clear of the guest's clipboard retracts the Mac's write of it, after a paste had every promised type too")
    func clearAfterAFullPasteRetracts() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        let text = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        try await receive(Self.text, on: probe, into: instance, concealed: true)
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
        let pasteboard = try hostPasteboard(instance)

        // One paste on the Mac lands the guest's password: the item's one promised type is provided.
        let paste = Task.detached { pasteboard.invokeProvider(forType: text) }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        let (requestID, order) = try #require(pulls(probe).first)
        try land(Data("hunter2".utf8), for: order, request: requestID, stream: 3, on: probe)
        #expect(await paste.value == Data("hunter2".utf8))
        // AppKit, every promised type provided with the write still standing, finishes with the provider.
        pasteboard.finishProvider(itemIndex: 0)
        let standing = pasteboard.changeCount

        // The guest's password manager clears the guest clipboard: the guest withdraws its offer, no successor.
        endGuestOffer(on: probe)
        await probe.settle()
        #expect(pasteboard.changeCount != standing)
        #expect(pasteboard.items.isEmpty)
    }
}
