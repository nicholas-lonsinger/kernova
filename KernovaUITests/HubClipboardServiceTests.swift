import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaCommandModel
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaTransferProgress
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

    /// A running macOS VM staging under `stagingRoot`, its clipboard readouts measured on `transferClock`, whose
    /// hub's one connection is a session peer on the console carrying CLIPBOARD.
    private func connected(
        _ probe: AgentHubProbe, stagingRoot: ProcessStagingRoot = ClipboardFileStaging.processRoot,
        transferClock: any EngineClock = makePlatformEngineClock()
    ) async throws -> VMInstance {
        let instance = VMInstanceFixture.make(
            guestOS: .macOS, phase: .running(sessionID: UUID()), agentConnector: probe, stagingRoot: stagingRoot,
            transferClock: transferClock)
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
        case .staged, .exactPath:
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
        withdrawal(of: token, probe) != nil
    }

    /// The code the offer `token` was withdrawn with, or nil when it was not.
    private func withdrawal(of token: Data, _ probe: AgentHubProbe) -> ErrorCode? {
        probe.commands.lazy.compactMap {
            if case .items(.withdraw(token, let code)) = $0 { code } else { nil }
        }.first
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

    // MARK: - One current clipboard

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
        try await waitForChange { !instance.hubClipboard.isConnected && instance.clipboardRoute == .none }
        await probe.settle()
        #expect(try hostPasteboard(instance).promisedTypes.isEmpty)
        #expect(offers(probe).isEmpty)
        // Passthrough on: nothing is reported.
        #expect(instance.clipboardTransferReport == .idle)

        let pasteboard = try #require(instance.hostClipboardPublisher.pasteboard as? FakePasteboard)
        #expect(pasteboard.setString("copied during the outage", forType: .string))
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected && instance.clipboardRoute != .none }
        coordinator.pollHostClipboard()
        await probe.settle()
        #expect(offers(probe).isEmpty)

        #expect(pasteboard.setString("copied after the return", forType: .string))
        try await probe.changed.wait { !offers(probe).isEmpty }
        let offered = try await acceptLastOffer(probe)
        await probe.settle()
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied after the return".utf8))))
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

    // MARK: - Guest → host

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

    @Test("Copy to Guest the guest's user cancelled on the guest's readout is not reported here")
    func copyToGuestCancelledInTheGuestIsNotReported() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        #expect(try hostPasteboard(instance).setString("from the Mac", forType: .string))
        let copy = try await copyToGuest(instance, probe)
        try await acceptLastOffer(probe)
        let before = instance.clipboardTransferReport

        probe.deliver(
            .items(.offerEnded(.clipboard, .local, token: copy.token, .resetByPeer(WireError(.cancelled)))),
            fromConnection: 0)
        await probe.settle()
        await drainMainQueue()
        #expect(instance.clipboardTransferReport == before)
    }

    @Test("Copy to Guest of a Mac clipboard whose every file this Mac cannot open sends nothing and says so")
    func copyToGuestOfUnreadableFiles() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let locked = scratch.url.appendingPathComponent("locked.bin")
        try Data("locked".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        #expect(try hostPasteboard(instance).setFiles([locked]))

        instance.copyMacClipboardToGuest()
        #expect(try await reported(instance, .send) == .itemsUnreadable)
        #expect(offers(probe).isEmpty)
    }

    // MARK: - Copy Guest Clipboard to Mac

    private static let copyToken = Data(repeating: 5, count: 16)

    /// Runs Copy Guest Clipboard to Mac and answers its ask with `items` as the guest's copy, the hub's reads of
    /// them answered; returns the ask.
    private func copyToMac(
        _ items: OfferedItem..., on probe: AgentHubProbe, into instance: VMInstance, leftOut: Int = 0,
        concealed: Bool = false, declining code: ErrorCode = .clipboardNothingToCopy,
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
                    .offerEnded(.clipboard, .local, token: ask.token, .resetByPeer(WireError(code)))),
                fromConnection: 0)
            return ask
        }
        let readsBefore = reads(probe).count
        probe.deliver(
            .items(
                .offerReceived(
                    ItemSetHeaderValue(
                        feature: .clipboard, token: Self.copyToken, concealed: concealed, count: items.count,
                        after: ask.token, copy: .snapshot, leftOut: leftOut))),
            fromConnection: 0)
        try await probe.changed.wait { reads(probe).count == readsBefore + items.count }
        for (id, item) in reads(probe).dropFirst(readsBefore) {
            probe.deliver(.itemReply(id, .read(items[Int(item)])), fromConnection: 0)
        }
        return ask
    }

    private static let textAndFile = item(
        representation(ClipboardContent.utf8TextUTI, .inline), representation("public.data", .file, name: "a.bin"))

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

    @Test("Copy to Mac cancelled on its readout writes nothing, and the cancel is all that is said")
    func copyToMacCancelledOnItsReadout() async throws {
        let probe = AgentHubProbe()
        let clock = GatedEngineClock()
        let instance = try await connected(probe, transferClock: clock)
        _ = try await copyToMac(Self.text, on: probe, into: instance)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        let pull = open(requestID, stream: 3, on: probe)
        await probe.settle()
        clock.advance(seconds: 1)
        order.progress?.advanced(landed: 1, declared: 10)
        try await waitForChange {
            if case .running = instance.clipboardTransferReport { true } else { false }
        }
        guard case .running(let readout, _) = instance.clipboardTransferReport else { return }
        #expect(readout.gesture == .copy)

        #expect(instance.clipboardTransfers.cancel(readout.operationID))
        try await waitForChange {
            if case .finished = instance.clipboardTransferReport { true } else { false }
        }
        guard case .finished(let finish) = instance.clipboardTransferReport, case .cancelled = finish.outcome else {
            Issue.record("the readout ended \(instance.clipboardTransferReport)")
            return
        }
        try await probe.changed.wait { cancels(probe) == [pull] }
        probe.deliver(
            .items(.pullEnded(.clipboard, pull, .closed(.resetLocally(WireError(.cancelled))))), fromConnection: 0)
        try await waitForChange { !instance.runningClipboardCommands.contains(.copyGuestClipboardToMac) }
        // No failure replaced the cancel's report.
        if case .finished(let after) = instance.clipboardTransferReport { #expect(after.failure == nil) }
        #expect(try hostPasteboard(instance).prepareCount == 0)
    }

    @Test("Copy to Mac that lands ends its readout completed at its whole size, not withdrawn, once the copy is let go")
    func copyToMacThatLandsCompletesItsReadout() async throws {
        let probe = AgentHubProbe()
        // Gated, so the readout's idle gap never passes: only the landing can complete it.
        let clock = GatedEngineClock()
        let instance = try await connected(probe, transferClock: clock)
        _ = try await copyToMac(Self.text, on: probe, into: instance)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        let content = Data("the guest's".utf8)
        let pull = open(requestID, stream: 3, on: probe)
        await probe.settle()
        clock.advance(seconds: 1)
        order.progress?.advanced(landed: 1, declared: UInt64(content.count))
        try await waitForChange {
            if case .running = instance.clipboardTransferReport { true } else { false }
        }

        guard case .staged(let directory, .exactly(let name)) = order.landing else {
            Issue.record("landing \(order.landing)")
            return
        }
        try content.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
        probe.deliver(.items(.pullEnded(.clipboard, pull, .landed(.named(name)))), fromConnection: 0)
        try await probe.changed.wait { released(Self.copyToken, probe) }
        try await waitForChange { !instance.runningClipboardCommands.contains(.copyGuestClipboardToMac) }
        await drainMainQueue()

        guard case .finished(let finish) = instance.clipboardTransferReport,
            case .completed(let final) = finish.outcome
        else {
            Issue.record("the readout ended \(instance.clipboardTransferReport)")
            return
        }
        #expect(final.bytesTransferred == UInt64(content.count))
        #expect(final.totalBytes == UInt64(content.count))
    }

    /// Has the guest land each of the `count` pulls the hub asked for, each as `content` gives for its order.
    private func landPulls(
        _ count: Int, on probe: AgentHubProbe, _ content: (ItemPullOrder) -> Data
    ) async throws {
        try await probe.changed.wait { pulls(probe).count == count }
        for (index, (request, order)) in pulls(probe).enumerated() {
            try land(content(order), for: order, request: request, stream: UInt32(3 + 2 * index), on: probe)
        }
    }

    private static let textType = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)

    @Test(
        "Copy to Mac's item of an unpasted file goes whole with the connection, its name too; the rest stays, and that is said"
    )
    func copyToMacRetractedWithTheLink() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(Self.text, Self.textAndFile, on: probe, into: instance)
        try await landPulls(2, on: probe) { Data($0.request.item == 0 ? "the guest's".utf8 : "a.bin".utf8) }
        let pasteboard = try hostPasteboard(instance)
        try await pasteboard.changed.wait { pasteboard.promisedTypes == [.fileURL] }
        #expect(pasteboard.dataByItem.map { $0[Self.textType] } == [Data("the guest's".utf8), Data("a.bin".utf8)])

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await pasteboard.changed.wait { pasteboard.promisedTypes.isEmpty }
        #expect(pasteboard.dataByItem == [[Self.textType: Data("the guest's".utf8)]])
        #expect(try await reported(instance, .copy) == .disconnectedFilesRetracted)
    }

    /// Has the guest reset its copy `code`, its connection still up: `CANCELLED` withdraws it.
    private func withdrawGuestCopy(on probe: AgentHubProbe, _ code: ErrorCode = .cancelled) {
        probe.deliver(
            .items(.offerEnded(.clipboard, .remote, token: Self.copyToken, .resetByPeer(WireError(code)))),
            fromConnection: 0)
    }

    /// Runs Copy to Mac of the guest's concealed text, waiting for its write, which holds the copy: not released.
    private func concealedCopyToMac(
        _ probe: AgentHubProbe, _ instance: VMInstance
    ) async throws -> FakePasteboard {
        _ = try await copyToMac(Self.text, on: probe, into: instance, concealed: true)
        try await landPulls(1, on: probe) { _ in Data("s3cret".utf8) }
        let pasteboard = try hostPasteboard(instance)
        try await pasteboard.changed.wait { !pasteboard.dataByItem.isEmpty }
        #expect(
            pasteboard.dataByItem == [
                [
                    Self.textType: Data("s3cret".utf8),
                    NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI): Data(),
                ]
            ])
        await probe.settle()
        #expect(!released(Self.copyToken, probe))
        return pasteboard
    }

    @Test(
        "Copy to Mac's concealed text goes, unannounced, when the guest's clipboard moves on from it, pasted or not",
        arguments: [false, true])
    func concealedCopyToMacGoesWhenTheGuestsClipboardMovesOn(pasted: Bool) async throws {
        let probe = AgentHubProbe()
        // Gated, so no readout or dwell changes the report on its own.
        let instance = try await connected(probe, transferClock: GatedEngineClock())
        let pasteboard = try await concealedCopyToMac(probe, instance)
        if pasted { #expect(pasteboard.items.first?.data(forType: Self.textType) == Data("s3cret".utf8)) }
        let before = instance.clipboardTransferReport

        withdrawGuestCopy(on: probe, .clipboardChanged)
        try await pasteboard.changed.wait { pasteboard.dataByItem.isEmpty }
        // The retraction and the report it would make run in one turn: none came.
        #expect(instance.clipboardTransferReport == before)
    }

    @Test("Copy to Mac's concealed text the guest withdraws, what its files came from having ended, is said withdrawn")
    func concealedCopyToMacWithdrawnIsSaid() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let pasteboard = try await concealedCopyToMac(probe, instance)

        withdrawGuestCopy(on: probe)
        try await pasteboard.changed.wait { pasteboard.dataByItem.isEmpty }
        #expect(try await reported(instance, .copy) == .withdrawnCopyRetracted)
    }

    @Test("Copy to Mac of a guest copy that left out files the guest cannot read writes the rest, and says so")
    func copyToMacReportsUnreadableFilesLeftOut() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(Self.text, on: probe, into: instance, leftOut: 2)
        try await probe.changed.wait { pulls(probe).count == 1 }
        let (requestID, order) = pulls(probe)[0]
        try land(Data("the guest's".utf8), for: order, request: requestID, stream: 3, on: probe)

        #expect(try await reported(instance, .copy) == .itemsSkipped(count: 2))
        #expect(
            try hostPasteboard(instance).dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("the guest's".utf8))
    }

    @Test("Copy to Mac of a guest clipboard whose every file the guest cannot read writes nothing and says so")
    func copyToMacOfUnreadableFiles() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try await copyToMac(on: probe, into: instance, declining: .readFailed)
        #expect(try await reported(instance, .copy) == .itemsUnreadable)
        #expect(try hostPasteboard(instance).prepareCount == 0)
    }

    @Test("A guest offer passthrough's write the Mac's pasteboard refuses says the copy failed")
    func passthroughRefusedWriteIsReported() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        try hostPasteboard(instance).failNextWrite()
        try await receive(Self.text, on: probe, into: instance)
        #expect(try await reported(instance, .copy) == .transferFailed)
        #expect(!instance.hostClipboardPublisher.pasteboardHoldsLastWrite)
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
        // The guest hears its clipboard's offer end as passthrough stopping, and retracts what no paste had of it.
        #expect(withdrawal(of: hostOffer.token, probe) == .disabledByPolicy)
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

    /// Records what each retraction of the Mac's write that `instance`'s service asks for left.
    private func recordingRetractions(_ instance: VMInstance) -> RetractionLog {
        let log = RetractionLog()
        let retract = instance.hubClipboard.retractHostWrite
        instance.hubClipboard.retractHostWrite = { token, withdrawal in
            let outcome = retract(token, withdrawal)
            log.outcomes.append(outcome)
            return outcome
        }
        return log
    }

    /// Has the Mac paste `type` of item `item` of the guest's offer, the guest landing `content` as pull `stream`.
    private func paste(
        _ type: NSPasteboard.PasteboardType, item: Int, landing content: Data, stream: UInt32,
        _ instance: VMInstance, _ probe: AgentHubProbe
    ) async throws -> Data? {
        let pasteboard = try hostPasteboard(instance)
        let before = pulls(probe).count
        let paste = Task.detached { pasteboard.invokeProvider(forType: type, itemIndex: item) }
        try await probe.changed.wait { pulls(probe).count == before + 1 }
        let (request, order) = pulls(probe)[before]
        try land(content, for: order, request: request, stream: stream, on: probe)
        return await paste.value
    }

    /// Has passthrough write the guest's offer of `items` to the Mac, `concealed` or not.
    private func passthroughWrites(
        _ items: OfferedItem..., concealed: Bool = false, into instance: VMInstance, on probe: AgentHubProbe
    ) async throws {
        let shown = instance.hubClipboard.inboundOfferSeq
        let readsBefore = reads(probe).count
        deliverOffer(on: probe, token: Self.guestToken, concealed: concealed, count: items.count)
        try await probe.changed.wait { reads(probe).count == readsBefore + items.count }
        for (id, item) in reads(probe).dropFirst(readsBefore) {
            probe.deliver(.itemReply(id, .read(items[Int(item)])), fromConnection: 0)
        }
        try await waitForChange { instance.hubClipboard.inboundOfferSeq == shown + 1 }
        try await hostPasteboard(instance).changed.wait { instance.hostClipboardPublisher.pasteboardHoldsLastWrite }
    }

    @Test(
        "Turning passthrough off takes back the guest's file item whose file no paste had, its pasted name too; the rest stays"
    )
    func passthroughOffTakesBackAnUnpastedFilesItem() async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        _ = try startPassthrough(instance)
        let retractions = recordingRetractions(instance)
        let pasteboard = try hostPasteboard(instance)
        try await passthroughWrites(Self.text, Self.textAndFile, into: instance, on: probe)
        #expect(
            try await paste(Self.textType, item: 0, landing: Data("text".utf8), stream: 3, instance, probe)
                == Data("text".utf8))
        #expect(
            try await paste(Self.textType, item: 1, landing: Data("a.bin".utf8), stream: 5, instance, probe)
                == Data("a.bin".utf8))

        await stopPassthrough(instance, probe)
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pasteboard.dataByItem == [[Self.textType: Data("text".utf8)]])
        #expect(retractions.outcomes == [.keptPart])
        // Passthrough made the write: nothing is reported.
        #expect(instance.clipboardTransferReport == .idle)
    }

    /// How the guest's passthrough offer stops being the Mac's clipboard while what a paste had of it stays.
    enum GuestOfferEnd: CaseIterable, Sendable {
        /// Passthrough is turned off on the Mac.
        case passthroughStops
        /// The guest leaves the console, and the hub's connection with it.
        case guestLeavesTheConsole
        /// The guest resets its offer `CAPABILITY_WITHDRAWN`, CLIPBOARD having stopped being usable there.
        case guestFeatureGoes
    }

    /// Ends the guest's passthrough offer as `end` says.
    private func end(
        _ end: GuestOfferEnd, _ instance: VMInstance, _ probe: AgentHubProbe
    ) async throws {
        switch end {
        case .passthroughStops:
            await stopPassthrough(instance, probe)
        case .guestLeavesTheConsole:
            probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
            try await waitForChange { !instance.hubClipboard.isConnected && instance.clipboardRoute == .none }
            await probe.settle()
        case .guestFeatureGoes:
            let pasteboard = try hostPasteboard(instance)
            let standing = pasteboard.changeCount
            probe.deliver(
                .items(
                    .offerEnded(
                        .clipboard, .remote, token: Self.guestToken, .resetByPeer(WireError(.capabilityWithdrawn)))),
                fromConnection: 0)
            // The retraction rewrites the Mac's pasteboard.
            try await pasteboard.changed.wait { pasteboard.changeCount != standing }
            await probe.settle()
        }
    }

    @Test(
        "A concealed guest copy pasted on the Mac goes from it when passthrough stops, the connection ends, or the guest's CLIPBOARD goes",
        arguments: GuestOfferEnd.allCases)
    func pastedConcealedCopyGoes(end ending: GuestOfferEnd) async throws {
        let probe = AgentHubProbe()
        let instance = try await connected(probe)
        let coordinator = try startPassthrough(instance)
        defer { coordinator.stop() }
        let retractions = recordingRetractions(instance)
        let pasteboard = try hostPasteboard(instance)
        try await passthroughWrites(Self.text, concealed: true, into: instance, on: probe)
        #expect(
            try await paste(Self.textType, item: 0, landing: Data("hunter2".utf8), stream: 3, instance, probe)
                == Data("hunter2".utf8))

        try await end(ending, instance, probe)
        #expect(pasteboard.items.isEmpty)
        #expect(retractions.outcomes == [.cleared])
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
        try await waitForChange { !instance.hubClipboard.isConnected && instance.clipboardRoute == .none }
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected && instance.clipboardRoute != .none }
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

    // MARK: - Lower findings

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

    // MARK: - A pasted file and its staging

    /// Has passthrough write the guest's offer of a text item and a file item to the Mac, a paste on the Mac take
    /// every type of both, and the connection end: what was pasted stays, as data. Returns the staged file the
    /// second item's `public.file-url` names, and the passthrough to stop.
    private func keepPastedFile(
        _ instance: VMInstance, _ probe: AgentHubProbe
    ) async throws -> (file: URL, passthrough: ClipboardPassthroughCoordinator) {
        let coordinator = try startPassthrough(instance)
        let pasteboard = try hostPasteboard(instance)
        try await passthroughWrites(Self.text, Self.textAndFile, into: instance, on: probe)
        #expect(
            try await paste(Self.textType, item: 0, landing: Data("text".utf8), stream: 3, instance, probe) != nil)
        #expect(
            try await paste(Self.textType, item: 1, landing: Data("a.bin".utf8), stream: 5, instance, probe) != nil)
        let served = try #require(
            try await paste(.fileURL, item: 1, landing: Data("the guest's file".utf8), stream: 7, instance, probe))
        let file = try #require(URL(string: String(decoding: served, as: UTF8.self)))

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected && instance.clipboardRoute == .none }
        await probe.settle()
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pasteboard.dataByItem.last?[.fileURL] == served)
        #expect(try Data(contentsOf: file) == Data("the guest's file".utf8))
        return (file, coordinator)
    }

    private func refusals(of token: Data, _ probe: AgentHubProbe) -> Int {
        probe.commands.filter { if case .items(.refuse(token, _)) = $0 { true } else { false } }.count
    }

    @Test(
        "A guest file pasted on the Mac goes whole, its name too, once later copies evict its staging; the rest stays")
    func keptFileGoesWithItsStaging() async throws {
        let staging = TestStagingRoot(retirement: ClipboardStagingRetirement())
        let probe = AgentHubProbe()
        let instance = try await connected(probe, stagingRoot: staging.root)
        let (file, passthrough) = try await keepPastedFile(instance, probe)
        defer { passthrough.stop() }
        let pasteboard = try hostPasteboard(instance)

        // Three Copy Guest Clipboard to Mac whose text never lands each take a generation of staging, unwritten;
        // the third evicts the pasted file's.
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected && instance.clipboardRoute != .none }
        for attempt in 0..<3 {
            let before = pulls(probe).count
            _ = try await copyToMac(Self.text, on: probe, into: instance)
            try await probe.changed.wait { pulls(probe).count == before + 1 }
            let pull = open(pulls(probe)[before].id, stream: UInt32(101 + 2 * attempt), on: probe)
            probe.deliver(
                .items(.pullEnded(.clipboard, pull, .failed(WireError(.readFailed)))), fromConnection: 0)
            try await probe.changed.wait { refusals(of: Self.copyToken, probe) == attempt + 1 }
        }

        try await pasteboard.changed.wait { pasteboard.dataByItem.count == 1 }
        #expect(pasteboard.dataByItem == [[Self.textType: Data("text".utf8)]])
        try await staging.removals.wait { !FileManager.default.fileExists(atPath: file.path) }
    }
}

/// What each retraction a test watched left.
@MainActor
private final class RetractionLog {
    var outcomes: [ClipboardRetraction?] = []
}
