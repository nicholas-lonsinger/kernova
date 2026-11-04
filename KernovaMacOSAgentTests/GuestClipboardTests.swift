import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

/// The guest's clipboard over the session peer's CLIPBOARD items: when its copies are offered to the host, and
/// what becomes of the host's offers — over a fake pasteboard and a link recording what it is asked to send.
@Suite("GuestClipboard", .caseScoped)
@MainActor
struct GuestClipboardTests {
    private let staging = TestStagingRoot()

    /// The calls a connection is asked to make, each completed at once: offers open, and each item read is
    /// `items`' entry. A pull is ordered through `sink` and opened, or with no sink refused `WRITE_FAILED`.
    private final class RecordingLink: ClipboardItemLink {
        private struct Calls {
            var offers: [ItemOffer] = []
            var withdrawals: [Data] = []
            var releases: [Data] = []
            var refusals: [(token: Data, code: ErrorCode)] = []
            var ceilings: [UInt64] = []
            var orders: [ItemPullOrder] = []
            var opened: [ItemPullID] = []
        }

        private let calls = Locked(Calls())
        private let items: [OfferedItem]
        private let sink: ItemSinkAdapter<POSIXTreeFileSystem>?
        let changed = AsyncGate()

        init(items: [OfferedItem] = [], sink: ItemSinkAdapter<POSIXTreeFileSystem>? = nil) {
            self.items = items
            self.sink = sink
        }

        var offers: [ItemOffer] { calls.withLock(\.offers) }
        var withdrawals: [Data] { calls.withLock(\.withdrawals) }
        var releases: [Data] { calls.withLock(\.releases) }
        var refusals: [(token: Data, code: ErrorCode)] { calls.withLock(\.refusals) }
        /// The `byte_ceiling` of each pull ordered, in order.
        var ceilings: [UInt64] { calls.withLock(\.ceilings) }
        /// Each pull ordered, in order.
        var orders: [ItemPullOrder] { calls.withLock(\.orders) }
        /// The id of each pull opened, in order.
        var opened: [ItemPullID] { calls.withLock(\.opened) }

        func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
            calls.withLock { $0.offers.append(offer) }
            changed.notify()
            completion(nil)
        }

        func withdrawOffer(_ token: Data) {
            calls.withLock { $0.withdrawals.append(token) }
            changed.notify()
        }

        func releaseOffer(_ token: Data) {
            calls.withLock { $0.releases.append(token) }
            changed.notify()
        }

        func refuseOffer(_ token: Data, _ error: WireError) {
            calls.withLock { $0.refusals.append((token, error.code)) }
            changed.notify()
        }

        func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
            completion(items.indices.contains(Int(item)) ? items[Int(item)] : nil)
        }

        func pullItem(
            _ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void
        ) {
            let id = calls.withLock { calls in
                let id = ItemPullID(
                    generation: ConnectionGeneration(rawValue: 1),
                    stream: StreamID(rawValue: UInt32(3 + 2 * calls.opened.count)))
                calls.opened.append(id)
                return id
            }
            completion(.success(id))
            changed.notify()
        }

        func cancelPull(_ id: ItemPullID) {}

        func order(
            token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
            budget: ByteBudget?
        ) throws(WireError) -> ItemPullOrder {
            calls.withLock { $0.ceilings.append(byteCeiling) }
            guard let sink else { throw WireError(.writeFailed) }
            let order = try sink.order(
                token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
                budget: budget)
            calls.withLock { $0.orders.append(order) }
            return order
        }
    }

    private struct Rig {
        let pasteboard: FakePasteboard
        let clipboard: GuestClipboard
    }

    private func rig() -> Rig {
        let pasteboard = FakePasteboard()
        return Rig(
            pasteboard: pasteboard,
            clipboard: GuestClipboard(pasteboard: pasteboard, stagingRoot: staging.root))
    }

    /// The types each of `link`'s offers carries, in order.
    private func offeredUTIs(_ link: RecordingLink) -> [[String?]] {
        link.offers.map { $0.items.flatMap { $0.representations.map(\.type.appleUTI) } }
    }

    // MARK: - Gating

    @Test("A copy is offered only once the session is on the console and its connection can use CLIPBOARD")
    func offeredOnlyOnConsoleAndUsable() async throws {
        let rig = rig()
        let link = RecordingLink()
        #expect(rig.pasteboard.setString("first", forType: .string))

        rig.clipboard.setLink(link)
        rig.clipboard.checkPasteboard()
        #expect(!rig.clipboard.isOffering)

        rig.clipboard.setOnConsole(true)
        try await link.changed.wait { link.offers.count == 1 }
        #expect(offeredUTIs(link) == [[ClipboardContent.utf8TextUTI]])
    }

    @Test("A copy the gate opening offered is not offered again by the next poll")
    func gateOfferIsSeen() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.checkPasteboard()
        await drainMainQueue()
        #expect(link.offers.count == 1)
    }

    @Test("Usability returning re-offers the clipboard as it stands")
    func usabilityReturningReoffers() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("first", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.setLink(nil)
        #expect(!rig.clipboard.isOffering)
        rig.clipboard.setLink(link)

        try await link.changed.wait { link.offers.count == 2 }
        #expect(link.offers[0].token != link.offers[1].token)
        #expect(link.offers[0].items == link.offers[1].items)
    }

    @Test("Off the console a copy is not offered; the console returning offers the copy that stands")
    func offConsoleCopyWaitsForTheConsole() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        #expect(rig.pasteboard.setString("on", forType: .string))
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.setOnConsole(false)
        #expect(rig.pasteboard.setItem([(.string, Data("off".utf8)), (.html, Data("<b>off</b>".utf8))]))
        rig.clipboard.checkPasteboard()
        #expect(link.offers.count == 1)

        rig.clipboard.setOnConsole(true)
        try await link.changed.wait { link.offers.count == 2 }
        #expect(offeredUTIs(link).last == [ClipboardContent.utf8TextUTI, NSPasteboard.PasteboardType.html.rawValue])
    }

    // MARK: - The host's offers

    @Test("The host's offer is published promised, and released once a copy in the guest replaces it")
    func hostOfferPublishedThenReleased() async throws {
        let rig = rig()
        var text = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        representation.storage = .inline
        text.representations = [representation]
        let link = RecordingLink(items: [text])
        rig.clipboard.setLink(link)
        let token = Data(repeating: 9, count: 16)

        rig.clipboard.exchange.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: token, concealed: false, count: 1)),
            on: link)
        try await rig.pasteboard.changed.wait { !rig.pasteboard.promisedTypes.isEmpty }
        #expect(rig.pasteboard.promisedTypes == [NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)])
        // The poll does not read the agent's own promise as a copy.
        rig.clipboard.checkPasteboard()
        #expect(link.releases.isEmpty)

        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.releases == [token] }
        #expect(link.offers.isEmpty)
    }

    @Test("The host's policy sets each pull's byte ceiling, and a policy arriving later changes it")
    func policySetsThePullCeiling() async throws {
        let rig = rig()
        var text = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        representation.storage = .inline
        text.representations = [representation]
        let link = RecordingLink(items: [text])
        rig.clipboard.setLink(link)
        func policy(_ bytes: Int) -> PolicySnapshot {
            PolicySnapshot([ClipboardPolicyValue(maxPasteBytes: UInt64(bytes)).policy(enabled: true)])
        }
        let first = ClipboardPasteLimit.choices[0]
        rig.clipboard.apply(policy(first))
        rig.clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(
                    feature: .clipboard, token: Data(repeating: 9, count: 16), concealed: false, count: 1)),
            on: link)
        try await rig.pasteboard.changed.wait { !rig.pasteboard.promisedTypes.isEmpty }
        let pasteboard = rig.pasteboard
        let type = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)

        // A paste holds its thread until the pull ends, so it fires off the main actor.
        _ = await Task.detached { pasteboard.invokeProvider(forType: type) }.value
        #expect(link.ceilings == [UInt64(first)])

        let raised = 16 * 1024 * 1024 * 1024
        rig.clipboard.apply(policy(raised))
        _ = await Task.detached { pasteboard.invokeProvider(forType: type) }.value
        #expect(link.ceilings == [UInt64(first), UInt64(raised)])
        #expect(rig.clipboard.pasteCeilingBytes == raised)
    }

    @Test("A paste of the host's file refused over the paste ceiling shows that refusal and the ceiling")
    func pullOverTheCeilingIsShown() async throws {
        let noticed = AsyncGate()
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: staging.root, onNotice: { noticed.notify() })
        var file = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: "public.data")
        representation.storage = .file
        representation.name = Data("big.bin".utf8)
        file.representations = [representation]
        let link = RecordingLink(items: [file], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        clipboard.setLink(link)
        clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(
                    feature: .clipboard, token: Data(repeating: 9, count: 16), concealed: false, count: 1)),
            on: link)
        try await pasteboard.changed.wait { !pasteboard.promisedTypes.isEmpty }
        // Published within the ceiling: the offer's estimate fits, and only the pull finds it does not.
        #expect(clipboard.activity == .offeredFromHost)

        let paste = Task.detached { pasteboard.invokeProvider(forType: .fileURL) }
        try await link.changed.wait { link.opened.count == 1 }
        let limit = ClipboardPasteLimit.defaultBytes
        clipboard.exchange.pullEnded(link.opened[0], .failed(WireError(.tooLarge, limit: UInt64(limit))))

        #expect(await paste.value == nil)
        try await noticed.wait { clipboard.activity == .pasteRefused(.pasteTooLarge, pasteLimitBytes: limit) }
        #expect(
            AgentMenuText.clipboardLine(clipboard.activity)
                == "Clipboard: too large to paste — over the \(ClipboardPasteLimit.displayLimit(limit)) transfer limit")
    }

    @Test("A paste of the host's concealed text lands it in memory, creating nothing under the staging root")
    func concealedPasteStagesNothing() async throws {
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(pasteboard: pasteboard, stagingRoot: staging.root)
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        clipboard.setLink(link)
        clipboard.exchange.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: true, count: 1)),
            on: link)
        try await pasteboard.changed.wait { !pasteboard.promisedTypes.isEmpty }

        let password = Data("hunter2".utf8)
        let paste = Task.detached { pasteboard.invokeProvider(forType: .init(ClipboardContent.utf8TextUTI)) }
        try await link.changed.wait { link.opened.count == 1 }
        clipboard.exchange.pullEnded(link.opened[0], .landed(.inline(password)))

        #expect(await paste.value == password)
        let staged = FileManager.default.enumerator(atPath: staging.root.url.path)?.allObjects ?? []
        #expect(staged.isEmpty)
    }

    // MARK: - Serving the host's pulls

    private static let promiseTypes: [NSPasteboard.PasteboardType] = [
        .init("com.apple.NSFilePromiseItemMetaData"), .init("com.apple.pasteboard.promised-file-content-type"),
    ]

    /// Offers through `rig`'s exchange a copy of one file promise, `receiver`, whose call-in notifies `calledIn`.
    private func offerPromise(
        _ receiver: FakeFilePromiseReceiver, on rig: Rig, link: RecordingLink, calledIn: AsyncGate
    ) async throws -> ItemOffer {
        let promised = FakePasteboard()
        promised.setItem(Self.promiseTypes.map { (type: $0, data: Data()) })
        let root = staging.root
        let outcome = await ClipboardPasteboardReader.readOffer(
            from: promised, promises: [receiver],
            promiseDestination: {
                calledIn.notify()
                return try ClipboardFileStaging(label: "promises", root: root).reserveScratchDirectory(generation: 1)
            },
            sizeOf: nil)
        guard case .offer(let source, _) = outcome else { throw TestFailure("not an offer: \(outcome)") }
        let offered = link.offers.count
        rig.clipboard.exchange.offer(source)
        try await link.changed.wait { link.offers.count == offered + 1 }
        return try #require(link.offers.last)
    }

    @Test("A pull waiting on a promise's call-in ends when the pull ends, and when its offer does")
    func callInWaitEndsWithItsPullOrOffer() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.exchange.setLink(link)
        let exchange = rig.clipboard.exchange
        func id(_ stream: UInt32) -> ItemPullID {
            ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: stream))
        }
        func pull(_ stream: UInt32, of offer: ItemOffer) -> Task<Result<ItemContent, WireError>, Never> {
            var request = PullRequest()
            request.token = offer.token
            let id = id(stream)
            let representation = offer.items[0].representations[0]
            return Task.detached { exchange.content(id, request, representation) }
        }
        func failure(_ result: Result<ItemContent, WireError>) -> ErrorCode? {
            if case .failure(let error) = result { error.code } else { nil }
        }

        // The source never delivers: each pull waits on the call-in until something ends it.
        let calledIn = AsyncGate()
        let first = FakeFilePromiseReceiver(
            files: [("a.png", .file(Data("a".utf8)))], fileType: "public.png", deferred: true)
        let offer = try await offerPromise(first, on: rig, link: link, calledIn: calledIn)
        let ended = pull(2, of: offer)
        try await calledIn.wait { first.callIns == 1 }
        exchange.handle(.serveEnded(.clipboard, id(2), .closed(.connectionLost)), on: link)
        #expect(failure(await ended.value) == .cancelled)

        // A pull whose end came before its content was asked for is not served at all.
        exchange.handle(.serveEnded(.clipboard, id(4), .closed(.connectionLost)), on: link)
        #expect(failure(await pull(4, of: offer).value) == .cancelled)

        let second = FakeFilePromiseReceiver(
            files: [("b.png", .file(Data("b".utf8)))], fileType: "public.png", deferred: true)
        let replacing = try await offerPromise(second, on: rig, link: link, calledIn: calledIn)
        let withdrawn = pull(6, of: replacing)
        try await calledIn.wait { second.callIns == 1 }
        exchange.handle(
            .offerEnded(.clipboard, .local, token: replacing.token, .resetLocally(WireError(.cancelled))), on: link)
        #expect(failure(await withdrawn.value) == .itemRepresentationUnavailable)
    }

    // MARK: - One current clipboard

    private static let hostToken = Data(repeating: 9, count: 16)

    private static func textItem() -> OfferedItem {
        var item = OfferedItem()
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: ClipboardContent.utf8TextUTI)
        representation.storage = .inline
        item.representations = [representation]
        return item
    }

    /// Has the host offer one text item on `link` and waits for the guest pasteboard to promise it.
    private func receiveHostOffer(_ rig: Rig, _ link: RecordingLink, token: Data = hostToken) async throws {
        rig.clipboard.exchange.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: token, concealed: false, count: 1)),
            on: link)
        try await rig.pasteboard.changed.wait { rig.clipboard.exchange.remote?.token == token }
    }

    @Test("A guest offer names the last host offer the guest received on its connection")
    func offerNamesTheLastHostOffer() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)

        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.offers.count == 1 }
        #expect(link.offers[0].after == Self.hostToken)

        // A new connection has received nothing yet.
        rig.clipboard.setLink(nil)
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 2 }
        #expect(link.offers[1].after.isEmpty)
    }

    @Test("Publishing the host's offer withdraws the guest's own: one current clipboard")
    func publishingWithdrawsTheGuestsOffer() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        try await receiveHostOffer(rig, link)
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
        #expect(rig.clipboard.exchange.localSource == nil)
    }

    @Test(
        "A host offer that ends is retracted: the host ends it, with or without a successor, or its connection drops",
        arguments: [
            (StreamClosure.resetByPeer(WireError(.cancelled)), true),
            (StreamClosure.resetByPeer(WireError(.itemOfferReplaced)), true),
            (StreamClosure.connectionLost, true),
        ])
    func hostEndRetracts(closure: StreamClosure, retracted: Bool) async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)
        #expect(!rig.pasteboard.promisedTypes.isEmpty)

        rig.clipboard.exchange.handle(.offerEnded(.clipboard, .remote, token: Self.hostToken, closure), on: link)
        #expect(rig.pasteboard.promisedTypes.isEmpty == retracted)
        // The retraction's clear is the agent's own write: the poll reads no copy from it, and the gate opening
        // reports it empty, unchanged.
        rig.clipboard.setOnConsole(true)
        rig.clipboard.checkPasteboard()
        await drainMainQueue()
        #expect(link.offers.allSatisfy { $0.items.isEmpty })
    }

    @Test("The connection leaving retracts the host's offer at once, and its return reports the clear unchanged")
    func linkDropRetracts() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)
        #expect(!rig.pasteboard.promisedTypes.isEmpty)

        rig.clipboard.setLink(nil)
        #expect(rig.pasteboard.promisedTypes.isEmpty)
        #expect(rig.clipboard.exchange.remote == nil)
        rig.clipboard.setLink(link)
        await drainMainQueue()
        #expect(link.offers.last.map { $0.items.isEmpty && !$0.changedWhileUnlinked } == true)
    }

    @Test("A host clipboard offer of no items is refused: released, and the guest's clipboard left as it is")
    func hostOfferOfNoItemsIsRefused() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.exchange.handle(
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
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        // A password manager clears the clipboard.
        _ = rig.pasteboard.clearContents()
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
        #expect(link.offers.count == 1)
    }

    @Test("The connection returning re-offers a copy of the guest's own, never the host's write it holds, reporting it")
    func returnReoffersOnlyLocalCopies() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)

        rig.clipboard.setLink(nil)
        rig.clipboard.setLink(link)
        rig.clipboard.setOnConsole(false)
        rig.clipboard.setOnConsole(true)
        await drainMainQueue()
        #expect(link.offers.allSatisfy { $0.items.isEmpty })
    }

    // MARK: - Copies

    private static let askToken = Data(repeating: 4, count: 16)
    private static let copyToken = Data(repeating: 6, count: 16)

    private static func copyHeader(token: Data, count: Int, concealed: Bool = false) -> ItemSetHeaderValue {
        ItemSetHeaderValue(feature: .clipboard, token: token, concealed: concealed, count: count, copy: .snapshot)
    }

    /// The host's ask for a snapshot of the guest's clipboard.
    private static let askHeader = ItemSetHeaderValue(
        feature: .clipboard, token: askToken, concealed: false, count: 0, copy: .ask)

    @Test(
        "The host's ask is answered with a snapshot of the pasteboard naming it, served after the pasteboard moves on")
    func askIsAnsweredWithASnapshot() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.exchange.handle(.offerReceived(Self.askHeader), on: link)
        try await link.changed.wait { link.offers.count == 2 && link.releases == [Self.askToken] }
        let copy = try #require(link.offers.last)
        #expect(copy.copy == .snapshot && copy.after == Self.askToken)
        #expect(copy.items[0].representations[0].sizeEstimate == UInt64("copied in the guest".utf8.count))

        // A copy in the guest since neither withdraws the snapshot nor changes what it serves.
        #expect(rig.pasteboard.setString("copied since", forType: .string))
        rig.clipboard.checkPasteboard()
        var request = PullRequest()
        request.token = copy.token
        let exchange = rig.clipboard.exchange
        let representation = copy.items[0].representations[0]
        let pull = ItemPullID(generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: 2))
        let served = await Task.detached { exchange.content(pull, request, representation) }.value
        #expect(served == .success(.inline(Data("copied in the guest".utf8))))
        #expect(!link.withdrawals.contains(copy.token))
    }

    @Test("Off the console the host's ask is declined: nothing to copy")
    func askOffTheConsoleAnswersNothing() async throws {
        let rig = rig()
        let link = RecordingLink()
        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        rig.clipboard.setLink(link)

        rig.clipboard.exchange.handle(.offerReceived(Self.askHeader), on: link)
        try await link.changed.wait { !link.refusals.isEmpty }
        #expect(link.refusals.map(\.token) == [Self.askToken])
        #expect(link.refusals.map(\.code) == [.clipboardNothingToCopy])
        #expect(link.offers.isEmpty)
    }

    @Test("The host's ask of a pasteboard that is the guest's write of the host's offer is declined, held already")
    func askOfTheHostsOwnOfferIsHeld() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try await receiveHostOffer(rig, link)
        let before = rig.pasteboard.changeCount
        let offersBefore = link.offers.count

        rig.clipboard.exchange.handle(.offerReceived(Self.askHeader), on: link)
        try await link.changed.wait { !link.refusals.isEmpty }
        #expect(link.refusals.map(\.token) == [Self.askToken])
        #expect(link.refusals.map(\.code) == [.clipboardAlreadyHeld])
        #expect(rig.pasteboard.changeCount == before)
        #expect(!rig.pasteboard.promisedTypes.isEmpty)
        #expect(link.offers.count == offersBefore)
        #expect(link.opened.isEmpty)
    }

    private static func textAndFileItem() -> OfferedItem {
        var item = textItem()
        var file = Representation()
        file.type = TypeDescriptor(appleUTI: "public.data")
        file.storage = .file
        file.name = Data("a.bin".utf8)
        item.representations.append(file)
        return item
    }

    /// Has the host send `item` as a copy, and lands the text pull it opens with `text`.
    private func receiveCopy(
        _ item: OfferedItem, text: Data, on rig: Rig, _ link: RecordingLink, before landing: () -> Void = {}
    ) async throws {
        rig.clipboard.exchange.handle(.offerReceived(Self.copyHeader(token: Self.copyToken, count: 1)), on: link)
        try await link.changed.wait { link.opened.count == 1 }
        landing()
        let order = try #require(link.orders.first)
        guard case .staged(let directory, .exactly(let name)) = order.landing else {
            Issue.record("landing \(order.landing)")
            return
        }
        try text.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
        rig.clipboard.exchange.pullEnded(link.opened[0], .landed(.named(name)))
    }

    @Test(
        "The host's copy lands its text at once and is written as data, its file promised, held until the pasteboard lets go"
    )
    func hostCopyIsWrittenAsData() async throws {
        let rig = rig()
        let link = RecordingLink(
            items: [Self.textAndFileItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try await receiveCopy(Self.textAndFileItem(), text: Data("from the host".utf8), on: rig, link)

        try await rig.pasteboard.changed.wait { !rig.pasteboard.dataByItem.isEmpty }
        #expect(
            rig.pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("from the host".utf8))
        #expect(rig.pasteboard.promisedTypes == [.fileURL])
        // Only the text was pulled.
        #expect(link.opened.count == 1)
        #expect(!link.releases.contains(Self.copyToken))
        // The written copy is the agent's own write: the poll offers nothing of it.
        rig.clipboard.checkPasteboard()
        await drainMainQueue()
        #expect(link.offers.allSatisfy { $0.items.isEmpty })

        #expect(rig.pasteboard.setString("copied in the guest", forType: .string))
        try await link.changed.wait { link.releases.contains(Self.copyToken) }
    }

    @Test("A guest pasteboard that changed before the host's copy landed is left alone, and the copy refused so")
    func hostCopyLeavesAChangedPasteboard() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        try await receiveCopy(Self.textItem(), text: Data("from the host".utf8), on: rig, link) {
            #expect(rig.pasteboard.setString("copied meanwhile", forType: .string))
        }

        try await link.changed.wait { !link.refusals.isEmpty }
        #expect(link.refusals.map(\.token) == [Self.copyToken])
        #expect(link.refusals.map(\.code) == [.clipboardChanged])
        #expect(rig.pasteboard.items.first?.data(forType: .string) == Data("copied meanwhile".utf8))
    }

    @Test("The connection leaving retracts a host copy's pending files")
    func hostCopyRetractedWithTheLink() async throws {
        let rig = rig()
        let link = RecordingLink(
            items: [Self.textAndFileItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        try await receiveCopy(Self.textAndFileItem(), text: Data("from the host".utf8), on: rig, link)
        try await rig.pasteboard.changed.wait { rig.pasteboard.promisedTypes == [.fileURL] }

        rig.clipboard.setLink(nil)
        try await rig.pasteboard.changed.wait { rig.pasteboard.promisedTypes.isEmpty }
        #expect(rig.pasteboard.dataByItem.isEmpty)
    }

    @Test("A connection's first offer says whether the clipboard changed while unlinked, reporting an empty one")
    func firstOfferReportsChangeWhileUnlinked() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 1 }
        // Never linked before: changed, and empty.
        #expect(link.offers[0].items.isEmpty && link.offers[0].changedWhileUnlinked)

        rig.clipboard.setLink(nil)
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 2 }
        #expect(link.offers[1].items.isEmpty && !link.offers[1].changedWhileUnlinked)

        rig.clipboard.setLink(nil)
        #expect(rig.pasteboard.setString("copied while unlinked", forType: .string))
        rig.clipboard.setLink(link)
        try await link.changed.wait { link.offers.count == 3 }
        #expect(!link.offers[2].items.isEmpty && link.offers[2].changedWhileUnlinked)
    }
}
