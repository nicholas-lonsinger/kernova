import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaFileTree
import KernovaItemTransfer
import KernovaKit
import KernovaTestSupport
import KernovaWire
import Testing

/// The guest's clipboard over the session peer's CLIPBOARD items: when its copies are offered to the host, and
/// what becomes of the host's offers — over a fake pasteboard and a link recording what it is asked to send.
@Suite("GuestClipboard", .caseScoped)
@MainActor
struct GuestClipboardTests {
    private let staging = TestStagingRoot()

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

    /// The host's policy, passthrough `on` or off.
    private static func policy(passthrough on: Bool) -> PolicySnapshot {
        PolicySnapshot([
            ClipboardPolicyValue(maxPasteBytes: 0, passthrough: on).policy(enabled: true)
        ])
    }

    /// Opens the gate on `link`: on the console, passthrough on, the connection usable.
    private func openGate(_ rig: Rig, _ link: RecordingLink) {
        rig.clipboard.setOnConsole(true)
        rig.clipboard.apply(Self.policy(passthrough: true))
        rig.clipboard.setLink(link)
    }

    /// Copies `text` in the guest and polls the pasteboard.
    private func copy(_ text: String, _ rig: Rig) {
        #expect(rig.pasteboard.setString(text, forType: .string))
        rig.clipboard.checkPasteboard()
    }

    /// The types each of `link`'s offers carries, in order.
    private func offeredUTIs(_ link: RecordingLink) -> [[String?]] {
        link.offers.map { $0.items.flatMap { $0.representations.map(\.type.appleUTI) } }
    }

    // MARK: - Gating

    @Test("A copy is offered only while passthrough runs, on the console, over a connection that can use CLIPBOARD")
    func offeredOnlyWhilePassthroughRuns() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        copy("passthrough off", rig)
        await drainMainQueue()
        #expect(!rig.clipboard.isOffering)
        #expect(link.offers.isEmpty)

        rig.clipboard.apply(Self.policy(passthrough: true))
        #expect(rig.clipboard.isOffering)
        copy("passthrough on", rig)
        try await link.changed.wait { link.offers.count == 1 }
        #expect(offeredUTIs(link) == [[ClipboardContent.utf8TextUTI]])
    }

    @Test("Turning passthrough off withdraws the guest's offer, and later copies are not offered")
    func passthroughOffWithdraws() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        copy("offered", rig)
        try await link.changed.wait { link.offers.count == 1 }

        rig.clipboard.apply(Self.policy(passthrough: false))
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
        copy("not offered", rig)
        await drainMainQueue()
        #expect(link.offers.count == 1)
    }

    @Test("A connection's start offers nothing the pasteboard holds, first or returning; the next copy crosses")
    func connectionStartOffersNothing() async throws {
        let rig = rig()
        let link = RecordingLink()
        #expect(rig.pasteboard.setString("copied before the first connection", forType: .string))
        openGate(rig, link)
        await drainMainQueue()
        #expect(link.offers.isEmpty)

        rig.clipboard.setLink(nil)
        #expect(!rig.clipboard.isOffering)
        #expect(rig.pasteboard.setString("copied while unlinked", forType: .string))
        rig.clipboard.setLink(link)
        rig.clipboard.checkPasteboard()
        await drainMainQueue()
        #expect(link.offers.isEmpty)

        copy("copied after the return", rig)
        try await link.changed.wait { link.offers.count == 1 }
    }

    @Test("Leaving the console withdraws the guest's offer as the feature going, never as its clipboard moving on")
    func offConsoleWithdrawsAsTheFeatureGoing() async throws {
        let rig = rig()
        let link = RecordingLink()
        openGate(rig, link)
        copy("offered", rig)
        try await link.changed.wait { link.offers.count == 1 }
        let token = link.offers[0].token
        await drainMainQueue()

        rig.clipboard.setOnConsole(false)
        try await link.changed.wait { link.withdrawals == [token] }
        #expect(link.withdrawalCodes[token] == .capabilityWithdrawn)
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

    @Test("The host's policy sets each pull's byte ceiling, and a policy arriving later changes it for later offers")
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
            PolicySnapshot([
                ClipboardPolicyValue(maxPasteBytes: UInt64(bytes), passthrough: false).policy(enabled: true)
            ])
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

        // An offer's pulls land against one budget, the ceiling as its first pull read it.
        let raised = 16 * 1024 * 1024 * 1024
        rig.clipboard.apply(policy(raised))
        let later = Data(repeating: 8, count: 16)
        rig.clipboard.exchange.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: later, concealed: false, count: 1)),
            on: link)
        try await rig.pasteboard.changed.wait { rig.clipboard.exchange.remote?.token == later }
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

    /// Publishes the host's passthrough offer of `item` on `pasteboard` through `clipboard`, over `link`.
    private func receiveOffer(
        _ item: OfferedItem, _ clipboard: GuestClipboard, _ pasteboard: FakePasteboard, _ link: RecordingLink
    ) async throws {
        clipboard.setLink(link)
        clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: false, count: 1)),
            on: link)
        try await pasteboard.changed.wait { !pasteboard.promisedTypes.isEmpty }
    }

    /// Lands the one pull `link` opened with `bytes`, where its order says.
    private func landPull(_ bytes: Data, _ clipboard: GuestClipboard, _ link: RecordingLink) async throws {
        try await link.changed.wait { link.opened.count == 1 }
        let order = try #require(link.orders.first)
        guard case .staged(let directory, .exactly(let name)) = order.landing else {
            return clipboard.exchange.pullEnded(link.opened[0], .landed(.inline(bytes)))
        }
        try bytes.write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
        clipboard.exchange.pullEnded(link.opened[0], .landed(.named(name)))
    }

    /// The host resetting its offer `code`: `DISABLED_BY_POLICY` is it turning passthrough off,
    /// `CAPABILITY_WITHDRAWN` CLIPBOARD stopping being usable on its side.
    private func passthroughStops(
        _ clipboard: GuestClipboard, _ link: RecordingLink, _ code: ErrorCode
    ) {
        clipboard.exchange.handle(
            .offerEnded(.clipboard, .remote, token: Self.hostToken, .resetByPeer(WireError(code))), on: link)
    }

    @Test(
        "Turning passthrough off, or the host's CLIPBOARD going, keeps what a paste in the guest had of the host's offer, as data (step 35c)",
        arguments: [ErrorCode.disabledByPolicy, .capabilityWithdrawn])
    func passthroughOffKeepsWhatWasPasted(code: ErrorCode) async throws {
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(pasteboard: pasteboard, stagingRoot: staging.root)
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        try await receiveOffer(Self.textItem(), clipboard, pasteboard, link)

        // `pbpaste` in the guest lands the Mac's text; AppKit finishes with the provider, the write standing.
        let text = NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)
        let pasted = Data("pasted before off".utf8)
        let paste = Task.detached { pasteboard.invokeProvider(forType: text) }
        try await landPull(pasted, clipboard, link)
        #expect(await paste.value == pasted)
        pasteboard.finishProvider(itemIndex: 0)
        await drainMainQueue()

        passthroughStops(clipboard, link, code)
        #expect(pasteboard.promisedTypes.isEmpty)
        #expect(pasteboard.dataByItem == [[text: pasted]])
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
        openGate(rig, link)
        try await receiveHostOffer(rig, link)

        copy("copied in the guest", rig)
        try await link.changed.wait { link.offers.count == 1 }
        #expect(link.offers[0].after == Self.hostToken)

        // A new connection has received nothing yet.
        rig.clipboard.setLink(nil)
        rig.clipboard.setLink(link)
        copy("copied on the new connection", rig)
        try await link.changed.wait { link.offers.count == 2 }
        #expect(link.offers[1].after.isEmpty)
    }

    @Test("Publishing the host's offer withdraws the guest's own: one current clipboard")
    func publishingWithdrawsTheGuestsOffer() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()])
        openGate(rig, link)
        copy("copied in the guest", rig)
        try await link.changed.wait { link.offers.count == 1 }

        try await receiveHostOffer(rig, link)
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
        #expect(rig.clipboard.exchange.localSource == nil)
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
        rig.clipboard.checkPasteboard()
        try await link.changed.wait { link.withdrawals == [link.offers[0].token] }
        #expect(link.offers.count == 1)
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

        // Passthrough is off: the ask is answered all the same.
        rig.clipboard.exchange.handle(.offerReceived(Self.askHeader), on: link)
        try await link.changed.wait { link.offers.count == 1 && link.releases == [Self.askToken] }
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

    /// Has the host ask for the guest's clipboard as it stands, returning the guest's answering copy.
    private func answerAsk(_ token: Data, _ rig: Rig, _ link: RecordingLink) async throws -> ItemOffer {
        let before = link.offers.count
        rig.clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(feature: .clipboard, token: token, concealed: false, count: 0, copy: .ask)),
            on: link)
        try await link.changed.wait { link.offers.count == before + 1 && link.releases.contains(token) }
        return try #require(link.offers.last)
    }

    /// A password manager's copy: text beside `org.nspasteboard.ConcealedType`.
    private static func setConcealed(_ text: String, on pasteboard: FakePasteboard) {
        #expect(
            pasteboard.setItem([
                (type: .string, data: Data(text.utf8)),
                (type: NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI), data: Data()),
            ]))
    }

    @Test(
        "The guest's concealed copy is withdrawn from the host once the guest's clipboard is cleared or replaced; a plain one stays",
        arguments: [true, false])
    func concealedAnswerIsWithdrawnWhenThePasteboardMovesOn(cleared: Bool) async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        #expect(rig.pasteboard.setString("plain text", forType: .string))
        let plain = try await answerAsk(Data(repeating: 0xA1, count: 16), rig, link)
        #expect(!plain.concealed)
        Self.setConcealed("hunter2-guest", on: rig.pasteboard)
        let concealed = try await answerAsk(Data(repeating: 0xA2, count: 16), rig, link)
        #expect(concealed.concealed)
        await drainMainQueue()
        #expect(link.withdrawals.isEmpty)

        if cleared {
            _ = rig.pasteboard.clearContents()
        } else {
            #expect(rig.pasteboard.setString("copied since", forType: .string))
        }
        try await link.changed.wait { link.withdrawals.contains(concealed.token) }
        #expect(link.withdrawalCodes[concealed.token] == .clipboardChanged)
        #expect(!link.withdrawals.contains(plain.token))
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

    private let scratch = TestScratchDirectory(prefix: "guest-clipboard")

    /// Has the host ask for the guest's clipboard, which holds `file`, returning the guest's copy.
    private func sendFileCopy(_ file: URL, _ rig: Rig, _ link: RecordingLink) async throws -> ItemOffer {
        #expect(rig.pasteboard.setFiles([file]))
        rig.clipboard.checkPasteboard()
        rig.clipboard.exchange.handle(.offerReceived(Self.askHeader), on: link)
        try await link.changed.wait { link.offers.contains { $0.copy == .snapshot } }
        return try #require(link.offers.last { $0.copy == .snapshot })
    }

    /// A host copy's one item: a FILE naming representation `representation` of item 0 of the guest's `offer`.
    private static func referenceItem(to offer: Data, representation: UInt32 = 0) -> OfferedItem {
        var file = Representation()
        file.type = TypeDescriptor(appleUTI: "public.data")
        file.storage = .file
        file.name = Data("a.bin".utf8)
        var reference = RepresentationReference()
        reference.offer = offer
        reference.item = 0
        reference.representation = representation
        file.reference = reference
        var item = OfferedItem()
        item.representations = [file]
        return item
    }

    private func guestFile() throws -> URL {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let file = scratch.url.appendingPathComponent("a.bin")
        try Data("the guest's file".utf8).write(to: file)
        return file
    }

    @Test("A host copy naming the guest's own copy by reference is filled from it and written as data, pulling nothing")
    func hostCopyOfReferencesIsFilled() async throws {
        let rig = rig()
        let file = try guestFile()
        rig.clipboard.setOnConsole(true)
        let first = RecordingLink()
        rig.clipboard.setLink(first)
        let guestCopy = try await sendFileCopy(file, rig, first)
        // The guest's clipboard moved on; the host's copy names the file of the copy it still serves.
        #expect(rig.pasteboard.setString("copied since", forType: .string))
        // Reads of the host copy's items answer with its one item.
        let link = RecordingLink(items: [Self.referenceItem(to: guestCopy.token)])
        rig.clipboard.exchange.handle(.offerReceived(Self.copyHeader(token: Self.copyToken, count: 1)), on: link)
        try await link.changed.wait { !link.releases.isEmpty || !link.refusals.isEmpty }
        #expect(link.refusals.isEmpty)
        #expect(link.releases == [Self.copyToken])
        #expect(link.opened.isEmpty)
        #expect(rig.pasteboard.dataByItem.first?[.fileURL] == Data(file.absoluteString.utf8))
        #expect(rig.pasteboard.promisedTypes.isEmpty)
    }

    @Test("A reference filled from a file the guest's copy called in is cloned, so it outlives that copy")
    func filledCallInOutlivesItsCopy() async throws {
        let rig = rig()
        rig.clipboard.setOnConsole(true)
        let first = RecordingLink()
        rig.clipboard.setLink(first)
        rig.pasteboard.setFilePromise(
            FakeFilePromiseReceiver(name: "photo.png", fileType: "public.png", contents: .file(Data("png".utf8))))
        rig.clipboard.checkPasteboard()
        rig.clipboard.exchange.handle(.offerReceived(Self.askHeader), on: first)
        try await first.changed.wait { first.offers.contains { $0.copy == .snapshot } }
        let guestCopy = try #require(first.offers.last { $0.copy == .snapshot })
        #expect(rig.pasteboard.setString("copied since", forType: .string))

        let link = RecordingLink(items: [Self.referenceItem(to: guestCopy.token)])
        rig.clipboard.exchange.handle(.offerReceived(Self.copyHeader(token: Self.copyToken, count: 1)), on: link)
        try await link.changed.wait { !link.releases.isEmpty || !link.refusals.isEmpty }
        let written = try #require(rig.pasteboard.dataByItem.first?[.fileURL])
        let url = try #require(URL(string: String(decoding: written, as: UTF8.self)))
        #expect(url.lastPathComponent == "photo.png")

        // The host lets the guest's copy go, and its called-in file with it; the written clone stays.
        rig.clipboard.exchange.handle(
            .offerEnded(.clipboard, .local, token: guestCopy.token, .completed(remoteEndBody: Data())), on: first)
        await drainMainQueue()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try Data(contentsOf: url) == Data("png".utf8))
    }

    @Test("A host copy's reference the guest can no longer fill is left out, and the host told so")
    func hostCopyOfGoneReferencesIsPartsGone() async throws {
        let rig = rig()
        #expect(rig.pasteboard.setString("the guest's", forType: .string))
        let before = rig.pasteboard.changeCount
        let link = RecordingLink(items: [Self.referenceItem(to: Data(repeating: 3, count: 16))])
        rig.clipboard.setLink(link)
        rig.clipboard.exchange.handle(.offerReceived(Self.copyHeader(token: Self.copyToken, count: 1)), on: link)
        try await link.changed.wait { !link.refusals.isEmpty }
        #expect(link.refusals.map(\.code) == [.clipboardPartsGone])
        #expect(rig.pasteboard.changeCount == before)
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

    /// Has the host send `item` as a copy, `concealed` or not, and lands each text pull it opens with `text`.
    private func receiveCopy(
        _ item: OfferedItem, text: Data, concealed: Bool = false, on rig: Rig, _ link: RecordingLink,
        before landing: () -> Void = {}
    ) async throws {
        let inline = item.representations.filter { $0.storage == .inline }.count
        rig.clipboard.exchange.handle(
            .offerReceived(Self.copyHeader(token: Self.copyToken, count: 1, concealed: concealed)), on: link)
        try await link.changed.wait { link.pulls.count == inline }
        landing()
        for (order, id) in link.pulls {
            switch order.landing {
            case .memory:
                rig.clipboard.exchange.pullEnded(id, .landed(.inline(text)))
            case .staged(let directory, .exactly(let name)):
                try text.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
                rig.clipboard.exchange.pullEnded(id, .landed(.named(name)))
            case .staged, .exactPath:
                Issue.record("landing \(order.landing)")
            }
        }
    }

    @Test("A host copy's text, written as data, leaves no staged file behind")
    func writtenInlineLandingLeavesNoStagedFile() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        try await receiveCopy(Self.textItem(), text: Data("from the host".utf8), on: rig, link)
        let order = try #require(link.orders.first)
        guard case .staged(let directory, _) = order.landing else {
            Issue.record("landing \(order.landing)")
            return
        }

        try await link.changed.wait { link.releases.contains(Self.copyToken) }
        #expect(
            rig.pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("from the host".utf8))
        #expect(!FileManager.default.fileExists(atPath: directory))
    }

    @Test("A host copy the pasteboard refuses to take is refused WRITE_FAILED, and the paste shown failed")
    func refusedCopyWriteIsShown() async throws {
        let noticed = AsyncGate()
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: staging.root, onNotice: { noticed.notify() })
        let rig = Rig(pasteboard: pasteboard, clipboard: clipboard)
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        clipboard.setLink(link)
        pasteboard.failNextWrite()
        try await receiveCopy(Self.textItem(), text: Data("too large for the pasteboard".utf8), on: rig, link)

        try await link.changed.wait { !link.refusals.isEmpty }
        #expect(link.refusals.map(\.code) == [.writeFailed])
        try await noticed.wait { clipboard.activity == .pasteRefused(.pasteFailed, pasteLimitBytes: nil) }
        #expect(AgentMenuText.clipboardLine(clipboard.activity) == "Clipboard: paste failed")
    }

    @Test("A host offer the pasteboard refuses to take is let go, and the paste shown failed")
    func refusedOfferWriteIsShown() async throws {
        let noticed = AsyncGate()
        let pasteboard = FakePasteboard()
        let clipboard = GuestClipboard(
            pasteboard: pasteboard, stagingRoot: staging.root, onNotice: { noticed.notify() })
        let link = RecordingLink(items: [Self.textItem()])
        clipboard.setLink(link)
        pasteboard.failNextWrite()
        clipboard.exchange.handle(
            .offerReceived(ItemSetHeaderValue(feature: .clipboard, token: Self.hostToken, concealed: false, count: 1)),
            on: link)

        try await link.changed.wait { link.releases == [Self.hostToken] }
        try await noticed.wait { clipboard.activity == .pasteRefused(.pasteFailed, pasteLimitBytes: nil) }
    }

    @Test(
        "The host's ask leaves out a file the agent cannot open, and says how many; of only such files, it is refused READ_FAILED"
    )
    func askLeavesOutUnreadableFiles() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        let readable = try guestFile()
        let locked = scratch.url.appendingPathComponent("locked.jpeg")
        try Data("locked".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        #expect(rig.pasteboard.setFiles([readable, locked]))
        rig.clipboard.exchange.handle(.offerReceived(Self.askHeader), on: link)
        try await link.changed.wait { link.releases == [Self.askToken] }
        let copy = try #require(link.offers.last { $0.copy == .snapshot })
        #expect(copy.items.count == 1)
        #expect(copy.leftOut == 1)

        #expect(rig.pasteboard.setFiles([locked]))
        let only = Data(repeating: 5, count: 16)
        rig.clipboard.exchange.handle(
            .offerReceived(
                ItemSetHeaderValue(feature: .clipboard, token: only, concealed: false, count: 0, copy: .ask)),
            on: link)
        try await link.changed.wait { link.refusals.contains { $0.token == only } }
        #expect(link.refusals.first { $0.token == only }?.code == .readFailed)
        #expect(rig.clipboard.activity == .copyCarriedNothing)
    }

    @Test("The host's ask of an item whose file the agent cannot open crosses as its image data, its file left out")
    func askOfAnUnreadableFileItemSendsItsData() async throws {
        let rig = rig()
        let link = RecordingLink()
        rig.clipboard.setOnConsole(true)
        rig.clipboard.setLink(link)
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
        let locked = scratch.url.appendingPathComponent("derivative.jpeg")
        try Data("locked".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

        // A Photos copy's shape: image data beside a file URL into a library the agent cannot read.
        #expect(
            rig.pasteboard.setItem([
                (type: NSPasteboard.PasteboardType("public.jpeg"), data: Data("jpeg".utf8)),
                (type: .fileURL, data: Data(locked.absoluteString.utf8)),
                (type: NSPasteboard.PasteboardType("NSFilenamesPboardType"), data: Data(locked.path.utf8)),
            ]))
        rig.clipboard.exchange.handle(.offerReceived(Self.askHeader), on: link)
        try await link.changed.wait { link.releases == [Self.askToken] }
        let copy = try #require(link.offers.last { $0.copy == .snapshot })
        #expect(copy.leftOut == 1)
        #expect(copy.items.map { $0.representations.compactMap(\.type.appleUTI) } == [["public.jpeg"]])
        #expect(rig.clipboard.activity == .copyPartlyCarried(skipped: 1))
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

    /// Has the host send its concealed copy of text, landing it, and waits for the guest's write of it, which is
    /// held: not released.
    private func receiveConcealedCopy(_ rig: Rig, _ link: RecordingLink) async throws {
        try await receiveCopy(Self.textItem(), text: Data("hunter2-mac".utf8), concealed: true, on: rig, link)
        try await rig.pasteboard.changed.wait { !rig.pasteboard.dataByItem.isEmpty }
        #expect(
            rig.pasteboard.dataByItem == [
                [
                    NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI): Data("hunter2-mac".utf8),
                    NSPasteboard.PasteboardType(ClipboardSnapshotPolicy.concealedMarkerUTI): Data(),
                ]
            ])
        await drainMainQueue()
        #expect(!link.releases.contains(Self.copyToken))
    }

    @Test(
        "The Mac's clipboard moving on from its concealed copy clears the guest's write of it, pasted or not, unannounced",
        arguments: [false, true])
    func concealedHostCopyGoesWhenTheMacsClipboardMovesOn(pasted: Bool) async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        try await receiveConcealedCopy(rig, link)
        if pasted { #expect(rig.pasteboard.items.first?.data(forType: .string) == Data("hunter2-mac".utf8)) }
        let before = rig.clipboard.activity

        rig.clipboard.exchange.handle(
            .offerEnded(.clipboard, .remote, token: Self.copyToken, .resetByPeer(WireError(.clipboardChanged))),
            on: link)
        #expect(rig.pasteboard.items.isEmpty)
        #expect(rig.clipboard.activity == before)
        #expect(!rig.clipboard.activity.isNotice)
    }

    @Test("The host withdrawing its concealed copy, what its files came from having ended, says the Mac withdrew it")
    func concealedHostCopyWithdrawnIsSaid() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        try await receiveConcealedCopy(rig, link)

        rig.clipboard.exchange.handle(
            .offerEnded(.clipboard, .remote, token: Self.copyToken, .resetByPeer(WireError(.cancelled))), on: link)
        #expect(rig.pasteboard.items.isEmpty)
        #expect(rig.clipboard.activity == .copyWithdrawn(filesOnly: false))
    }

    /// A text item beside a file of `size` bytes.
    private static func textAndFileItem(fileSize size: UInt64) -> OfferedItem {
        var item = textAndFileItem()
        item.representations[1].sizeEstimate = size
        return item
    }

    @Test("A host copy of text and files over the paste ceiling is written without the files, and the host told so")
    func hostCopyLeavesOutOversizeFiles() async throws {
        let rig = rig()
        let item = Self.textAndFileItem(fileSize: 3 << 30)
        let link = RecordingLink(items: [item], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        try await receiveCopy(item, text: Data("from the host".utf8), on: rig, link)

        try await link.changed.wait { !link.refusals.isEmpty }
        #expect(link.refusals.map(\.code) == [.clipboardFilesWithheld])
        #expect(
            rig.pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("from the host".utf8))
        #expect(rig.pasteboard.promisedTypes.isEmpty)
    }

    /// Lands `text` as the INLINE pull `index` of `link` opened.
    private func land(_ text: String, pull index: Int, on rig: Rig, _ link: RecordingLink) throws {
        guard case .staged(let directory, .exactly(let name)) = link.orders[index].landing else {
            Issue.record("landing \(link.orders[index].landing)")
            return
        }
        try Data(text.utf8).write(
            to: URL(fileURLWithPath: directory).appendingPathComponent(String(decoding: name, as: UTF8.self)))
        rig.clipboard.exchange.pullEnded(link.opened[index], .landed(.named(name)))
    }

    @Test("A host copy arriving while an earlier one lands supersedes it: the earlier one never writes, landed late")
    func newerHostCopySupersedesTheLanding() async throws {
        let rig = rig()
        let link = RecordingLink(items: [Self.textItem()], sink: ItemSinkAdapter(fileSystem: POSIXTreeFileSystem()))
        rig.clipboard.setLink(link)
        let second = Data(repeating: 8, count: 16)
        rig.clipboard.exchange.handle(.offerReceived(Self.copyHeader(token: Self.copyToken, count: 1)), on: link)
        try await link.changed.wait { link.opened.count == 1 }
        // The Mac's clipboard changed and the user clicked again: the second copy ends the first's landing.
        rig.clipboard.exchange.handle(.offerReceived(Self.copyHeader(token: second, count: 1)), on: link)
        try await link.changed.wait { link.opened.count == 2 }
        #expect(link.refusals.map(\.token) == [Self.copyToken])
        #expect(link.refusals.map(\.code) == [.itemOfferReplaced])

        // The newer, small copy lands first and is written; the older, slow one lands after and writes nothing.
        try land("second, newer", pull: 1, on: rig, link)
        try await link.changed.wait { link.releases.contains(second) }
        let written = rig.pasteboard.changeCount
        try land("first, older", pull: 0, on: rig, link)
        await drainMainQueue()
        #expect(rig.pasteboard.changeCount == written)
        #expect(
            rig.pasteboard.dataByItem.first?[NSPasteboard.PasteboardType(ClipboardContent.utf8TextUTI)]
                == Data("second, newer".utf8))
        #expect(link.refusals.count == 1)
    }
}
