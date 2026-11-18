import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaKit

/// The guest's clipboard over the session peer's CLIPBOARD items: when its copies are offered to the host, what
/// becomes of the host's offers, and what the menu shows of each — over a fake pasteboard only the test polls and a
/// link recording what it is asked to send.
@Suite("GuestClipboard", .caseScoped)
@MainActor
struct GuestClipboardTests {
    private let staging = TestStagingRoot()
    private let scratch = TestScratchDirectory(prefix: "guest-clipboard")

    private struct Rig {
        let pasteboard: FakePasteboard
        let clipboard: GuestClipboard
        /// Notified at each notice the clipboard raises.
        let noticed: AsyncGate
        private let raised: Locked<Int>

        init(pasteboard: FakePasteboard, clipboard: (@escaping @Sendable () -> Void) -> GuestClipboard) {
            let noticed = AsyncGate()
            let raised = Locked(0)
            self.pasteboard = pasteboard
            self.noticed = noticed
            self.raised = raised
            self.clipboard = clipboard {
                raised.withLock { $0 += 1 }
                noticed.notify()
            }
        }

        /// How many notices the clipboard raised.
        var notices: Int { raised.withLock { $0 } }
    }

    private func rig() -> Rig {
        let pasteboard = FakePasteboard(pollsOnlyWhenTold: true)
        let root = staging.root
        return Rig(pasteboard: pasteboard) {
            GuestClipboard(pasteboard: pasteboard, stagingRoot: root, onNotice: $0)
        }
    }

    /// The host's policy, passthrough `on` or off, its paste ceiling `maxPasteBytes` (0: the default).
    private static func policy(passthrough on: Bool, maxPasteBytes: Int = 0) -> PolicySnapshot {
        PolicySnapshot([
            ClipboardPolicyValue(maxPasteBytes: UInt64(maxPasteBytes), passthrough: on).policy(enabled: true)
        ])
    }

    /// Opens the gate on `link`: on the console, passthrough on, the connection usable.
    private func openGate(_ rig: Rig, _ link: RecordingLink) {
        rig.clipboard.setOnConsole(true)
        rig.clipboard.apply(Self.policy(passthrough: true))
        rig.clipboard.setLink(link)
    }

    /// A tick of the pasteboard's watch.
    private func poll(_ rig: Rig) {
        ClipboardPasteboardWatch.pollForTesting(rig.pasteboard)
    }

    /// Copies `text` in the guest and polls the pasteboard.
    private func copy(_ text: String, _ rig: Rig) {
        #expect(rig.pasteboard.setString(text, forType: .string))
        poll(rig)
    }

    /// The host asks for the guest's clipboard by a request of `token`.
    private func request(_ token: Data, _ rig: Rig, _ link: RecordingLink) {
        rig.clipboard.end.handle(.offerRequested(token: token), on: link)
    }

    /// The types each of `link`'s offers carries, in order.
    private func offeredUTIs(_ link: RecordingLink) -> [[String?]] {
        link.offers.map { $0.items.flatMap { $0.representations.map(\.type.appleUTI) } }
    }

    private static func token(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }
    private static let hostToken = token(9)

    private static func textItem() -> OfferedItem {
        var item = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: NSPasteboard.PasteboardType.string.rawValue)
        representation.storage = .inline
        item.representations = [representation]
        return item
    }

    /// A text item beside a file of `size` bytes.
    private static func textAndFileItem(fileSize size: UInt64) -> OfferedItem {
        var item = textItem()
        var file = Representation()
        file.type = TypeDescriptor(appleUTI: "public.data")
        file.storage = .file
        file.name = Data("a.bin".utf8)
        file.sizeEstimate = size
        item.representations.append(file)
        return item
    }

    /// Has the host offer `count` items on `link` as `token` and waits for the guest pasteboard to be written.
    private func receiveHostOffer(_ rig: Rig, _ link: RecordingLink, token: Data = hostToken, count: Int = 1)
        async throws
    {
        let before = rig.pasteboard.changeCount
        rig.clipboard.end.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: token, concealed: false, count: count)),
            on: link)
        try await rig.pasteboard.changed.wait { rig.pasteboard.changeCount != before }
    }

    private func guestFile() throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("a.bin")
        try Data("the guest's file".utf8).write(to: file)
        return file
    }

    // MARK: - Gating

    @Test(
        "Under passthrough each copy is offered; without it a copy offers nothing, and the host's request is answered with an offer naming it"
    )
    func gateFollowsPolicy() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        rig.clipboard.apply(Self.policy(passthrough: true))
        copy("passthrough on", rig)
        try await link.changed.wait { link.offers.count == 1 }
        #expect(offeredUTIs(link) == [[NSPasteboard.PasteboardType.string.rawValue]])

        // Turning passthrough off ends the offer as the setting changing, never as the clipboard moving on.
        rig.clipboard.apply(Self.policy(passthrough: false))
        let first = link.offers[0].token
        try await link.changed.wait { link.withdrawals == [first] }
        #expect(link.withdrawalCodes[first] == .disabledByPolicy)
        copy("passthrough off", rig)
        await drainMainQueue()
        #expect(link.offers.count == 1)

        let asked = Self.token(1)
        request(asked, rig, link)
        try await link.changed.wait { link.offers.count == 2 }
        #expect(link.offers[1].request == asked)
    }

    @Test(
        "Off the console the guest's offer is withdrawn as the feature going, and neither a copy nor the host's request offers anything"
    )
    func consoleOwnershipGatesOffering() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        copy("offered", rig)
        try await link.changed.wait { link.offers.count == 1 }
        let token = link.offers[0].token

        rig.clipboard.setOnConsole(false)
        try await link.changed.wait { link.withdrawals == [token] }
        #expect(link.withdrawalCodes[token] == .capabilityWithdrawn)
        copy("off the console", rig)
        await drainMainQueue()
        #expect(link.offers.count == 1)

        rig.clipboard.apply(Self.policy(passthrough: false))
        let asked = Self.token(1)
        request(asked, rig, link)
        try await link.changed.wait { !link.refusals.isEmpty }
        #expect(link.refusals.map(\.token) == [asked])
        #expect(link.refusals.map(\.code) == [.clipboardNothingToCopy])
        #expect(link.offers.count == 1)
    }

    @Test("The status reads disabled until a connection carries the clipboard, enabled while one does, disabled after")
    func statusFollowsTheConnection() {
        let rig = rig()
        #expect(rig.clipboard.activity == .disabled)
        rig.clipboard.setLink(RecordingLink())
        #expect(rig.clipboard.activity == .enabled)
        rig.clipboard.setLink(nil)
        #expect(rig.clipboard.activity == .disabled)
    }

    // MARK: - What a read of the guest's clipboard shows

    @Test(
        "A copy offered whole shows as shared; one that lost a file says how many items, and one of only lost files says nothing crossed"
    )
    func copyOutcomesAreShown() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        copy("copied in the guest", rig)
        try await link.changed.wait { link.offers.count == 1 }
        #expect(rig.clipboard.activity == .offeredToHost)
        #expect(rig.notices == 0)

        let readable = try guestFile()
        let missing = scratch.url.appendingPathComponent("missing.bin")
        #expect(rig.pasteboard.setFiles([readable, missing]))
        poll(rig)
        try await rig.noticed.wait { rig.notices == 1 }
        #expect(rig.clipboard.activity == .copyPartlyCarried(skipped: 1))
        #expect(link.offers.count == 2)

        #expect(rig.pasteboard.setFiles([missing]))
        poll(rig)
        try await rig.noticed.wait { rig.notices == 2 }
        #expect(rig.clipboard.activity == .copyCarriedNothing)
        #expect(link.offers.count == 2)
    }

    @Test("A copy of nothing a pasteboard carries says nothing in it crossed")
    func uncarriableCopyIsShown() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        // A Finder node, which names a file on this machine, is never offered.
        let node = NSPasteboard.PasteboardType("com.apple.finder.node")
        #expect(rig.pasteboard.setItem([(type: node, data: Data("node".utf8))]))
        poll(rig)
        try await rig.noticed.wait { rig.notices == 1 }
        #expect(rig.clipboard.activity == .copyCarriedNothing)
        #expect(link.offers.isEmpty)
    }

    @Test(
        "The host's request: an empty clipboard or the host's own write there shows nothing, unreadable files say nothing crossed, a copy shows shared"
    )
    func requestOutcomesAreShown() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)

        request(Self.token(1), rig, link)
        try await link.changed.wait { link.refusals.count == 1 }
        #expect(link.refusals.last?.code == .clipboardNothingToCopy)
        #expect(rig.clipboard.activity == .enabled)

        try await receiveHostOffer(rig, link)
        #expect(rig.clipboard.activity == .offeredFromHost)
        request(Self.token(2), rig, link)
        try await link.changed.wait { link.refusals.count == 2 }
        #expect(link.refusals.last?.code == .clipboardAlreadyHeld)
        #expect(rig.clipboard.activity == .offeredFromHost)
        #expect(rig.notices == 0)

        #expect(rig.pasteboard.setFiles([scratch.url.appendingPathComponent("missing.bin")]))
        request(Self.token(3), rig, link)
        try await link.changed.wait { link.refusals.count == 3 }
        #expect(link.refusals.last?.code == .readFailed)
        #expect(rig.clipboard.activity == .copyCarriedNothing)
        #expect(rig.notices == 1)

        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        request(Self.token(4), rig, link)
        try await link.changed.wait { link.offers.count == 1 }
        #expect(link.offers[0].request == Self.token(4))
        #expect(rig.clipboard.activity == .offeredToHost)
    }

    @Test("A pull of the guest's offer shows as sent to the host")
    func servedPullIsShown() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        copy("copied in the guest", rig)
        try await link.changed.wait { link.offers.count == 1 }

        var pull = PullRequest()
        pull.token = link.offers[0].token
        let request = pull
        let end = rig.clipboard.end
        let id = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2))
        let served = await offCooperativePool { end.content(id, request) }
        #expect(served == .success(.inline(Data("copied in the guest".utf8))))
        #expect(rig.clipboard.activity == .sentToHost)
    }

    // MARK: - The host's offers

    @Test(
        "Without passthrough, the host's offer is published promised, and released once a copy in the guest replaces it"
    )
    func hostOfferPublishedThenReleased() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)

        try await receiveHostOffer(rig, link)
        #expect(rig.pasteboard.promisedTypes == [NSPasteboard.PasteboardType.string])
        #expect(rig.clipboard.activity == .offeredFromHost)
        // A poll does not read the agent's own write as a copy.
        poll(rig)
        await drainMainQueue()
        #expect(link.releases.isEmpty)

        copy("copied in the guest", rig)
        try await link.changed.wait { link.releases == [Self.hostToken] }
        #expect(link.offers.isEmpty)
    }

    @Test("The host's policy sets each pull's byte ceiling, and a policy arriving later changes it for later offers")
    func policySetsThePullCeiling() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setLink(link)
        let first = ClipboardPasteLimit.choices[0]
        rig.clipboard.apply(Self.policy(passthrough: false, maxPasteBytes: first))
        try await receiveHostOffer(rig, link)
        let pasteboard = rig.pasteboard
        let type = NSPasteboard.PasteboardType.string

        // A paste holds its thread until the pull ends, so it fires off the main actor.
        _ = await offCooperativePool { pasteboard.invokeProvider(forType: type) }
        #expect(link.ceilings == [UInt64(first)])

        // An offer's pulls land against one budget, the ceiling as its first pull read it.
        let raised = 16 * 1024 * 1024 * 1024
        rig.clipboard.apply(Self.policy(passthrough: false, maxPasteBytes: raised))
        try await receiveHostOffer(rig, link, token: Self.token(8))
        _ = await offCooperativePool { pasteboard.invokeProvider(forType: type) }
        #expect(link.ceilings == [UInt64(first), UInt64(raised)])
    }

    @Test("A host offer cut by the paste ceiling is written again, its file with it, once the host's policy raises it")
    func raisedCeilingWritesTheCutOfferAgain() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textAndFileItem(fileSize: 1 << 30)])
        rig.clipboard.setLink(link)
        rig.clipboard.apply(Self.policy(passthrough: false, maxPasteBytes: ClipboardPasteLimit.choices[0]))
        try await receiveHostOffer(rig, link)
        #expect(rig.pasteboard.promisedTypes == [NSPasteboard.PasteboardType.string])

        rig.clipboard.apply(Self.policy(passthrough: false, maxPasteBytes: 16 * 1024 * 1024 * 1024))
        #expect(rig.pasteboard.promisedTypes.contains(.fileURL))
    }

    @Test("A paste of the host's file refused over the paste ceiling shows that refusal and the ceiling")
    func pullOverTheCeilingIsShown() async throws {
        let rig = rig()
        var file = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: "public.data")
        representation.storage = .file
        representation.name = Data("big.bin".utf8)
        file.representations = [representation]
        let link = RecordingLink(items: [file], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)
        // Published within the ceiling: the offer's estimate fits, and only the pull finds it does not.
        #expect(rig.clipboard.activity == .offeredFromHost)

        let pasteboard = rig.pasteboard
        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        try await link.changed.wait { link.opened.count == 1 }
        let limit = ClipboardPasteLimit.defaultBytes
        rig.clipboard.end.pullEnded(link.opened[0], .failed(WireError(.tooLarge, limit: UInt64(limit))))

        #expect(await paste.value == nil)
        try await rig.noticed.wait {
            rig.clipboard.activity == .pasteRefused(.pasteTooLarge, pasteLimitBytes: limit)
        }
        #expect(
            AgentMenuText.clipboardLine(rig.clipboard.activity)
                == "Clipboard: too large to paste — over the \(ClipboardPasteLimit.displayLimit(limit)) transfer limit")
    }

    /// Lands the one pull `link` opened with `bytes`, where its order says.
    private func landPull(_ bytes: Data, _ rig: Rig, _ link: RecordingLink) async throws {
        try await link.changed.wait { link.opened.count == 1 }
        let order = try #require(link.orders.first)
        guard case .staged(let directory, .exactly(let name)) = order.landing else {
            return rig.clipboard.end.pullEnded(link.opened[0], .landed(.inline(bytes)))
        }
        try bytes.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
        rig.clipboard.end.pullEnded(link.opened[0], .landed(.named(name)))
    }

    @Test(
        "Turning passthrough off, or the host's CLIPBOARD going, keeps what a paste in the guest had of the host's offer, as data (step 35c)",
        arguments: [ErrorCode.disabledByPolicy, .capabilityWithdrawn])
    func passthroughOffKeepsWhatWasPasted(code: ErrorCode) async throws {
        let rig = rig()
        let pasteboard = rig.pasteboard
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        rig.clipboard.apply(Self.policy(passthrough: true))
        try await receiveHostOffer(rig, link)

        // `pbpaste` in the guest lands the Mac's text; AppKit finishes with the provider, the write standing.
        let text = NSPasteboard.PasteboardType.string
        let pasted = Data("pasted before off".utf8)
        let paste = Task.detached { pasteboard.invokeProvider(forType: text) }
        try await landPull(pasted, rig, link)
        #expect(await paste.value == pasted)
        pasteboard.finishProvider(itemIndex: 0)
        await drainMainQueue()
        #expect(rig.clipboard.activity == .receivedFromHost)

        rig.clipboard.end.handle(
            .offerEnded(.clipboard, .remote, token: Self.hostToken, .resetByPeer(WireError(code))), on: link)
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pasteboard.dataByItem == [[text: pasted]])
    }

    @Test("A host offer the pasteboard refuses to take is let go, and the paste shown failed")
    func refusedOfferWriteIsShown() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setLink(link)
        rig.pasteboard.failNextWrite()
        rig.clipboard.end.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: false, count: 1)),
            on: link)

        try await link.changed.wait { link.releases == [Self.hostToken] }
        try await rig.noticed.wait { rig.clipboard.activity == .pasteRefused(.pasteFailed, pasteLimitBytes: nil) }
        #expect(AgentMenuText.clipboardLine(rig.clipboard.activity) == "Clipboard: paste failed")
    }

    @Test("A host offer of only files over the paste ceiling leaves the guest's clipboard as it is, refused too large")
    func hostOfferOfOversizeFilesAlone() async throws {
        let rig = rig()
        var file = Self.textAndFileItem(fileSize: 3 << 30)
        file.representations.removeFirst()
        let link = RecordingLink(items: [file])
        rig.clipboard.setLink(link)
        #expect(rig.pasteboard.setString("the guest's", forType: .string))
        let before = rig.pasteboard.changeCount

        rig.clipboard.end.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: false, count: 1)),
            on: link)
        let limit = ClipboardPasteLimit.defaultBytes
        try await rig.noticed.wait {
            rig.clipboard.activity == .pasteRefused(.pasteTooLarge, pasteLimitBytes: limit)
        }
        #expect(rig.pasteboard.changeCount == before)
        #expect(rig.pasteboard.items.first?.data(forType: .string) == Data("the guest's".utf8))
    }

    @Test("A host offer of text and files over the paste ceiling is published without the files, refused too large")
    func hostOfferLeavesOutOversizeFiles() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textAndFileItem(fileSize: 3 << 30)])
        rig.clipboard.setLink(link)

        try await receiveHostOffer(rig, link)
        #expect(rig.pasteboard.promisedTypes == [NSPasteboard.PasteboardType.string])
        let limit = ClipboardPasteLimit.defaultBytes
        try await rig.noticed.wait {
            rig.clipboard.activity == .pasteRefused(.pasteTooLarge, pasteLimitBytes: limit)
        }
        #expect(link.releases.isEmpty)
    }

    // MARK: - Serving the host's pulls

    /// A promise whose call-in the test hears.
    @MainActor
    private final class HeardPromise: FilePromiseReceiving {
        let promise: FakeFilePromiseReceiver
        let calledIn = AsyncGate()

        init(_ name: String) {
            promise = FakeFilePromiseReceiver(
                files: [(name, .file(Data(name.utf8)))], fileType: "public.png", deferred: true)
        }

        var fileNames: [String] { promise.fileNames }
        var fileTypes: [String] { promise.fileTypes }
        var callIns: Int { promise.callIns }

        func receivePromisedFiles(
            atDestination destination: URL, options: [AnyHashable: Any], operationQueue: OperationQueue,
            reader: @escaping (URL, (any Error)?) -> Void
        ) {
            promise.receivePromisedFiles(
                atDestination: destination, options: options, operationQueue: operationQueue, reader: reader)
            calledIn.notify()
        }
    }

    @Test("A pull waiting on a promise's call-in ends when the pull ends, and when its offer does")
    func callInWaitEndsWithItsPullOrOffer() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        let end = rig.clipboard.end
        func id(_ stream: UInt32) -> ItemPullID {
            ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: stream))
        }
        func pull(_ stream: UInt32, of offer: ItemOffer) -> Task<Result<ItemContent, WireError>, Never> {
            var request = PullRequest()
            request.token = offer.token
            let id = id(stream)
            return Task.detached { end.content(id, request) }
        }
        func failure(_ result: Result<ItemContent, WireError>) -> ErrorCode? {
            if case .failure(let error) = result { error.code } else { nil }
        }
        /// Copies `promise` in the guest and returns its offer.
        func offered(_ promise: HeardPromise) async throws -> ItemOffer {
            let offered = link.offers.count
            rig.pasteboard.setFilePromise(promise)
            poll(rig)
            try await link.changed.wait { link.offers.count == offered + 1 }
            return try #require(link.offers.last)
        }

        // The source never delivers: each pull waits on the call-in until something ends it.
        let first = HeardPromise("a.png")
        let offer = try await offered(first)
        let ended = pull(2, of: offer)
        try await first.calledIn.wait { first.callIns == 1 }
        end.handle(.serveEnded(.clipboard, id(2), .closed(.connectionLost)), on: link)
        #expect(failure(await ended.value) == .cancelled)

        // A pull whose end came before its content was asked for is not served at all.
        end.handle(.serveEnded(.clipboard, id(4), .closed(.connectionLost)), on: link)
        #expect(failure(await pull(4, of: offer).value) == .cancelled)

        let second = HeardPromise("b.png")
        let replacing = try await offered(second)
        let withdrawn = pull(6, of: replacing)
        try await second.calledIn.wait { second.callIns == 1 }
        end.handle(
            .offerEnded(.clipboard, .local, token: replacing.token, .resetLocally(WireError(.cancelled))), on: link)
        #expect(failure(await withdrawn.value) == .itemRepresentationUnavailable)
    }

    // MARK: - One current clipboard

    @Test("Publishing the host's offer withdraws the guest's own: one current clipboard")
    func publishingWithdrawsTheGuestsOffer() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        openGate(rig, link)
        copy("copied in the guest", rig)
        try await link.changed.wait { link.offers.count == 1 }

        try await receiveHostOffer(rig, link)
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
    }

    @Test("A host clipboard offer of no items is refused: released, and the guest's clipboard left as it is")
    func hostOfferOfNoItemsIsRefused() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        copy("copied in the guest", rig)
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.end.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: false, count: 0)),
            on: link)
        try await link.changed.wait { link.releases == [Self.hostToken] }
        #expect(link.withdrawals.isEmpty)
        #expect(rig.pasteboard.items.first?.data(forType: .string) == Data("copied in the guest".utf8))
    }

    @Test("A copy that offers nothing withdraws the guest's offer")
    func emptyCopyWithdraws() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        copy("copied in the guest", rig)
        try await link.changed.wait { link.offers.count == 1 }

        // A password manager clears the clipboard.
        _ = rig.pasteboard.clearContents()
        poll(rig)
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
        #expect(link.offers.count == 1)
    }
}
