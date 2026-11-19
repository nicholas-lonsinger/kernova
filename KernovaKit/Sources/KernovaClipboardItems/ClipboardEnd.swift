import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaKit
import KernovaLogging
import KernovaWire

/// One side's whole clipboard over the agent connection, the same at the host and a guest agent: its pasteboard,
/// the one publisher writing the far side's offers there, and the exchange carrying both sides' offers.
///
/// What crosses is always a live offer, read as metadata and pulled at paste. The gate decides only when this side
/// offers (``ClipboardOfferGate``): every read that offers starts from a trigger the gate admits — a copy the poll
/// saw, this side's command, or the host's request — and from there every offer is the same. An offer lives while
/// the pasteboard it was read from holds what it was read from, so a later copy withdraws it in either gate, and
/// the far side retracts its write; a copy over the far side's write lets the far side's offer go. Changing the gate
/// ends every offer of either side's this end sent or took, and so does the connection's end; nothing is sent
/// again when either returns.
@MainActor
public final class ClipboardEnd<Role: ClipboardEndRole> {
    /// Hears what this end does that its owner reports or shows.
    public var onEvent: ((ClipboardEndEvent) -> Void)?

    private let pasteboard: any ClipboardPasteboard
    private let publisher: ClipboardPasteboardPublisher
    private let exchange: ClipboardItemExchange
    /// Where a file promise copied here is called in when the far side pulls an offer of it: each read's in a
    /// generation of its own, so every promise one offer called in stays while that offer can serve it.
    private let promiseStaging: ClipboardFileStaging
    private var nextPromiseGeneration: UInt64 = 1
    private let pasteCeiling: @Sendable () -> Int
    private let logger: KernovaLogger
    private var mayOffer = false
    /// The connection that carries the clipboard now, whose item calls the exchange makes.
    private var link: Role.Link?

    /// The poll for copies, which exists exactly while a connection carries the clipboard, the gate is
    /// ``ClipboardOfferGate/everyCopy`` and this side may offer: what every setter of those rebuilds.
    private var poll: Poll?
    private var read: Read?
    private var nextRead = 0
    /// The far side's offer this end wrote, or held back over the paste ceiling, while it is this end's clipboard.
    private var published: Publication?
    private var nextPublication = 0
    /// The grants of access to the files of the pasteboard generation this end read last that its offer reaches by
    /// their paths, held while the pasteboard stands at it: reading it again takes none (``PasteboardFileAccess``), so
    /// a later read of the same copy — a command, or one after the connection returns — still reaches them.
    private var lastRead: (access: PasteboardFileAccess, watch: ClipboardPasteboardWatch.Observation)?

    private struct Poll {
        let observation: ClipboardPasteboardWatch.Observation
        /// The change count the poll is done with: one it read and found standing when the read landed, this
        /// end's own write, or the count it started at.
        var settled: Int
    }

    private enum Trigger {
        case copy
        case command
        case request(ClipboardItemExchange.OfferRequest)

        var reported: ClipboardOfferTrigger {
            switch self {
            case .copy: .copy
            case .command: .command
            case .request: .request
            }
        }
    }

    /// The one read of the pasteboard in flight, of the pasteboard as it stood at `changeCount`.
    private struct Read {
        let id: Int
        let trigger: Trigger
        let changeCount: Int
    }

    private struct Publication {
        let remote: ClipboardRemoteOffer
        /// Tells this publication's write from a later one of the same offer.
        let id: Int
        /// The paste ceiling its write was cut under — files left out, or nothing written — and the change count
        /// the pasteboard stood at then: what ``ClipboardEnd/pasteCeilingChanged()`` publishes it again over.
        var cut: (ceiling: Int, changeCount: Int)?
    }

    /// An end over `pasteboard` offering as `gate` says, its writes' providers held by `providerRegistry` and
    /// recorded in `ledger`, landing the far side's representations, and calling in its own copied promises, in
    /// clipboard staging labelled `stagingLabel` under `stagingRoot`, under the paste ceiling `pasteCeiling` reads
    /// each time it is needed. It offers nothing until a connection carries the clipboard and it may offer.
    public init(
        pasteboard: any ClipboardPasteboard, gate: ClipboardOfferGate, stagingLabel: String,
        stagingRoot: ProcessStagingRoot, pasteCeiling: @escaping @Sendable () -> Int,
        providerRegistry: LazyClipboardProviderRegistry = .shared, ledger: ClipboardWriteLedger = .shared,
        logger: KernovaLogger
    ) {
        self.pasteboard = pasteboard
        self.pasteCeiling = pasteCeiling
        self.logger = logger
        publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: providerRegistry, ledger: ledger)
        exchange = ClipboardItemExchange(
            side: Role.side, gate: gate, stagingLabel: stagingLabel, stagingRoot: stagingRoot,
            pasteCeiling: pasteCeiling, logger: logger)
        promiseStaging = ClipboardFileStaging(label: "\(stagingLabel)-promises", root: stagingRoot)
        exchange.onRemoteOffer = { [weak self] in self?.publish($0) }
        exchange.onRemoteOfferEnded = { [weak self] in self?.remoteEnded($0, $1) }
        exchange.holdsUnsentCopy = { [weak self] in self?.holdsUnsentCopy ?? false }
        exchange.onCrossingRefused = { [weak self] in self?.polled() }
        exchange.onOfferRequested = { [weak self] in self?.requested($0) }
        exchange.onRequestRefused = { [weak self] in self?.emit(.requestRefused($0)) }
        exchange.onServed = { [weak self] in self?.emit(.served) }
        exchange.onLanded = { [weak self] in self?.emit(.landed) }
        exchange.onPullFailed = { [weak self] in self?.emit(.pullFailed($0)) }
        publisher.onPasteRefused = { [weak self] in self?.emit(.pasteRefused) }
    }

    // MARK: Inputs

    /// Runs over `link` from now on, or over nothing: everything the connection before carried ends — the read in
    /// flight, both sides' offers, this end's write of the far side's, retracted as at a link's end — and the
    /// new one is offered only what is copied after it.
    public func setLink(_ link: Role.Link?) {
        voidRead(refusing: WireError(.cancelled, debugDetail: "the connection left"))
        self.link = link
        exchange.setLink(link.map { Role.itemCalls($0) })
        rearmPoll()
    }

    /// Offers as `gate` says from now on. A change ends what either side's offers carried: the read in flight,
    /// this side's offer and the far side's — this end's write of it retracted as at a link's end — and any request
    /// either side has open; turning passthrough on offers only what is copied after.
    public func setGate(_ gate: ClipboardOfferGate) {
        guard gate != exchange.gate else { return }
        logger.log(
            .notice,
            "The clipboard is offered \(gate == .everyCopy ? "at every copy" : "on command", privacy: .public) from now on"
        )
        voidRead(refusing: WireError(.disabledByPolicy))
        exchange.setGate(gate)
        rearmPoll()
    }

    /// Whether this side may offer — a guest's, while its session owns the console; the host may always. Losing it
    /// withdraws this side's offer `CAPABILITY_WITHDRAWN`; regaining it offers only what is copied after.
    public func setMayOffer(_ mayOffer: Bool) {
        guard mayOffer != self.mayOffer else { return }
        self.mayOffer = mayOffer
        if !mayOffer {
            voidRead(refusing: WireError(.clipboardNothingToCopy))
            exchange.withdrawLocal(.capabilityWithdrawn)
        }
        rearmPoll()
    }

    /// The paste ceiling may have risen: the far side's offer a lower one cut is written again, whole, while it is
    /// still this end's clipboard and nothing has written this pasteboard since.
    public func pasteCeilingChanged() {
        guard let published, let cut = published.cut, pasteCeiling() > cut.ceiling,
            pasteboard.changeCount == cut.changeCount
        else { return }
        logger.log(.notice, "The paste ceiling rose: the far side's clipboard it cut is written again")
        publish(published.remote)
    }

    // MARK: The connection's events

    /// Hands `event`, of the connection `link` names, to this end; a pull's end goes to ``pullEnded(_:_:)``.
    public func handle(_ event: ItemTransferEvent, on link: Role.Link) {
        exchange.handle(event, on: Role.itemCalls(link))
    }

    /// A pull of the far side's offer ended: handled where it arrives, on any queue.
    nonisolated public func pullEnded(_ id: ItemPullID, _ result: ItemPullResult) {
        exchange.pullEnded(id, result)
    }

    /// The content of the representation of this side's offer that pull `id`'s `request` pulls
    /// (``ClipboardItemExchange/content(_:_:)``), never asked on the main thread.
    nonisolated public func content(_ id: ItemPullID, _ request: PullRequest) -> Result<ItemContent, WireError> {
        exchange.content(id, request)
    }

    // MARK: Offering

    /// Polls for copies from the pasteboard's change count now while a connection carries the clipboard, the gate
    /// is ``ClipboardOfferGate/everyCopy`` and this side may offer, and not otherwise.
    private func rearmPoll() {
        poll = nil
        guard link != nil, exchange.gate == .everyCopy, mayOffer else { return }
        poll = Poll(
            observation: ClipboardPasteboardWatch.observe(pasteboard, in: .newCopies) { [weak self] in
                self?.polled()
            },
            settled: pasteboard.changeCount)
    }

    /// A poll: a change the poll is not done with, and not being read, is read and offered.
    private func polled() {
        guard let poll else { return }
        let current = pasteboard.changeCount
        guard current != publisher.lastWriteChangeCount else {
            self.poll?.settled = current
            return
        }
        guard current != poll.settled, read?.changeCount != current else { return }
        readAndOffer(.copy)
    }

    /// Whether the pasteboard holds a copy of the user's the poll is not done with — read now, or not read yet —
    /// which a far-side offer made meanwhile crosses and loses to.
    private var holdsUnsentCopy: Bool {
        guard let poll else { return false }
        let current = pasteboard.changeCount
        return current != poll.settled && current != publisher.lastWriteChangeCount && pasteboard.mayOfferSomething
    }

    /// The host asks for this side's clipboard: read and offered, unless this side may not offer.
    private func requested(_ request: ClipboardItemExchange.OfferRequest) {
        guard mayOffer else {
            exchange.refuseRequest(request, WireError(.clipboardNothingToCopy))
            return emit(.notAdmitted(.request))
        }
        readAndOffer(.request(request))
    }

    /// Reads the pasteboard as it stands and offers it, for a trigger the gate admits: the one way this end reads
    /// its pasteboard to offer it. A newer read replaces the one in flight.
    private func readAndOffer(_ trigger: Trigger) {
        switch (exchange.gate, trigger) {
        case (.everyCopy, .copy), (.onCommand, .command), (.onCommand, .request):
            break
        case (.onCommand, .copy):
            return
        case (.everyCopy, .command):
            return emit(.notAdmitted(.command))
        case (.everyCopy, .request(let request)):
            exchange.refuseRequest(request, WireError(.disabledByPolicy))
            return emit(.notAdmitted(.request))
        }
        voidRead(refusing: WireError(.itemOfferReplaced, debugDetail: "a newer read replaced it"))
        let id = nextRead
        nextRead += 1
        read = Read(id: id, trigger: trigger, changeCount: pasteboard.changeCount)
        emit(.readBegan(trigger.reported))
        let pasteboard = pasteboard
        let publisher = publisher
        let promises = pasteboard.filePromiseReceivers
        let promiseStaging = promiseStaging
        let promiseGeneration = nextPromiseGeneration
        nextPromiseGeneration += 1
        Task { @MainActor [weak self] in
            let outcome = await ClipboardPasteboardReader.readOffer(
                from: pasteboard, publisher: publisher, promises: promises,
                promiseDestination: { try promiseStaging.reserveScratchDirectory(generation: promiseGeneration) })
            #if DEBUG
            if let held = pasteboard as? any ClipboardTestHeldReadPasteboard { await held.readMayLandForTesting() }
            #endif
            if case .offer(let source, _) = outcome { self?.holdWhileStanding(source.fileAccess) }
            self?.landed(outcome, of: id)
        }
    }

    /// Holds `access`, a read's, in place of the last read's, until the pasteboard moves on from the generation it
    /// read.
    private func holdWhileStanding(_ access: PasteboardFileAccess?) {
        guard let access, access.standsOnItsPasteboard, lastRead?.access !== access else { return }
        let watch = ClipboardPasteboardWatch.observe(pasteboard, in: .standingWrites) { [weak self] in
            guard let self, let lastRead = self.lastRead, !lastRead.access.standsOnItsPasteboard else { return }
            self.lastRead = nil
        }
        lastRead = (access, watch)
    }

    /// Read `id` landed with `outcome`. One the pasteboard outran is dropped: the poll reads what replaced it, and
    /// a command or request, which offers the clipboard as it stands, reads again.
    private func landed(_ outcome: ClipboardPasteboardReader.OfferOutcome, of id: Int) {
        guard let read, read.id == id else { return }
        self.read = nil
        let trigger = read.trigger.reported
        guard pasteboard.changeCount == read.changeCount else {
            emit(.readEnded(trigger, .superseded))
            if case .copy = read.trigger { return }
            return readAndOffer(read.trigger)
        }
        if case .copy = read.trigger { poll?.settled = read.changeCount }
        let request: ClipboardItemExchange.OfferRequest? =
            if case .request(let request) = read.trigger { request } else { nil }
        switch outcome {
        case .offer(let source, let lost):
            let offered = exchange.offer(source, answering: request)
            emit(.readEnded(trigger, offered ? .offered(skipped: lost) : .superseded))
        case .empty, .suppressed:
            if let request { exchange.refuseRequest(request, WireError(.clipboardNothingToCopy)) }
            emit(.readEnded(trigger, .nothingToCopy))
        case .nothingOfferable(lost: 0):
            if let request { exchange.refuseRequest(request, WireError(.clipboardNothingToCopy)) }
            emit(.readEnded(trigger, .nothingCarriable))
        case .nothingOfferable:
            if let request { exchange.refuseRequest(request, WireError(.readFailed)) }
            emit(.readEnded(trigger, .unreadable))
        case .heldByFarSide:
            if let request { exchange.refuseRequest(request, WireError(.clipboardAlreadyHeld)) }
            emit(.readEnded(trigger, .heldByFarSide))
        }
    }

    /// Ends the read in flight, offering nothing of what it lands; the request it answers is refused with `error`.
    private func voidRead(refusing error: WireError) {
        guard let read else { return }
        self.read = nil
        if case .request(let request) = read.trigger { exchange.refuseRequest(request, error) }
        emit(.readEnded(read.trigger.reported, .superseded))
    }

    // MARK: The far side's offer

    /// Writes the far side's offer to the pasteboard, promised, within the paste ceiling: files over it are left
    /// out, and an offer of nothing else is not written but held, for a raised ceiling to write. The offer is
    /// let go once its write no longer stands — a copy over it, or a later write — or at once when nothing of it
    /// can be written.
    private func publish(_ remote: ClipboardRemoteOffer) {
        let id = nextPublication
        nextPublication += 1
        published = Publication(remote: remote, id: id)
        let outcome = publisher.publish(
            remote.items, concealed: remote.concealed, pasteCeiling: pasteCeiling(), puller: remote,
            serving: remote.token, onReleased: { [weak self] in self?.writeEnded(id) })
        switch outcome {
        case .written:
            break
        case .writtenWithoutFiles(_, let limitBytes), .tooLarge(let limitBytes):
            published?.cut = (limitBytes, pasteboard.changeCount)
        case .nothingToWrite, .writeFailed:
            published = nil
            exchange.release(remote)
        }
        emit(.published(outcome))
    }

    /// Publication `id`'s write no longer stands: its offer is let go, unless a later publication of it replaced
    /// the write.
    private func writeEnded(_ id: Int) {
        guard let published, published.id == id else { return }
        self.published = nil
        exchange.release(published.remote)
    }

    /// The far side's offer stopped being this end's clipboard: a write of it the pasteboard still holds is
    /// retracted — every promise when the far side withdrew it, and what no paste had when the link or
    /// the setting ended it, since the far side may hold it still. This side's own copy replacing it replaced the
    /// write already.
    private func remoteEnded(_ remote: ClipboardRemoteOffer, _ ending: ClipboardItemExchange.RemoteEnding) {
        if published?.remote === remote { published = nil }
        let withdrawal: ClipboardWithdrawal
        switch ending {
        case .superseded: return
        case .linkLost, .settingChanged: withdrawal = .unread
        case .byFarSide: withdrawal = .everyPromise
        }
        guard let retraction = publisher.retractWrite(servingOffer: remote.token, withdrawing: withdrawal) else {
            return
        }
        emit(.retracted(retraction, ending))
    }

    private func emit(_ event: ClipboardEndEvent) {
        onEvent?(event)
    }
}

extension ClipboardEnd where Role == ClipboardHost {
    /// "Copy to Guest": offers the Mac's clipboard as it stands now, while the gate is
    /// ``ClipboardOfferGate/onCommand``.
    public func offerOnCommand() {
        readAndOffer(.command)
    }

    /// "Copy to Mac": asks the guest to offer its clipboard as it stands now. Its offer answering the request is
    /// taken unless, first, the Mac's clipboard was offered — the Mac's wins — the gate changed, or a later request
    /// replaced this one before the answer arrived whole. Any other request whose answer is not taken — refused,
    /// its answer lost before it was taken, or with no connection to ask over — is heard once as
    /// ``ClipboardEndEvent/requestRefused(_:)``.
    public func requestOffer() {
        guard let link else {
            let unconnected = WireError(.cancelled, debugDetail: "no connection carries the clipboard")
            return emit(.requestRefused(.failed(unconnected)))
        }
        exchange.requestOffer(on: link)
    }
}
