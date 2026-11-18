import AppKit
import Foundation
import KernovaAgentCore
import KernovaClipboardItems
import KernovaKit
import KernovaSynchronization
import KernovaTestSupport
import KernovaWire
import Testing

/// One side's clipboard end: what the host takes of the guest's offers under its gate, the host's request for the
/// guest's clipboard, and the passthrough poll and publish behaviors, each over a fake pasteboard and an in-memory
/// connection the test steps.
@Suite("ClipboardEnd", .caseScoped)
@MainActor
struct ClipboardEndTests {
    private let staging = TestStagingRoot()
    private let scratch = TestScratchDirectory(prefix: "clipboard-end")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    private static func token(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }

    /// An item of one INLINE representation of `uti`.
    private static func item(
        _ uti: String, _ storage: Representation.Storage = .inline, name: String = "", size: UInt64 = 0
    )
        -> OfferedItem
    {
        var representation = Representation()
        representation.type = TypeDescriptor(appleUTI: uti)
        representation.storage = storage
        representation.name = Data(name.utf8)
        representation.sizeEstimate = size
        var item = OfferedItem()
        item.representations = [representation]
        return item
    }

    /// The item a copy of `name` by ``ClipboardEndPair/copy(_:on:)`` offers.
    private static func copyItem(_ name: String) -> OfferedItem { item("com.kernova.test.copy.\(name)") }

    /// The far side opens `offer` straight on the wire, as a guest end of any build could, and everything toward
    /// the host reaches it: the withdrawal of the far side's offer before, then `offer`.
    private func guestOffers(_ offer: ItemOffer, on pair: ClipboardEndPair) async throws {
        let wire = try #require(pair.wire)
        wire.link(.guest).offerItems(offer) { _ in }
        try await pair.settle()
        while wire.deliverNext(toward: .host) != nil { try await pair.settle() }
    }

    private func readOutcomes(_ pair: ClipboardEndPair, _ side: ClipboardWire.Side) -> [ClipboardReadOutcome] {
        (pair.events[side] ?? []).compactMap { if case .readEnded(_, let outcome) = $0 { outcome } else { nil } }
    }

    private func requestRefusals(_ pair: ClipboardEndPair) -> [ClipboardItemExchange.RequestRefusal] {
        (pair.events[.host] ?? []).compactMap { if case .requestRefused(let refusal) = $0 { refusal } else { nil } }
    }

    // MARK: - What the host takes

    @Test("On command, the host refuses unread a guest offer naming no request, or a request it no longer has open")
    func hostRefusesWhatItDidNotAskFor() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .onCommand)
        let wire = try #require(pair.wire)
        let refusal = WireError(.disabledByPolicy)

        try await guestOffers(ItemOffer(token: Self.token(1), items: [Self.copyItem("unasked")]), on: pair)
        #expect(wire.queue(toward: .guest).contains(.refused(token: Self.token(1), error: refusal)))

        pair.host.requestOffer()
        pair.host.requestOffer()
        try await pair.settle()
        let requests = wire.requests
        try #require(requests.count == 2)
        try await guestOffers(
            ItemOffer(token: Self.token(2), items: [Self.copyItem("stale")], request: requests[0]), on: pair)
        #expect(wire.queue(toward: .guest).contains(.refused(token: Self.token(2), error: refusal)))
        #expect(wire.itemReads(.host) == 0)
        #expect(pair.holding(.host) == .nothing)

        try await guestOffers(
            ItemOffer(token: Self.token(3), items: [Self.copyItem("answer")], request: requests[1]), on: pair)
        #expect(pair.holding(.host) == .write("answer"))
    }

    @Test(
        "At every copy, the host takes a guest offer naming no request, and refuses unread an answer to no open request"
    )
    func hostAtEveryCopyStillRefusesAStaleAnswer() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let wire = try #require(pair.wire)

        try await guestOffers(
            ItemOffer(token: Self.token(1), items: [Self.copyItem("stale")], request: Self.token(9)), on: pair)
        #expect(
            wire.queue(toward: .guest).contains(.refused(token: Self.token(1), error: WireError(.disabledByPolicy))))
        #expect(wire.itemReads(.host) == 0)
        #expect(pair.holding(.host) == .nothing)

        try await guestOffers(ItemOffer(token: Self.token(2), items: [Self.copyItem("copied")]), on: pair)
        #expect(pair.holding(.host) == .write("copied"))
    }

    // MARK: - Copy to Mac

    @Test(
        "Copy to Mac: an empty guest clipboard is nothing to copy, the host's own offer there is silent, a copy answers"
    )
    func copyToMacOutcomes() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .onCommand)
        let wire = try #require(pair.wire)
        func ask() async throws {
            pair.host.requestOffer()
            try await pair.settle()
            wire.deliverNext(toward: .guest)
            try await pair.settle()
            while wire.deliverNext(toward: .host) != nil { try await pair.settle() }
        }

        try await ask()
        #expect(pair.events[.host]?.last == .requestRefused(.nothingToCopy))

        pair.copy("mac", on: .host)
        pair.host.offerOnCommand()
        try await pair.settle()
        wire.deliverNext(toward: .guest)
        try await pair.settle()
        #expect(pair.holding(.guest) == .write("mac"))
        let heard = pair.events[.host]?.count
        try await ask()
        #expect(pair.events[.host]?.count == heard)
        #expect(pair.holding(.host) == .user("mac"))

        pair.copy("guest", on: .guest)
        try await ask()
        #expect(pair.holding(.host) == .write("guest"))
    }

    @Test(
        "Copy to Mac takes the guest's answer after a Copy to Guest the Mac's clipboard moved on from while it opened, which the guest took"
    )
    func copyToMacAfterACopyToGuestWithdrawnWhileItOpened() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .onCommand, holdsSteps: true)
        let wire = try #require(pair.wire)
        func step(_ act: () -> Void) async throws {
            act()
            try await pair.settle()
            while pair.landRead(on: .host) || pair.landRead(on: .guest) { try await pair.settle() }
        }
        func answer(_ side: ClipboardWire.Side) async throws {
            while !wire.unansweredOpens(side).isEmpty { try await step { wire.answerOldestOpen(of: side) } }
        }
        func deliver(toward side: ClipboardWire.Side) async throws {
            while !wire.queue(toward: side).isEmpty { try await step { wire.deliverNext(toward: side) } }
        }

        // A Copy to Guest the guest takes.
        pair.copy("first", on: .host)
        try await step { pair.host.offerOnCommand() }
        try await answer(.host)
        try await deliver(toward: .guest)
        #expect(pair.holding(.guest) == .write("first"))

        // Another, which the Mac's clipboard moves on from while it opens; the guest takes it, then its withdrawal.
        try await step { pair.host.offerOnCommand() }
        pair.copy("second", on: .host)
        try await step { pair.poll() }
        try await deliver(toward: .guest)
        #expect(pair.holding(.guest) == .write("first"))
        try await answer(.host)
        try await deliver(toward: .guest)
        #expect(pair.holding(.guest) == .nothing)

        pair.copy("guest", on: .guest)
        try await step { pair.host.requestOffer() }
        try await deliver(toward: .guest)
        try await answer(.guest)
        try await deliver(toward: .host)
        #expect(pair.holding(.host) == .write("guest"))
    }

    @Test("Copy to Mac whose answer the host's item registry resets over budget is refused, once")
    func copyToMacAnswerOverBudgetIsRefused() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .onCommand, holdsSteps: true)
        let wire = try #require(pair.wire)
        pair.copy("guest", on: .guest)
        pair.host.requestOffer()
        try await pair.settle()
        wire.deliverNext(toward: .guest)
        try await pair.settle()
        while pair.landRead(on: .guest) { try await pair.settle() }
        try #require(wire.unansweredOpens(.guest).count == 1)
        // The host's registry resets the answer at its OPEN; the guest hears its answer opened and releases the
        // request.
        wire.refuseOverBudget(toward: .host)
        try await pair.settle()
        wire.answerOldestOpen(of: .guest)
        try await pair.settle()
        while wire.deliverNext(toward: .host) != nil { try await pair.settle() }
        while wire.deliverNext(toward: .guest) != nil { try await pair.settle() }

        #expect(pair.holding(.host) == .nothing)
        #expect(requestRefusals(pair) == [.failed(WireError(.tooLarge))])
    }

    @Test("Copy to Mac whose request the guest releases with no answer arriving is refused, once")
    func copyToMacReleasedUnansweredIsRefused() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .onCommand, holdsSteps: true)
        let wire = try #require(pair.wire)
        pair.host.requestOffer()
        try await pair.settle()
        let request = try #require(wire.requests.last)
        wire.deliverNext(toward: .guest)
        try await pair.settle()
        // A guest end of any build releases the request, its answer never reaching the host's registry.
        wire.link(.guest).releaseOffer(request)
        try await pair.settle()
        while wire.deliverNext(toward: .host) != nil { try await pair.settle() }

        #expect(requestRefusals(pair).count == 1)
        guard case .failed(let error)? = requestRefusals(pair).first else {
            Issue.record("refusals: \(requestRefusals(pair))")
            return
        }
        #expect(error.code == .cancelled)
    }

    enum AnswerLoss: CaseIterable, CustomStringConvertible, Sendable {
        case linkDrops, guestWithdraws

        var description: String { self == .linkDrops ? "the link drops" : "the guest withdraws it" }
    }

    @Test(
        "Copy to Mac whose answer arrived whole is refused, once, when the answer ends before the host read it",
        arguments: AnswerLoss.allCases)
    func copyToMacAnswerLostWhileReadIsRefused(loss: AnswerLoss) async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .onCommand)
        let wire = try #require(pair.wire)
        pair.copy("guest", on: .guest)
        pair.host.requestOffer()
        try await pair.settle()
        wire.deliverNext(toward: .guest)
        try await pair.settle()
        try #require(wire.queue(toward: .host).count == 2, "the answer, then the request's release")
        if loss == .guestWithdraws {
            pair.copy("next", on: .guest)
            pair.poll()
        }
        // Each arrives before the host's read of the answer's items lands.
        while wire.deliverNext(toward: .host) != nil {}
        if loss == .linkDrops { pair.linkDown() }
        try await pair.settle()

        #expect(pair.holding(.host) == .nothing)
        #expect(requestRefusals(pair).count == 1)
    }

    // MARK: - File grants

    @Test("A copied file's grant lasts while the clipboard holds the copy, past its offer, and goes once it moves on")
    func copiedFileGrantLastsWhileTheCopyStands() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .onCommand)
        let copied = scratch.url.appendingPathComponent("copied.txt")
        try Data("copied".utf8).write(to: copied)
        let sandbox = pair.hostPasteboard.sandbox
        pair.hostPasteboard.setFiles([copied])

        pair.host.offerOnCommand()
        try await pair.settle()
        #expect(sandbox.grants(of: copied) == 1)

        // The offer ends with the connection; the copy, read again, can take no grant of its own.
        pair.linkDown()
        try await pair.settle()
        #expect(sandbox.grants(of: copied) == 1)
        pair.linkUp()
        pair.host.offerOnCommand()
        try await pair.settle()
        #expect(readOutcomes(pair, .host) == [.offered(skipped: 0), .offered(skipped: 0)])
        #expect(sandbox.grants(of: copied) == 1)

        pair.copy("text", on: .host)
        pair.poll()
        try await pair.settle()
        try await sandbox.changed.wait { sandbox.grants(of: copied) == 0 }
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    // MARK: - The poll

    @Test("A copied zero-byte file is offered like any other, with nothing left out")
    func zeroByteFileIsOffered() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let empty = scratch.url.appendingPathComponent("empty.txt")
        try Data().write(to: empty)
        pair.hostPasteboard.setFiles([empty])
        pair.poll()
        try await pair.settle()

        let offer = try #require(pair.wire?.opened(.host).last)
        let files = offer.items.flatMap(\.representations).filter { $0.storage != .inline }
        #expect(files.map { String(decoding: $0.name, as: UTF8.self) } == ["empty.txt"])
        #expect(files.first?.sizeEstimate == 0)
        #expect(readOutcomes(pair, .host) == [.offered(skipped: 0)])
    }

    @Test("A copy whose every file vanished before the poll offers nothing, and says none could be read")
    func vanishedFilesAreUnreadable() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let doomed = scratch.url.appendingPathComponent("doomed.txt")
        try Data("doomed".utf8).write(to: doomed)
        pair.hostPasteboard.setFiles([doomed])
        try FileManager.default.removeItem(at: doomed)
        pair.poll()
        try await pair.settle()

        #expect(pair.wire?.opened(.host).isEmpty == true)
        #expect(readOutcomes(pair, .host) == [.unreadable])
    }

    @Test("Each copy losing the same item says so again, not folded into the one before")
    func eachPartialCopySaysSo() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let kept = scratch.url.appendingPathComponent("kept.txt")
        let doomed = scratch.url.appendingPathComponent("doomed.txt")
        try Data("kept".utf8).write(to: kept)
        for _ in 0..<2 {
            pair.hostPasteboard.setFiles([kept, doomed])
            pair.poll()
            try await pair.settle()
        }
        #expect(readOutcomes(pair, .host) == [.offered(skipped: 1), .offered(skipped: 1)])
        #expect(pair.wire?.opened(.host).count == 2)
    }

    @Test("A poll while a copy is read starts no second read of it, and a settled copy is not offered again")
    func pollDuringReadReadsOnce() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let file = scratch.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        pair.hostPasteboard.setFiles([file])
        pair.poll()
        pair.poll()
        try await pair.settle()
        pair.poll()
        try await pair.settle()

        #expect(pair.events[.host]?.filter { $0 == .readBegan(.copy) }.count == 1)
        #expect(pair.wire?.opened(.host).count == 1)
    }

    @Test("A read the pasteboard outran offers nothing, and the copy that replaced it is offered at the next poll")
    func outrunReadOffersNothing() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let file = scratch.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        pair.hostPasteboard.setFiles([file])
        pair.poll()
        pair.copy("over", on: .host)
        try await pair.settle()
        #expect(pair.wire?.opened(.host).isEmpty == true)

        pair.poll()
        try await pair.settle()
        #expect(pair.wire?.opened(.host).map { ClipboardEndPair.name(of: $0.items) } == ["over"])
    }

    @Test(
        "A read outliving the gate it began under offers nothing, turning passthrough on offers nothing standing, and the next copy is offered"
    )
    func readOutlivingItsGateOffersNothing() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let file = scratch.url.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        pair.hostPasteboard.setFiles([file])
        pair.poll()
        pair.host.setGate(.onCommand)
        pair.host.setGate(.everyCopy)
        pair.poll()
        try await pair.settle()
        #expect(pair.wire?.opened(.host).isEmpty == true)

        pair.copy("after", on: .host)
        pair.poll()
        try await pair.settle()
        #expect(pair.wire?.opened(.host).map { ClipboardEndPair.name(of: $0.items) } == ["after"])
    }

    // MARK: - Publishing the far side's offer

    /// A pair whose host took a guest offer of a 1 GiB file — beside text when `alongsideText` — under a 512 MiB
    /// paste ceiling, which left the file off the host's pasteboard.
    private func cutByTheCeiling(alongsideText: Bool) async throws -> (ClipboardEndPair, Locked<Int>) {
        let ceiling = Locked(512 * 1024 * 1024)
        let pair = ClipboardEndPair(
            staging: staging.root, gate: .everyCopy, pasteCeiling: { ceiling.withLock { $0 } })
        let file = Self.item("public.data", .file, name: "big.bin", size: 1 << 30)
        let items = alongsideText ? [Self.item(NSPasteboard.PasteboardType.string.rawValue), file] : [file]
        try await guestOffers(ItemOffer(token: Self.token(1), items: items), on: pair)
        #expect(!pair.hostPasteboard.promisedTypes.contains(.fileURL))
        return (pair, ceiling)
    }

    @Test("Raising the ceiling writes the offer the old one cut again, with its file", arguments: [false, true])
    func raisingTheCeilingWritesAgain(alongsideText: Bool) async throws {
        let (pair, ceiling) = try await cutByTheCeiling(alongsideText: alongsideText)
        ceiling.withLock { $0 = 16 * 1024 * 1024 * 1024 }
        pair.host.pasteCeilingChanged()
        #expect(pair.hostPasteboard.promisedTypes.contains(.fileURL))
    }

    @Test("A ceiling raised over what the user has copied since leaves their copy alone")
    func raisingTheCeilingSparesTheUsersCopy() async throws {
        let (pair, ceiling) = try await cutByTheCeiling(alongsideText: true)
        pair.copy("mine", on: .host)
        let heard = pair.events[.host]?.count
        ceiling.withLock { $0 = 16 * 1024 * 1024 * 1024 }
        pair.host.pasteCeilingChanged()
        #expect(pair.events[.host]?.count == heard)
        #expect(pair.holding(.host) == .user("mine"))
    }

    @Test("The guest's offer is written promised, moving no bytes until a paste pulls them")
    func farSideOfferMovesNoBytesUntilPasted() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let wire = try #require(pair.wire)
        pair.copy("words", on: .guest)
        pair.poll()
        try await pair.settle()
        wire.deliverNext(toward: .host)
        try await pair.settle()
        let type = NSPasteboard.PasteboardType("com.kernova.test.copy.words")
        #expect(pair.hostPasteboard.promisedTypes == [type])
        #expect(wire.pulls(.host) == 0)

        let board = pair.hostPasteboard
        let pasted = try await offCooperativePool { board.invokeProvider(forType: type) }
        #expect(pasted == Data("words".utf8))
        #expect(wire.pulls(.host) == 1)
    }

    @Test("Every promise of a copy holding more than staging keeps generations stays called in while its offer serves")
    func everyPromiseOfOneOfferStays() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let receivers = (0...ClipboardFileStaging.maxGenerations).map { index in
            FakeFilePromiseReceiver(
                name: "\(index).png", fileType: "public.png", contents: .file(Data("\(index)".utf8)))
        }
        pair.hostPasteboard.setFilePromises(receivers)
        pair.poll()
        try await pair.settle()
        let offer = try #require(pair.wire?.opened(.host).last)
        try #require(offer.items.count == receivers.count)

        var served: [String] = []
        let host = pair.host
        for item in offer.items.indices {
            var pull = PullRequest()
            pull.token = offer.token
            pull.item = UInt32(item)
            let request = pull
            let id = ItemPullID(
                generation: ConnectionGeneration(rawValue: 1), stream: StreamID(rawValue: UInt32(2 * item + 2)))
            guard case .success(.tree(let path)) = try await offCooperativePool({ host.content(id, request) }) else {
                Issue.record("item \(item) was not served")
                return
            }
            served.append(path)
        }
        for (index, path) in served.enumerated() {
            #expect(FileManager.default.contents(atPath: path) == Data("\(index)".utf8), "item \(index)")
        }
    }

    // MARK: - What a copy carries

    @Test("A Photos copy whose file cannot be opened crosses as its image data, its file left out and counted")
    func photosCopyCrossesAsItsData() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let wire = try #require(pair.wire)
        let derivative = scratch.url.appendingPathComponent("derivative.jpeg")
        try Data("derivative".utf8).write(to: derivative)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: derivative.path)
        #expect(pair.guestPasteboard.setItem(ClipboardPasteboardReaderTests.photosCopy(naming: derivative)))
        pair.poll()
        try await pair.settle()
        #expect(readOutcomes(pair, .guest) == [.offered(skipped: 1)])

        wire.deliverNext(toward: .host)
        try await pair.settle()
        let jpeg = NSPasteboard.PasteboardType("public.jpeg")
        let tiff = NSPasteboard.PasteboardType("public.tiff")
        let promised = pair.hostPasteboard.promisedTypes
        #expect(promised.contains(jpeg) && promised.contains(tiff))
        #expect(!promised.contains(.fileURL))
        let board = pair.hostPasteboard
        #expect(try await offCooperativePool { board.invokeProvider(forType: jpeg) } == Data("jpeg".utf8))
        #expect(try await offCooperativePool { board.invokeProvider(forType: tiff) } == Data("tiff".utf8))
    }

    @Test(
        "A copy holding nothing a pasteboard carries offers nothing, told apart from an empty clipboard, and a request for it is nothing to copy"
    )
    func uncarriableCopyIsToldApart() async throws {
        let pair = ClipboardEndPair(staging: staging.root, gate: .everyCopy)
        let wire = try #require(pair.wire)
        // A Finder node, which names a file on this machine, is never offered.
        let node = NSPasteboard.PasteboardType("com.apple.finder.node")
        pair.guestPasteboard.setItem([(type: node, data: Data("node".utf8))])
        pair.poll()
        try await pair.settle()
        #expect(readOutcomes(pair, .guest) == [.nothingCarriable])
        #expect(wire.opened(.guest).isEmpty)

        pair.setGate(.onCommand, on: .host)
        pair.setGate(.onCommand, on: .guest)
        pair.host.requestOffer()
        try await pair.settle()
        wire.deliverNext(toward: .guest)
        try await pair.settle()
        while wire.deliverNext(toward: .host) != nil { try await pair.settle() }
        #expect(readOutcomes(pair, .guest) == [.nothingCarriable, .nothingCarriable])
        #expect(pair.events[.host]?.last == .requestRefused(.nothingToCopy))

        pair.guestPasteboard.clearContents()
        pair.host.requestOffer()
        try await pair.settle()
        wire.deliverNext(toward: .guest)
        try await pair.settle()
        #expect(readOutcomes(pair, .guest).last == .nothingToCopy)
    }
}
