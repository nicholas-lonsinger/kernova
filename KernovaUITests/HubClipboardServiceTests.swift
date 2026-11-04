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
    /// hub's reads of them, and waits for the buffer to show them.
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

    // MARK: - One current clipboard

    @Test("A console peer returning after a newer guest copy is offered nothing stale")
    func noStaleReoffer() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let (first, _, _) = try await forwardMacCopy("older Mac copy", instance, probe)
        probe.deliver(.itemReply(offers(probe)[0].id, .offered(nil)), fromConnection: 0)

        // The guest copies something newer, made after it received the Mac's copy.
        try await receive(Self.text, on: probe, into: instance, after: first.token)
        #expect(withdrawn(first.token, probe))
        #expect(instance.hubClipboard.exchange.localSource == nil)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }
        await drainMainQueue()
        #expect(offers(probe).count == 1)
    }

    @Test("With passthrough on, a guest clipboard clear retracts its landed bytes from the Mac and the window")
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
        #expect(instance.hubClipboard.clipboardContent.isEmpty)
        // Passthrough on: nothing is reported, since its Copy to Mac is not offered.
        #expect(instance.clipboardTransferReport == .idle)
    }

    @Test("A paste of the guest's concealed text lands it in memory, creating nothing under the staging root")
    func concealedPasteStagesNothing() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
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

    @Test(
        "With passthrough off, a guest offer's end retracts its Copy to Mac and says whether a newer one follows",
        arguments: [(ErrorCode.cancelled, false), (ErrorCode.itemOfferReplaced, true)])
    func copyToMacRetracted(code: ErrorCode, hasSuccessor: Bool) async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(Self.text, on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)

        probe.deliver(
            .items(.offerEnded(.clipboard, .remote, token: Self.guestToken, .resetByPeer(WireError(code)))),
            fromConnection: 0)
        try await hostPasteboard(instance).changed.wait { !instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
        guard case .finished(let finish) = instance.clipboardTransferReport else {
            Issue.record("nothing reported: \(instance.clipboardTransferReport)")
            return
        }
        #expect(finish.outcome == .failed(.supersededCopyRetracted(hasSuccessor: hasSuccessor)))
        // The window empties unless the guest's next copy follows to replace it.
        #expect(instance.hubClipboard.clipboardContent.isEmpty == !hasSuccessor)
    }

    @Test("A guest offer made before it received the host's latest is refused unread; one naming it is taken")
    func crossingOfferLoses() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        instance.hubClipboard.clipboardContent = ClipboardContent(text: "the window's")
        #expect(instance.hubClipboard.grabIfChanged() == .settled)
        try await probe.changed.wait { offers(probe).count == 1 }
        let hostOffer = offers(probe)[0].offer

        let crossing = Data(repeating: 3, count: 16)
        deliverOffer(on: probe, token: crossing)
        try await probe.changed.wait { released(crossing, probe) }
        #expect(reads(probe).isEmpty)
        #expect(instance.hubClipboard.clipboardContent == ClipboardContent(text: "the window's"))

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
        let offered = try #require(offers(probe).last).offer
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied on the Mac".utf8))))
    }

    @Test("A lost connection retracts the guest's copy from the Mac, not the window; its return offers a newer copy")
    func linkLossRetractsThenReoffers() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        try await receive(Self.text, on: probe, into: instance)
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        await drainMainQueue()
        #expect(try hostPasteboard(instance).promisedTypes.isEmpty)
        #expect(!instance.hubClipboard.clipboardContent.isEmpty)
        #expect(offers(probe).isEmpty)
        // Passthrough on: nothing is reported, since its Copy to Mac is not offered.
        #expect(instance.clipboardTransferReport == .idle)

        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.setString("copied during the outage", forType: .string))
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }
        try await probe.changed.wait { !offers(probe).isEmpty }
        let offered = try #require(offers(probe).last).offer
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied during the outage".utf8))))
    }

    @Test("A connection's return with no Mac copy since offers nothing, and the guest's re-offer is written again")
    func linkReturnTakesGuestReoffer() async throws {
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
        await drainMainQueue()
        #expect(offers(probe).isEmpty)

        // The restarted agent re-offers its copy, having received nothing on its new connection.
        try await receive(Self.text, on: probe, into: instance, token: Data(repeating: 8, count: 16))
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
    }

    @Test("With passthrough off, a lost connection retracts the guest's Copy to Mac and says so")
    func copyToMacRetractedOnLinkLoss() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(Self.text, on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)
        #expect(instance.hostClipboardPublisher.pasteboardHoldsLastWrite)

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await hostPasteboard(instance).changed.wait { !instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
        guard case .finished(let finish) = instance.clipboardTransferReport else {
            Issue.record("nothing reported: \(instance.clipboardTransferReport)")
            return
        }
        #expect(finish.outcome == .failed(.disconnectedCopyRetracted))
        // The guest may hold its copy still, so the window keeps showing it.
        #expect(!instance.hubClipboard.clipboardContent.isEmpty)
    }

    @Test("Stopping the VM's agent services retracts the guest's copy from the Mac")
    func vmStopRetracts() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        try await receive(Self.text, on: probe, into: instance)
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }

        try #require(instance.sessionContext).stopVsockServices()
        // The acceptor's shutdown ends the connection; the probe's connections run no driver to report it.
        probe.deliver(.closed(.transportLost), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        await drainMainQueue()
        #expect(try hostPasteboard(instance).promisedTypes.isEmpty)
    }

    @Test("Clear on the guest's copy offers the guest no items, releases its offer and retracts its Copy to Mac")
    func clearClearsTheGuestsCopy() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(Self.text, on: probe, into: instance)
        _ = try await instance.hostClipboardPublisher.publish(from: instance.hubClipboard)

        instance.hubClipboard.clearBuffer()
        try await probe.changed.wait { !offers(probe).isEmpty }
        let clear = try #require(offers(probe).last).offer
        #expect(clear.items.isEmpty)
        #expect(released(Self.guestToken, probe))
        #expect(!instance.hostClipboardPublisher.pasteboardHoldsLastWrite)
        #expect(try hostPasteboard(instance).promisedTypes.isEmpty)
        #expect(instance.hubClipboard.clipboardContent.isEmpty)
        // The user cleared it, so nothing is reported.
        #expect(instance.clipboardTransferReport == .idle)

        // The guest's copy made after it received the clear is taken.
        try await receive(
            Self.text, on: probe, into: instance, token: Data(repeating: 8, count: 16), after: clear.token)
    }

    @Test("Clear on the window's own content withdraws its offer")
    func clearWithdrawsWindowContent() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        instance.hubClipboard.clipboardContent = ClipboardContent(text: "typed in the window")
        #expect(instance.hubClipboard.grabIfChanged() == .settled)
        try await probe.changed.wait { !offers(probe).isEmpty }
        let offered = try #require(offers(probe).last).offer

        instance.hubClipboard.clearBuffer()
        try await probe.changed.wait { withdrawn(offered.token, probe) }
        #expect(offers(probe).count == 1)
        #expect(instance.hubClipboard.clipboardContent.isEmpty)
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
        let offered = try #require(offers(probe).last).offer

        #expect(
            pasteboard.setItem([
                (.string, Data("a password".utf8)),
                (NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI), Data()),
            ]))
        try await probe.changed.wait { withdrawn(offered.token, probe) }
        #expect(offers(probe).count == 1)
    }

    @Test("With passthrough on, a Mac copy replaces the guest's clipboard: its offer released, the window emptied")
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
        #expect(instance.hubClipboard.clipboardContent.isEmpty)
        #expect(instance.hubClipboard.guestHoldsMacCopy)
    }

    @Test("A Mac copy passthrough offers empties the window's own content, until a guest copy replaces it")
    func macCopyHeldUntilAGuestCopy() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        instance.hubClipboard.clipboardContent = ClipboardContent(text: "typed in the window")
        #expect(instance.hubClipboard.grabIfChanged() == .settled)
        try await probe.changed.wait { offers(probe).count == 1 }

        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        #expect(try hostPasteboard(instance).setString("copied on the Mac", forType: .string))
        try await probe.changed.wait { offers(probe).count == 2 }
        try await waitForChange { instance.hubClipboard.guestHoldsMacCopy }
        #expect(instance.hubClipboard.clipboardContent.isEmpty)

        try await receive(Self.text, on: probe, into: instance, after: offers(probe)[1].offer.token)
        #expect(!instance.hubClipboard.guestHoldsMacCopy)
        #expect(!instance.hubClipboard.clipboardContent.isEmpty)
    }

    @Test("Turning passthrough on publishes a guest copy newer than the Mac's")
    func passthroughOnPublishesNewerGuestCopy() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(Self.text, on: probe, into: instance)
        #expect(!instance.hostClipboardPublisher.pasteboardHoldsLastWrite)

        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
        #expect(offers(probe).isEmpty)
    }

    @Test("Turning passthrough on offers a Mac copy newer than the guest's")
    func passthroughOnOffersNewerMacCopy() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try await receive(Self.text, on: probe, into: instance)
        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.setString("copied on the Mac since", forType: .string))

        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        try await probe.changed.wait { !offers(probe).isEmpty }
        #expect(!instance.hostClipboardPublisher.pasteboardHoldsLastWrite)
        let offered = try #require(offers(probe).last).offer
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied on the Mac since".utf8))))
        #expect(released(Self.guestToken, probe))
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
        guard case .staged(let directory, _) = order.landing else {
            Issue.record("landing \(order.landing)")
            return
        }
        #expect(directory.hasPrefix(ClipboardFileStaging.processRoot.url.path + "/"))
        try land(content, for: order, request: requestID, stream: 5, on: probe)
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
