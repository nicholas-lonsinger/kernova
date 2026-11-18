import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaCommandModel
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaKit

/// A VM's clipboard over the guest agent's CLIPBOARD items, driven through its agent hub with a probe standing in
/// for the guest's connection and a host pasteboard the test alone polls: what the hub is asked to send, what the
/// host makes of what the guest sends, and what the VM's transfer report says of it.
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

    /// A running macOS VM sharing its clipboard, passthrough on or off as `passthrough` says, whose Mac clipboard
    /// holds `macText` from before the connection, and whose hub's one connection is a session peer on the console
    /// carrying CLIPBOARD. The VM owns the clipboard service the hub delivers to, so a test holds it to its end.
    private func connected(
        _ probe: AgentHubProbe, passthrough: Bool, macText: String? = nil
    ) async throws -> (instance: VMInstance, pasteboard: FakePasteboard) {
        let pasteboard = FakePasteboard(pollsOnlyWhenTold: true)
        if let macText { #expect(pasteboard.setString(macText, forType: .string)) }
        let instance = VMInstanceFixture.make(
            guestOS: .macOS, phase: .running(sessionID: UUID()), agentConnector: probe, hostPasteboard: pasteboard
        ) {
            $0.clipboardSharingEnabled = true
            $0.clipboardPassthroughEnabled = passthrough
        }
        instance.beginSessionContextForTesting()
        instance.attachAgentTransport(probe)
        try await probe.changed.wait { probe.isStarted }
        #expect(probe.connect())
        probe.deliver(.helloReceived(Self.claim, Self.onConsole), fromConnection: 0)
        probe.deliver(.featuresChanged(Self.clipboard), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }
        return (instance, pasteboard)
    }

    /// Turns passthrough on or off the way a settings write does, once the hub sent what that asks of it.
    private func setPassthrough(_ on: Bool, _ instance: VMInstance, _ probe: AgentHubProbe) async {
        var changed = instance.configuration
        changed.clipboardPassthroughEnabled = on
        instance.applyLivePolicy(oldConfig: instance.configuration, newConfig: changed)
        await probe.settle()
    }

    /// A tick of the host pasteboard's watch.
    private func poll(_ pasteboard: FakePasteboard) {
        ClipboardPasteboardWatch.pollForTesting(pasteboard)
    }

    /// Every clipboard offer the hub sent the connection, in order.
    private func offers(_ probe: AgentHubProbe) -> [(id: ItemRequestID, offer: ItemOffer)] {
        probe.commands.compactMap {
            if case .items(.offer(let id, let offer, .clipboard)) = $0 { (id, offer) } else { nil }
        }
    }

    /// Every request for the guest's clipboard the hub sent the connection, in order.
    private func requests(_ probe: AgentHubProbe) -> [(id: ItemRequestID, token: Data)] {
        probe.commands.compactMap {
            if case .items(.requestClipboardOffer(let id, let token)) = $0 { (id, token) } else { nil }
        }
    }

    /// Has the connection open the last clipboard offer the hub sent, returning it once the exchange heard it
    /// opened.
    @discardableResult
    private func acceptLastOffer(_ probe: AgentHubProbe) async throws -> ItemOffer {
        let (id, offer) = try #require(offers(probe).last)
        probe.deliver(.itemReply(id, .offered(nil)), fromConnection: 0)
        try await probe.settle()
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

    /// Has the guest offer `items` under `token`, answering the request `request`, answering the hub's reads of them.
    private func receive(
        _ items: OfferedItem..., on probe: AgentHubProbe, token: Data = guestToken, request: Data = Data(),
        concealed: Bool = false
    ) async throws {
        let readsBefore = reads(probe).count
        deliverOffer(on: probe, token: token, request: request, concealed: concealed, count: items.count)
        try await probe.changed.wait { reads(probe).count == readsBefore + items.count }
        for (id, item) in reads(probe).dropFirst(readsBefore) {
            probe.deliver(.itemReply(id, .read(items[Int(item)])), fromConnection: 0)
        }
    }

    /// Has the guest offer `items` as ``receive(_:on:token:request:concealed:)`` does, and waits for the
    /// host to write them to the Mac.
    private func written(
        _ items: OfferedItem..., concealed: Bool = false, request: Data = Data(), to pasteboard: FakePasteboard,
        on probe: AgentHubProbe
    ) async throws {
        let before = pasteboard.changeCount
        let readsBefore = reads(probe).count
        deliverOffer(on: probe, token: Self.guestToken, request: request, concealed: concealed, count: items.count)
        try await probe.changed.wait { reads(probe).count == readsBefore + items.count }
        for (id, item) in reads(probe).dropFirst(readsBefore) {
            probe.deliver(.itemReply(id, .read(items[Int(item)])), fromConnection: 0)
        }
        try await pasteboard.changed.wait { pasteboard.changeCount != before && !pasteboard.promisedTypes.isEmpty }
    }

    private func deliverOffer(
        on probe: AgentHubProbe, token: Data, request: Data = Data(), concealed: Bool = false, count: Int = 1
    ) {
        let header = ItemSetHeaderValue(
            feature: .clipboard, token: token, concealed: concealed, count: count, request: request)
        probe.deliver(.items(.offerReceived(header)), fromConnection: 0)
    }

    private static let text = item(representation(NSPasteboard.PasteboardType.string.rawValue, .inline))
    private static let textAndFile = item(
        representation(NSPasteboard.PasteboardType.string.rawValue, .inline),
        representation("public.data", .file, name: "a.bin"))
    private static let textType = NSPasteboard.PasteboardType.string

    /// A guest file over the default paste ceiling.
    private static var oversizeFile: Representation {
        var file = representation("public.data", .file, name: "big.bin")
        file.sizeEstimate = 3 << 30
        return file
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

    private func refusals(of token: Data, _ probe: AgentHubProbe) -> [WireError] {
        probe.commands.compactMap { if case .items(.refuse(token, let error)) = $0 { error } else { nil } }
    }

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

    // MARK: - Host → guest

    /// Has passthrough offer a copy of `text` on the Mac, returning the offer the console peer was sent.
    private func forwardMacCopy(
        _ text: String, _ pasteboard: FakePasteboard, _ probe: AgentHubProbe
    ) async throws -> ItemOffer {
        let before = offers(probe).count
        #expect(pasteboard.setString(text, forType: .string))
        poll(pasteboard)
        try await probe.changed.wait { offers(probe).count == before + 1 }
        return try await acceptLastOffer(probe)
    }

    /// The guest's pull of representation `index` of `offer`'s first item, as the hub's source asks the end for it.
    private func pull(_ offer: ItemOffer, representation index: Int = 0, from instance: VMInstance) async
        -> Result<ItemContent, WireError>
    {
        var request = PullRequest()
        request.token = offer.token
        request.representation = UInt32(index)
        let end = instance.hubClipboard.end
        let pull = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2))
        return await Task.detached { end.content(pull, request) }.value
    }

    // MARK: - One current clipboard

    @Test("A paste of the guest's concealed text lands it in memory, creating nothing under the staging root")
    func concealedPasteStagesNothing() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try await written(Self.text, concealed: true, to: pasteboard, on: probe)

        let password = Data("hunter2".utf8)
        let paste = BlockingCall {
            pasteboard.invokeProvider(forType: NSPasteboard.PasteboardType.string)
        }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        let (requestID, order) = try #require(pulls(probe).first)
        #expect(order.landing == .memory)
        try land(password, for: order, request: requestID, stream: 3, on: probe)

        #expect(try await paste.returned() == password)
        let exchangeStaging = ClipboardFileStaging.processRoot.url
            .appendingPathComponent("host-\(instance.configuration.id.uuidString)")
        #expect(!FileManager.default.fileExists(atPath: exchangeStaging.path))
    }

    @Test(
        "A guest offer arriving while the host's is open crossed it and is refused unread; once the guest released the host's, its next is taken"
    )
    func crossingOfferLoses() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        let hostOffer = try await forwardMacCopy("copied on the Mac", pasteboard, probe)

        let crossing = Data(repeating: 3, count: 16)
        deliverOffer(on: probe, token: crossing)
        try await probe.changed.wait { released(crossing, probe) }
        #expect(reads(probe).isEmpty)
        #expect(!withdrawn(hostOffer.token, probe))

        // The guest's connection releases the host's offer before it opens its next.
        probe.deliver(
            .items(.offerEnded(.clipboard, .local, token: hostOffer.token, .completed(remoteEndBody: Data()))),
            fromConnection: 0)
        try await written(Self.text, to: pasteboard, on: probe)
        withExtendedLifetime(instance) {}
    }

    @Test("A guest offer crossing a Mac copy passthrough has not sent yet loses, and the Mac copy goes at once")
    func crossingUnsentMacCopyLoses() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        #expect(pasteboard.setString("copied on the Mac", forType: .string))

        let crossing = Data(repeating: 3, count: 16)
        deliverOffer(on: probe, token: crossing)
        try await probe.changed.wait { released(crossing, probe) && !offers(probe).isEmpty }
        #expect(reads(probe).isEmpty)
        let offered = try await acceptLastOffer(probe)
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied on the Mac".utf8))))
    }

    @Test(
        "A lost connection retracts the guest's copy from the Mac; its return sends nothing, and the next copy crosses")
    func linkLossRetractsThenSendsNothing() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try await written(Self.text, to: pasteboard, on: probe)

        probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
        try await waitForChange { !instance.hubClipboard.isConnected }
        await probe.settle()
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(offers(probe).isEmpty)
        // A retraction is never reported.
        #expect(instance.clipboardTransferReport == .idle)

        #expect(pasteboard.setString("copied during the outage", forType: .string))
        probe.deliver(.peerStateChanged(Self.onConsole), fromConnection: 0)
        try await waitForChange { instance.hubClipboard.isConnected }
        poll(pasteboard)
        await probe.settle()
        #expect(offers(probe).isEmpty)

        let offered = try await forwardMacCopy("copied after the return", pasteboard, probe)
        #expect(await pull(offered, from: instance) == .success(.inline(Data("copied after the return".utf8))))
    }

    @Test("A Mac copy that offers nothing withdraws the host's offer")
    func emptyMacCopyWithdraws() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        let offered = try await forwardMacCopy("copied on the Mac", pasteboard, probe)

        #expect(
            pasteboard.setItem([
                (.string, Data("a password".utf8)),
                (NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI), Data()),
            ]))
        poll(pasteboard)
        try await probe.changed.wait { withdrawn(offered.token, probe) }
        #expect(offers(probe).count == 1)
        withExtendedLifetime(instance) {}
    }

    // MARK: - Guest → host

    @Test("A guest pull that opens and never ends is cancelled when the guest's offer ends, and the paste gets nothing")
    func stalledPullEndsWithItsOffer() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try await written(
            Self.item(Self.representation("public.data", .file, name: "notes.bin")), to: pasteboard, on: probe)
        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        try await probe.changed.wait { !pulls(probe).isEmpty }
        let pull = open(pulls(probe)[0].id, stream: 3, on: probe)

        // The guest sends nothing more, and then its clipboard moves on.
        endGuestOffer(on: probe)

        #expect(try await paste.returned() == nil)
        try await probe.changed.wait { cancels(probe) == [pull] }
        withExtendedLifetime(instance) {}
    }

    @Test("A guest offer passthrough's write the Mac's pasteboard refuses says the copy failed")
    func passthroughRefusedWriteIsReported() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        pasteboard.failNextWrite()
        try await receive(Self.text, on: probe)
        #expect(try await reported(instance, .copy) == .transferFailed)
        #expect(pasteboard.promisedTypes.isEmpty)
    }

    // MARK: - The clipboard commands

    @Test("Copy to Guest offers the Mac's clipboard live: pulled when pasted, and withdrawn by the Mac's next copy")
    func copyToGuestOffersLive() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: false)
        #expect(pasteboard.setString("from the Mac", forType: .string))
        instance.copyMacClipboardToGuest()
        try await probe.changed.wait { offers(probe).count == 1 }
        let offered = try await acceptLastOffer(probe)
        #expect(await pull(offered, from: instance) == .success(.inline(Data("from the Mac".utf8))))

        // Passthrough is off: the next copy offers nothing, and withdraws the one the command made.
        #expect(pasteboard.setString("copied since", forType: .string))
        poll(pasteboard)
        try await probe.changed.wait { withdrawn(offered.token, probe) }
        #expect(offers(probe).count == 1)
    }

    @Test("Copy to Guest of a Mac clipboard whose every file is gone sends nothing and says so")
    func copyToGuestOfUnreadableFiles() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: false)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let doomed = scratch.url.appendingPathComponent("doomed.bin")
        try Data("doomed".utf8).write(to: doomed)
        #expect(pasteboard.setFiles([doomed]))
        try FileManager.default.removeItem(at: doomed)

        instance.copyMacClipboardToGuest()
        #expect(try await reported(instance, .forward) == .itemsUnreadable)
        #expect(offers(probe).isEmpty)
    }

    /// Runs Copy Guest Clipboard to Mac until the guest has its request, returning the request's token.
    private func askForGuestClipboard(_ instance: VMInstance, _ probe: AgentHubProbe) async throws -> Data {
        let before = requests(probe).count
        instance.copyGuestClipboardToMac()
        try await probe.changed.wait { requests(probe).count == before + 1 }
        let (id, token) = try #require(requests(probe).last)
        probe.deliver(.itemReply(id, .offered(nil)), fromConnection: 0)
        await probe.settle()
        return token
    }

    @Test("Copy to Mac writes the guest's clipboard promised, pulling nothing until a paste")
    func copyToMacWritesPromised() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: false)
        let request = try await askForGuestClipboard(instance, probe)

        try await written(Self.text, request: request, to: pasteboard, on: probe)
        #expect(pasteboard.promisedTypes == [Self.textType])
        #expect(pulls(probe).isEmpty)
    }

    @Test(
        "Copy to Mac says what the guest's refusal of its request says",
        arguments: [
            (ErrorCode.clipboardNothingToCopy, ClipboardTransferFailure.nothingToCopy),
            (.readFailed, .itemsUnreadable),
        ])
    func copyToMacRefusalIsReported(code: ErrorCode, failure: ClipboardTransferFailure) async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: false)
        let request = try await askForGuestClipboard(instance, probe)
        probe.deliver(
            .items(.requestEnded(.local, token: request, .resetByPeer(WireError(code)))), fromConnection: 0)
        #expect(try await reported(instance, .copy) == failure)
        #expect(pasteboard.prepareCount == 0)
    }

    // MARK: - The paste ceiling

    @Test(
        "Passthrough of the guest's text and a file over the paste ceiling writes the text and says the file was left out"
    )
    func passthroughLeavesOutAnOversizeFile() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try await receive(
            Self.item(Self.representation(NSPasteboard.PasteboardType.string.rawValue, .inline), Self.oversizeFile),
            on: probe)

        #expect(
            try await reported(instance, .copy)
                == .filesLeftOut(count: 1, limitBytes: instance.effectiveClipboardMaxPasteBytes))
        #expect(pasteboard.promisedTypes == [.string])
    }

    @Test("Passthrough of a guest file over the paste ceiling, and nothing else, leaves the Mac's clipboard as it was")
    func passthroughRefusesAnOversizeFileAlone() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true, macText: "the Mac's")
        try await receive(Self.item(Self.oversizeFile), on: probe)

        #expect(
            try await reported(instance, .copy) == .tooLarge(limitBytes: instance.effectiveClipboardMaxPasteBytes))
        #expect(pasteboard.items.first?.data(forType: .string) == Data("the Mac's".utf8))
        #expect(pasteboard.promisedTypes.isEmpty)
    }

    // MARK: - The clipboard setting

    @Test("Turning passthrough off withdraws the host's offer as the setting changing, and it serves nothing more")
    func passthroughOffWithdrawsTheHostsOffer() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("A.bin")
        try Data("file A".utf8).write(to: file)
        #expect(pasteboard.setFiles([file]))
        poll(pasteboard)
        try await probe.changed.wait { offers(probe).count == 1 }
        let hostOffer = try await acceptLastOffer(probe)

        await setPassthrough(false, instance, probe)
        // The guest hears its clipboard's offer end as the setting changing, and retracts what no paste had of it.
        #expect(withdrawal(of: hostOffer.token, probe) == .disabledByPolicy)
        guard case .failure = try await pull(hostOffer, from: instance) else {
            Issue.record("the withdrawn offer still served A")
            return
        }
    }

    /// Has the Mac paste `type` of item `item` of the guest's offer, the guest landing `content` as pull `stream`.
    private func paste(
        _ type: NSPasteboard.PasteboardType, item: Int, landing content: Data, stream: UInt32,
        _ pasteboard: FakePasteboard, _ probe: AgentHubProbe
    ) async throws -> Data? {
        let before = pulls(probe).count
        let paste = BlockingCall { pasteboard.invokeProvider(forType: type, itemIndex: item) }
        try await probe.changed.wait { pulls(probe).count == before + 1 }
        let (request, order) = pulls(probe)[before]
        try land(content, for: order, request: request, stream: stream, on: probe)
        return try await paste.returned()
    }

    @Test(
        "Turning passthrough off lets the guest's offer go and takes back its file item no paste had, its pasted name too; the rest stays"
    )
    func passthroughOffTakesBackAnUnpastedFilesItem() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try await written(Self.text, Self.textAndFile, to: pasteboard, on: probe)
        #expect(
            try await paste(Self.textType, item: 0, landing: Data("text".utf8), stream: 3, pasteboard, probe)
                == Data("text".utf8))
        #expect(
            try await paste(Self.textType, item: 1, landing: Data("a.bin".utf8), stream: 5, pasteboard, probe)
                == Data("a.bin".utf8))

        await setPassthrough(false, instance, probe)
        #expect(released(Self.guestToken, probe))
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pasteboard.dataByItem == [[Self.textType: Data("text".utf8)]])
        // A retraction is never reported.
        #expect(instance.clipboardTransferReport == .idle)
    }

    /// How the guest's offer stops being the Mac's clipboard while what a paste had of it stays.
    enum GuestOfferEnd: CaseIterable, Sendable {
        /// Passthrough is turned off on the Mac.
        case passthroughStops
        /// The guest leaves the console, and the hub's connection with it.
        case guestLeavesTheConsole
        /// The guest resets its offer `CAPABILITY_WITHDRAWN`, CLIPBOARD having stopped being usable there.
        case guestFeatureGoes
    }

    /// Ends the guest's offer as `end` says.
    private func end(
        _ end: GuestOfferEnd, _ instance: VMInstance, _ pasteboard: FakePasteboard, _ probe: AgentHubProbe
    ) async throws {
        switch end {
        case .passthroughStops:
            await setPassthrough(false, instance, probe)
        case .guestLeavesTheConsole:
            probe.deliver(.peerStateChanged(Self.offConsole), fromConnection: 0)
            try await waitForChange { !instance.hubClipboard.isConnected }
            try await probe.settle()
        case .guestFeatureGoes:
            let standing = pasteboard.changeCount
            probe.deliver(
                .items(
                    .offerEnded(
                        .clipboard, .remote, token: Self.guestToken, .resetByPeer(WireError(.capabilityWithdrawn)))),
                fromConnection: 0)
            // The retraction rewrites the Mac's pasteboard.
            try await pasteboard.changed.wait { pasteboard.changeCount != standing }
            try await probe.settle()
        }
    }

    @Test(
        "A concealed guest copy pasted on the Mac goes from it when passthrough stops, the connection ends, or the guest's CLIPBOARD goes",
        arguments: GuestOfferEnd.allCases)
    func pastedConcealedCopyGoes(end ending: GuestOfferEnd) async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try await written(Self.text, concealed: true, to: pasteboard, on: probe)
        #expect(
            try await paste(Self.textType, item: 0, landing: Data("hunter2".utf8), stream: 3, pasteboard, probe)
                == Data("hunter2".utf8))

        try await end(ending, instance, pasteboard, probe)
        #expect(pasteboard.items.isEmpty)
    }

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
        let (instance, pasteboard) = try await connected(probe, passthrough: false)
        // A guest offer crossing passthrough's being off is refused unread: the guest's own agent offers nothing.
        deliverOffer(on: probe, token: Self.guestToken)
        try await probe.changed.wait { refusals(of: Self.guestToken, probe) == [WireError(.disabledByPolicy)] }
        #expect(reads(probe).isEmpty)
        #expect(pasteboard.setString("the Mac's newer copy", forType: .string))
        let macHolds = pasteboard.changeCount
        try await bounceLink(instance, probe)

        await setPassthrough(true, instance, probe)
        poll(pasteboard)
        await probe.settle()
        #expect(offers(probe).isEmpty)
        #expect(pasteboard.changeCount == macHolds)
        #expect(pasteboard.items.first?.data(forType: .string) == Data("the Mac's newer copy".utf8))
    }

    // MARK: - Lower findings

    @Test("A host offer the connection refused to open crosses nothing: the guest offer arriving next is taken")
    func refusedHostOfferIsNotTheLatest() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        #expect(pasteboard.setString("from the Mac", forType: .string))
        poll(pasteboard)
        try await probe.changed.wait { !offers(probe).isEmpty }
        probe.deliver(.itemReply(offers(probe)[0].id, .offered(WireError(.internal))), fromConnection: 0)
        await probe.settle()

        try await written(Self.text, to: pasteboard, on: probe)
        withExtendedLifetime(instance) {}
    }

    @Test("A concealed guest offer's in-memory pulls land against the offer's one budget")
    func memoryPullsShareTheBudget() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try await written(
            Self.item(
                Self.representation(NSPasteboard.PasteboardType.string.rawValue, .inline),
                Self.representation("public.rtf", .inline)),
            concealed: true, to: pasteboard, on: probe)

        let first = BlockingCall {
            pasteboard.invokeProvider(forType: NSPasteboard.PasteboardType.string)
        }
        let second = BlockingCall { pasteboard.invokeProvider(forType: .rtf) }
        try await probe.changed.wait { pulls(probe).count == 2 }
        let orders = pulls(probe).map(\.order)
        #expect(orders.allSatisfy { $0.landing == .memory })
        let budget = try #require(orders[0].budget)
        #expect(orders[1].budget === budget)
        #expect(budget.limit == UInt64(instance.effectiveClipboardMaxPasteBytes))

        endGuestOffer(on: probe)
        #expect(try await first.returned() == nil)
        #expect(try await second.returned() == nil)
    }

    // MARK: - Crossings and answers

    @Test("Copy to Mac takes the guest's answer after a Copy to Guest the guest's item registry reset over budget")
    func copyToMacAfterAnOverBudgetCopyToGuest() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: false)
        #expect(pasteboard.setString("from the Mac", forType: .string))
        instance.copyMacClipboardToGuest()
        try await probe.changed.wait { offers(probe).count == 1 }
        let hostOffer = try await acceptLastOffer(probe)
        // The guest's item registry resets an offer over its budget before the guest's end hears of it.
        probe.deliver(
            .items(.offerEnded(.clipboard, .local, token: hostOffer.token, .resetByPeer(WireError(.tooLarge)))),
            fromConnection: 0)
        await probe.settle()

        let request = try await askForGuestClipboard(instance, probe)
        try await written(Self.text, request: request, to: pasteboard, on: probe)
    }

    @Test("Copy to Mac takes the guest's answer that arrives whole after the guest released the request")
    func copyToMacTakesAnAnswerArrivingAfterTheRelease() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: false)
        let request = try await askForGuestClipboard(instance, probe)
        // The guest releases the request once its answer opened; the answer's items may still be crossing.
        probe.deliver(
            .items(.requestEnded(.local, token: request, .completed(remoteEndBody: Data()))), fromConnection: 0)
        await probe.settle()
        #expect(instance.clipboardTransferReport == .idle)

        try await written(Self.text, request: request, to: pasteboard, on: probe)
        #expect(instance.clipboardTransferReport == .idle)
    }

    @Test("A Mac clipboard holding nothing to copy is said of Copy to Guest, never of a copy passthrough reads")
    func nothingToCopyIsSaidOnlyOfTheCommand() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        let transient = NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.transientMarkerUTI)
        #expect(pasteboard.setItem([(.string, Data("a password".utf8)), (transient, Data())]))
        poll(pasteboard)
        try await pasteboard.changed.wait { pasteboard.readsReachedLanding == 1 }
        #expect(instance.clipboardTransferReport == .idle)

        await setPassthrough(false, instance, probe)
        instance.copyMacClipboardToGuest()
        #expect(try await reported(instance, .forward) == .nothingToCopy)
        #expect(offers(probe).isEmpty)
    }

    @Test("The guest's clipboard moving on takes its write back from the Mac, and says nothing")
    func guestMovingOnRetractsSilently() async throws {
        let probe = AgentHubProbe()
        let (instance, pasteboard) = try await connected(probe, passthrough: true)
        try await written(Self.text, to: pasteboard, on: probe)

        endGuestOffer(on: probe)
        try await pasteboard.changed.wait { pasteboard.promisedTypes.isEmpty }
        #expect(instance.clipboardTransferReport == .idle)
    }
}
