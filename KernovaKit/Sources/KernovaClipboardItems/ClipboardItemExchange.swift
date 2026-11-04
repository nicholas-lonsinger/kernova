import Dispatch
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// One end's clipboard over CLIPBOARD items, the same at the host and the macOS guest agent, over whichever
/// connection can use the feature now. Its current clipboard is one of: this side's offer, the far side's offer
/// it published, or nothing — never two at once.
///
/// - This side's offer is one ``ClipboardOfferSource``, each pull of it served from it. Making one ends the
///   far side's (``onRemoteOfferEnded`` hears `.superseded`), and the source lives only while its offer does: a
///   new connection is offered what the end's pasteboard holds then, never a source held from before.
/// - The far side's offer arrives as ``ClipboardRemoteOffer``, its items read whole, for the end to publish.
///   Taking it withdraws this side's offer.
/// - Offers made before either side saw the other's cross; the host's wins (``side``).
/// - A copy (``ItemOffer/copy``) is neither side's clipboard offer: the user sent it by command, and it lives as
///   long as the receiver's write of it. This side serves each copy it sent until the far side lets it go; the
///   receiver holds each copy it received until its end releases it.
/// - A connection's leaving ends every offer and copy it carried: what an end wrote of the far side's is the
///   end's to retract, since nothing more of it can be pulled.
///
/// Offers and ends hop onto the main actor in the order the connection emitted them; a pull's end is handled on
/// the connection's queue, so a paste waiting on a pull never needs the main actor.
@MainActor
public final class ClipboardItemExchange {
    /// Which end an exchange is: the one end of a crossing whose copy wins.
    public enum Side: Sendable {
        /// The host's: a guest offer made before the guest saw the host's latest is refused unread, since the
        /// host's copy is already on its way to the guest.
        case host
        /// A guest agent's: each offer names the last host offer it received (``ItemOffer/after``).
        case guest
    }

    /// How the far side's offer stopped being this end's clipboard.
    public enum RemoteEnding: Sendable, Equatable {
        /// The far side ended it, its clipboard having moved on: `hasSuccessor` when its next offer follows.
        case byFarSide(hasSuccessor: Bool)
        /// This side made a copy of its own.
        case superseded
        /// The connection left or no longer carries the feature, so nothing more of it can be pulled; the far
        /// side's clipboard may hold it still, and offers it again on the next connection.
        case linkLost
    }

    /// The guest's answer to the host's ask for its clipboard (``askForCopy(_:)``).
    public enum CopyAnswer: Sendable {
        /// The guest's copy, its items read; the host holds it until ``releaseCopy(_:)`` or
        /// ``refuseCopy(_:_:)``.
        case copy(ClipboardRemoteOffer)
        /// The guest's clipboard holds nothing to copy.
        case nothing
        /// No copy came: the connection left, or the ask was not sent.
        case failed(WireError)
    }

    /// Hears each offer of the far side once its items are read: it is this end's clipboard now.
    public var onRemoteOffer: ((ClipboardRemoteOffer) -> Void)?
    /// Hears each offer of the far side that stopped being this end's clipboard, and how.
    public var onRemoteOfferEnded: ((_ offer: ClipboardRemoteOffer, _ ending: RemoteEnding) -> Void)?
    /// The host: whether a copy of this side's own exists that it has not offered yet, which a crossing guest
    /// offer must lose to. False by default.
    public var holdsUnsentCopy: () -> Bool = { false }
    /// The host: a guest offer was refused for crossing a copy of this side's; offer that copy now.
    public var onCrossingRefused: (() -> Void)?
    /// The host: the guest's first offer on a connection reported an empty clipboard that did not change while
    /// unlinked, so the copy of this side's it held went with the last connection.
    public var onEmptyUnchangedReturn: (() -> Void)?
    /// A guest: the host asks for this side's clipboard; answer with ``sendCopy(_:answering:)`` naming the ask.
    public var onCopyAsked: ((_ ask: Data) -> Void)?
    /// A guest: the host sent a copy of its clipboard, its items read; this end holds it until it releases it.
    public var onCopyReceived: ((ClipboardRemoteOffer) -> Void)?
    /// Hears each copy this end held that ended before it let it go: the connection left, or the far side
    /// withdrew it. What this end wrote of it can be pulled no more.
    public var onCopyEnded: ((ClipboardRemoteOffer) -> Void)?
    /// Hears each copy this side sent that the far side refused, and why: `CLIPBOARD_CHANGED` when its clipboard
    /// changed before the copy landed, `TOO_LARGE` over its paste ceiling.
    public var onCopyRefused: ((WireError) -> Void)?
    /// Hears each pull of this side's offer that it served.
    public var onServed: (() -> Void)?
    /// Hears each pull of the far side's offer that landed here.
    public var onLanded: (() -> Void)?
    /// Hears each pull of the far side's offer that failed a paste, with the error it failed with:
    /// `TOO_LARGE` when the representation, or the offer's file set, is over the paste ceiling.
    public var onPullFailed: ((WireError) -> Void)?

    /// The far side's offer this end published, while it is this end's clipboard.
    public private(set) var remote: ClipboardRemoteOffer?
    /// This side's offer, while it is this end's clipboard and a connection carries it.
    public private(set) var localSource: ClipboardOfferSource?
    /// The far side's copies this end holds, by token.
    public private(set) var copies: [Data: ClipboardRemoteOffer] = [:]
    /// Whether this side's offer was the far side's clipboard when last heard of: set once one opens, and
    /// cleared only by the far side letting it go, a far-side offer taken, or this end withdrawing it — not by a
    /// connection ending, which a far side whose clipboard lost the offer with it reports on the next.
    public private(set) var localOfferStood = false

    /// Which end this is.
    public let side: Side
    private var link: (any ClipboardItemLink)?
    /// This side's offer sent on `link` and not yet answered, and the source it is served from once it opens.
    private var opening: (token: Data, source: ClipboardOfferSource)?
    /// The token of `localSource`'s offer on `link`.
    private var localToken: Data?
    /// The host: the last offer the connection opened on `link`. A guest: the last host offer received on it.
    private var lastLinkToken: Data?
    /// The host: whether the guest's first offer on `link` has arrived.
    private var heardOnLink = false
    /// The tokens of the far side's offers whose items are still being read.
    private var reading: Set<Data> = []
    /// The tokens of the far side's copies whose items are still being read.
    private var readingCopies: Set<Data> = []
    /// This side's copies on `link`, by token, each served until the far side lets it go.
    private var sentCopies: [Data: ClipboardOfferSource] = [:]
    /// The host: the ask awaiting the guest's copy on `link`.
    private var ask: (token: Data, answer: (CopyAnswer) -> Void)?
    private var nextGeneration: UInt64 = 1
    private let staging: ClipboardFileStaging
    private let pasteCeiling: @Sendable () -> Int
    private let pulls = ClipboardPullRegistry()
    private let serves = ClipboardServeWaits()
    private let logger: KernovaLogger

    /// An exchange landing the far side's representations in clipboard staging labelled `stagingLabel` under
    /// `stagingRoot`, reading the paste ceiling from `pasteCeiling` each time a pull needs it.
    public init(
        side: Side, stagingLabel: String, stagingRoot: ProcessStagingRoot,
        pasteCeiling: @escaping @Sendable () -> Int, logger: KernovaLogger
    ) {
        self.side = side
        staging = ClipboardFileStaging(label: stagingLabel, root: stagingRoot)
        self.pasteCeiling = pasteCeiling
        self.logger = logger
    }

    /// Whether a connection can carry the clipboard now.
    public var isLinked: Bool { link != nil }

    // MARK: The connection

    /// Runs over `link` from now on, or over nothing; this sends nothing. Every offer and copy the connection
    /// before carried ends here: the far side's offer as `.linkLost`, each copy held through ``onCopyEnded``,
    /// their pulls cancelled; this side's, whose ends follow as events; and an ask unanswered. What a new
    /// connection is offered is the end's to read from its pasteboard then.
    public func setLink(_ link: (any ClipboardItemLink)?) {
        self.link = link
        opening = nil
        localToken = nil
        localSource = nil
        lastLinkToken = nil
        heardOnLink = false
        reading.removeAll()
        readingCopies.removeAll()
        sentCopies.removeAll()
        if let ask {
            self.ask = nil
            ask.answer(.failed(WireError(.cancelled, debugDetail: "the connection left")))
        }
        let held = copies.values
        copies.removeAll()
        for copy in held {
            copy.close()
            onCopyEnded?(copy)
        }
        if let remote {
            self.remote = nil
            remote.close()
            onRemoteOfferEnded?(remote, .linkLost)
        }
    }

    // MARK: This side's offer

    /// Makes `source` this end's clipboard and offers it on the connection, replacing this side's offer before
    /// it (`ITEM_OFFER_REPLACED`) and ending the far side's. A source with no items offers nothing, so it
    /// withdraws this side's offer instead. With no connection, nothing is held. A guest's first offer on a
    /// connection says whether its clipboard `changedWhileUnlinked`.
    public func offer(_ source: ClipboardOfferSource, changedWhileUnlinked: Bool = false) {
        guard !source.items.isEmpty else { return withdrawLocal() }
        endRemote(.superseded)
        guard let link else { return }
        // A far-side offer still being read predates this side's offer too.
        for token in reading { link.releaseOffer(token) }
        reading.removeAll()
        withdrawLocal()
        let token = Self.freshToken()
        opening = (token, source)
        let offer = ItemOffer(
            token: token, concealed: source.concealed, items: source.items, after: after,
            changedWhileUnlinked: side == .guest && changedWhileUnlinked)
        send(offer, on: link) {
            [weak self] opened in self?.answered(token, opened: opened)
        }
    }

    /// A guest: this side's first offer on a connection, when its clipboard holds nothing: a report of no items
    /// saying whether its clipboard changed while unlinked, which the host releases.
    public func reportEmpty(changedWhileUnlinked: Bool) {
        withdrawLocal()
        guard side == .guest, let link else { return }
        send(
            ItemOffer(token: Self.freshToken(), items: [], after: after, changedWhileUnlinked: changedWhileUnlinked),
            on: link
        ) { _ in }
    }

    /// The `after` this side's next offer carries: a guest's names the last host offer it received.
    private var after: Data { side == .guest ? lastLinkToken ?? Data() : Data() }

    /// The connection answered this side's offer `token`: it is this end's clipboard now, unless something
    /// replaced it while it opened, when it is withdrawn at once.
    private func answered(_ token: Data, opened: Bool) {
        guard let opening, opening.token == token else {
            if opened { link?.withdrawOffer(token) }
            return
        }
        self.opening = nil
        guard opened else { return }
        localToken = token
        localSource = opening.source
        localOfferStood = true
        if side == .host { lastLinkToken = token }
    }

    /// Sends `offer` on `link`, hearing on the main actor whether it opened.
    private func send(
        _ offer: ItemOffer, on link: any ClipboardItemLink, _ opened: @escaping @MainActor (Bool) -> Void
    ) {
        let logger = logger
        let count = offer.items.count
        let copy = offer.copy
        link.offerItems(offer) { refusal in
            if let refusal {
                logger.log(
                    .notice, "The clipboard offer was not opened: \(String(describing: refusal), privacy: .public)")
            } else {
                logger.log(
                    .notice, "Offered the clipboard\(copy ? " as a copy" : ""): \(count, privacy: .public) item(s)")
            }
            MainActorBridge.async { opened(refusal == nil) }
        }
    }

    /// Withdraws this side's offer, `CANCELLED`: no newer one follows. The far side's offer, if it is this
    /// end's clipboard, stays so.
    public func withdrawLocal() {
        if let localToken { link?.withdrawOffer(localToken) }
        opening = nil
        localToken = nil
        localSource = nil
        localOfferStood = false
    }

    /// Ends the far side's offer as this end's clipboard, releasing it: this side pulls nothing more of it.
    private func endRemote(_ ending: RemoteEnding) {
        guard let remote else { return }
        self.remote = nil
        remote.release()
        onRemoteOfferEnded?(remote, ending)
    }

    /// The host: whether the guest made `header`'s offer before it received this side's latest — sent, or still
    /// opening — or while this side holds a copy it has yet to offer.
    private func crosses(_ header: ItemSetHeaderValue) -> Bool {
        if let sent = opening?.token ?? lastLinkToken, header.after != sent { return true }
        return holdsUnsentCopy()
    }

    private static func freshToken() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: Copies

    /// Sends `source` to the far side as a copy, `answering` the ask it answers, if any: served from `source`
    /// until the far side lets it go, whatever this end's clipboard does meanwhile. A nil `source` answers that
    /// this side's clipboard holds nothing to copy. Returns whether a connection carried it.
    @discardableResult
    public func sendCopy(_ source: ClipboardOfferSource?, answering ask: Data = Data()) -> Bool {
        guard let link else { return false }
        let token = Self.freshToken()
        if let source { sentCopies[token] = source }
        let offer = ItemOffer(
            token: token, concealed: source?.concealed ?? false, items: source?.items ?? [], after: ask, copy: true)
        send(offer, on: link) { [weak self] opened in
            guard !opened, let self, self.sentCopies.removeValue(forKey: token) != nil else { return }
            self.onCopyRefused?(WireError(.cancelled, debugDetail: "the copy was not opened"))
        }
        return true
    }

    /// The host: asks the guest for a copy of its clipboard as it stands now, replacing an ask still unanswered;
    /// `answer` hears it once.
    public func askForCopy(_ answer: @escaping (CopyAnswer) -> Void) {
        if let ask {
            self.ask = nil
            ask.answer(.failed(WireError(.cancelled, debugDetail: "a newer ask replaced it")))
        }
        guard side == .host, let link else {
            return answer(.failed(WireError(.cancelled, debugDetail: "no connection carries the clipboard")))
        }
        let token = Self.freshToken()
        ask = (token, answer)
        send(ItemOffer(token: token, items: [], copy: true), on: link) { [weak self] opened in
            guard !opened, let self, let ask = self.ask, ask.token == token else { return }
            self.ask = nil
            ask.answer(.failed(WireError(.cancelled, debugDetail: "the ask was not opened")))
        }
    }

    /// Lets `copy` go: this end's clipboard no longer holds what it wrote of it, so the far side serves it no
    /// more.
    public func releaseCopy(_ copy: ClipboardRemoteOffer) {
        guard copies.removeValue(forKey: copy.token) != nil else { return }
        copy.release()
    }

    /// Refuses `copy` with `error`, written nowhere: the far side hears why.
    public func refuseCopy(_ copy: ClipboardRemoteOffer, _ error: WireError) {
        guard copies.removeValue(forKey: copy.token) != nil else { return }
        copy.refuse(error)
    }

    /// A copy of the far side's arrived: an ask, an answer to this side's ask, or a copy for this end to write.
    private func receivedCopy(_ header: ItemSetHeaderValue, on link: any ClipboardItemLink) {
        switch side {
        case .guest:
            guard header.count > 0 else {
                link.releaseOffer(header.token)
                onCopyAsked?(header.token)
                return
            }
        case .host:
            guard let ask, header.after == ask.token else {
                logger.log(.notice, "Refused a guest clipboard copy that answers no ask of the host's")
                link.releaseOffer(header.token)
                return
            }
            guard header.count > 0 else {
                link.releaseOffer(header.token)
                self.ask = nil
                ask.answer(.nothing)
                return
            }
        }
        readingCopies.insert(header.token)
        readItems(of: header, on: link) { [weak self] items in self?.copyRead(header, items, on: link) }
    }

    private func copyRead(_ header: ItemSetHeaderValue, _ items: [OfferedItem]?, on link: any ClipboardItemLink) {
        guard readingCopies.remove(header.token) != nil else { return }
        guard let items else {
            logger.log(.notice, "The far side's clipboard copy ended before its items were read")
            link.releaseOffer(header.token)
            if let ask, header.after == ask.token {
                self.ask = nil
                ask.answer(.failed(WireError(.cancelled, debugDetail: "the copy ended before it was read")))
            }
            return
        }
        let copy = remoteOffer(header, items, on: link)
        copies[header.token] = copy
        logger.log(.notice, "Received a clipboard copy: \(items.count, privacy: .public) item(s)")
        switch side {
        case .host:
            guard let ask, header.after == ask.token else { return releaseCopy(copy) }
            self.ask = nil
            ask.answer(.copy(copy))
        case .guest:
            onCopyReceived?(copy)
        }
    }

    // MARK: Serving

    /// The content of `representation` of this side's offer that pull `id`'s `request` pulls, served from its
    /// source. Called on the pull's own queue, never the main thread: it waits for the main actor to read the
    /// source, and for as long as a promise it calls in takes, until the pull or its offer ends.
    nonisolated public func content(
        _ id: ItemPullID, _ request: PullRequest, _ representation: Representation
    ) -> Result<ItemContent, WireError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        guard let wait = serves.open(id, token: request.token) else {
            return .failure(WireError(.cancelled, debugDetail: "the pull ended before it was served"))
        }
        let serving = Task { @MainActor in wait.answer(await self.serve(request)) }
        let result = wait.result()
        serving.cancel()
        serves.served(id)
        return result
    }

    /// Serves `request` from this side's offer, or from the copy it names.
    private func serve(_ request: PullRequest) async -> Result<ItemContent, WireError> {
        let source = request.token == localToken ? localSource : sentCopies[request.token]
        guard let source else {
            return .failure(WireError(.itemRepresentationUnavailable, debugDetail: "not this side's open offer"))
        }
        do throws(ClipboardServeError) {
            let served = try await source.serve(item: Int(request.item), representation: Int(request.representation))
            onServed?()
            switch served {
            case .bytes(let data):
                return .success(.inline(data))
            case .file(let url), .folder(let url):
                return .success(.tree(path: url.path))
            }
        } catch {
            switch error {
            case .unavailable:
                // What the offer was read from is gone, so it can serve nothing more: it ends.
                if localSource === source { withdrawLocal() }
                return .failure(WireError(.itemRepresentationUnavailable, debugDetail: "the source is gone"))
            case .readFailed:
                return .failure(WireError(.readFailed, debugDetail: "the source could not be read"))
            }
        }
    }

    // MARK: The far side's offer

    /// Hands `event`, of the connection `link` names, to the exchange. Pulls' ends go to ``pullEnded(_:_:)``.
    public func handle(_ event: ItemTransferEvent, on link: any ClipboardItemLink) {
        serves.end(by: event)
        switch event {
        case .offerReceived(let header):
            if header.copy { receivedCopy(header, on: link) } else { received(header, on: link) }
        case .offerEnded(_, .local, let token, let closure):
            if sentCopies.removeValue(forKey: token) != nil {
                if case .resetByPeer(let error) = closure { onCopyRefused?(error) }
                return
            }
            if let ask, ask.token == token, case .resetByPeer(let error) = closure {
                self.ask = nil
                ask.answer(.failed(error))
                return
            }
            guard token == localToken else { return }
            localToken = nil
            localSource = nil
            switch closure {
            case .completed, .resetByPeer: localOfferStood = false
            case .resetLocally, .connectionClosedLocally, .connectionClosedByPeer, .connectionLost: break
            }
        case .offerEnded(_, .remote, let token, let closure):
            reading.remove(token)
            readingCopies.remove(token)
            if let copy = copies.removeValue(forKey: token) {
                copy.close()
                onCopyEnded?(copy)
                return
            }
            guard let remote, remote.token == token else { return }
            self.remote = nil
            remote.close()
            onRemoteOfferEnded?(remote, Self.ending(closure))
        case .pullEnded(_, let id, let result):
            pullEnded(id, result)
        case .serveEnded:
            break
        }
    }

    /// How a far-side offer that ended with `closure` stopped being this end's clipboard. Only the far side's
    /// RESET is its clipboard moving on; `ITEM_OFFER_REPLACED` says its next offer follows.
    static func ending(_ closure: StreamClosure) -> RemoteEnding {
        switch closure {
        case .resetByPeer(let error): .byFarSide(hasSuccessor: error.code == .itemOfferReplaced)
        case .completed, .resetLocally, .connectionClosedLocally, .connectionClosedByPeer, .connectionLost: .linkLost
        }
    }

    /// A pull of the far side's offer ended: handled where it arrives, on any queue.
    nonisolated public func pullEnded(_ id: ItemPullID, _ result: ItemPullResult) {
        pulls.ended(id, result)
    }

    /// Releases `remote`, which this end's pasteboard no longer holds: this side pulls nothing more of it, and
    /// what it landed stays servable.
    public func release(_ remote: ClipboardRemoteOffer) {
        if self.remote === remote { self.remote = nil }
        remote.release()
    }

    /// Reads every item of the far side's offer `header`, then hands the offer over, unless it ended meanwhile.
    /// The host first refuses, unread, a guest offer that crosses a copy of its own, and takes a guest's first
    /// offer of no items as its report of an empty clipboard.
    private func received(_ header: ItemSetHeaderValue, on link: any ClipboardItemLink) {
        switch side {
        case .guest:
            lastLinkToken = header.token
        case .host:
            let first = !heardOnLink
            heardOnLink = true
            if header.count == 0 {
                link.releaseOffer(header.token)
                if first, !header.changedWhileUnlinked { onEmptyUnchangedReturn?() }
                return
            }
            guard !crosses(header) else {
                logger.log(.notice, "Refused a guest clipboard offer that crossed the host's newer copy")
                link.releaseOffer(header.token)
                onCrossingRefused?()
                return
            }
        }
        if let remote {
            // The far side replaced its offer: its RESET comes first, so this is only a connection's offer.
            self.remote = nil
            remote.close()
        }
        reading.insert(header.token)
        readItems(of: header, on: link) { [weak self] items in self?.read(header, items, on: link) }
    }

    private func read(_ header: ItemSetHeaderValue, _ items: [OfferedItem]?, on link: any ClipboardItemLink) {
        guard reading.remove(header.token) != nil else { return }
        guard let items else {
            logger.log(.notice, "The far side's clipboard offer ended before its items were read")
            link.releaseOffer(header.token)
            return
        }
        guard !items.isEmpty else {
            logger.log(.notice, "Refused a clipboard offer of no items")
            link.releaseOffer(header.token)
            return
        }
        let remote = remoteOffer(header, items, on: link)
        withdrawLocal()
        self.remote = remote
        logger.log(.notice, "Received a clipboard offer: \(items.count, privacy: .public) item(s)")
        onRemoteOffer?(remote)
    }

    /// Reads every item of `header`'s offer at once, handing `done` them all, or nil once any is not held.
    private func readItems(
        of header: ItemSetHeaderValue, on link: any ClipboardItemLink,
        _ done: @escaping @MainActor ([OfferedItem]?) -> Void
    ) {
        let count = header.count
        let read = Locked<[OfferedItem?]>(Array(repeating: nil, count: count))
        let left = Locked(count)
        let finish: @Sendable () -> Void = {
            let items = read.withLock { $0 }
            let held = items.compactMap { $0 }
            MainActorBridge.async { done(held.count == items.count ? held : nil) }
        }
        guard count > 0 else { return finish() }
        for index in 0..<count {
            link.readItem(header.token, item: UInt32(index)) { item in
                read.withLock { $0[index] = item }
                if left.withLock({ left in
                    left -= 1
                    return left == 0
                }) {
                    finish()
                }
            }
        }
    }

    /// The far side's offer `header` of `items`, its pulls landing in a staging generation of its own.
    private func remoteOffer(
        _ header: ItemSetHeaderValue, _ items: [OfferedItem], on link: any ClipboardItemLink
    ) -> ClipboardRemoteOffer {
        let generation = nextGeneration
        nextGeneration += 1
        let ceiling = pasteCeiling
        return ClipboardRemoteOffer(
            header: header, items: items, link: link, staging: staging, generation: generation,
            ceiling: { UInt64(clamping: max(ceiling(), 0)) }, registry: pulls, logger: logger,
            landed: { [weak self] in MainActorBridge.async { self?.onLanded?() } },
            failed: { [weak self] error in MainActorBridge.async { self?.onPullFailed?(error) } })
    }
}

/// The waits of the pulls this side serves, each ended by its pull's end or its offer's: every pull's content is
/// asked for once and its `.serveEnded` arrives once, in either order, and an entry lasts until both have.
final class ClipboardServeWaits: Sendable {
    /// One pull's wait for its content: the first answer wins.
    final class Wait: Sendable {
        let token: Data
        private let answered = Locked<Result<ItemContent, WireError>?>(nil)
        private let signal = DispatchSemaphore(value: 0)

        init(token: Data) {
            self.token = token
        }

        func answer(_ result: Result<ItemContent, WireError>) {
            let first = answered.withLock { answered -> Bool in
                guard answered == nil else { return false }
                answered = result
                return true
            }
            if first { signal.signal() }
        }

        /// Parks the calling thread until the first answer.
        func result() -> Result<ItemContent, WireError> {
            signal.wait()
            guard let result = answered.withLock({ $0 }) else { preconditionFailure("a wait signalled unanswered") }
            return result
        }
    }

    private enum Entry {
        /// Its content is being served.
        case serving(Wait)
        /// Its content was served; its end is still to come.
        case served
        /// It ended before its content was asked for.
        case ended
    }

    private let entries = Locked<[ItemPullID: Entry]>([:])

    /// The wait for pull `id`'s content, of the offer `token`; nil when the pull already ended.
    func open(_ id: ItemPullID, token: Data) -> Wait? {
        entries.withLock { entries in
            if case .ended = entries[id] {
                entries[id] = nil
                return nil
            }
            let wait = Wait(token: token)
            entries[id] = .serving(wait)
            return wait
        }
    }

    /// Pull `id`'s content was answered.
    func served(_ id: ItemPullID) {
        entries.withLock { entries in
            switch entries[id] {
            case .serving: entries[id] = .served
            case .served, .ended, nil: entries[id] = nil
            }
        }
    }

    /// Ends the waits `event` ends: a pull's at its `.serveEnded`, every pull's of an offer of this side's at
    /// its `.offerEnded`.
    func end(by event: ItemTransferEvent) {
        switch event {
        case .serveEnded(_, let id, _):
            let wait = entries.withLock { entries -> Wait? in
                switch entries.removeValue(forKey: id) {
                case .serving(let wait):
                    entries[id] = .served
                    return wait
                case .served, .ended:
                    return nil
                case nil:
                    entries[id] = .ended
                    return nil
                }
            }
            wait?.answer(.failure(WireError(.cancelled, debugDetail: "the pull ended")))
        case .offerEnded(_, .local, let token, _):
            let waits = entries.withLock { entries in
                entries.values.compactMap { entry -> Wait? in
                    if case .serving(let wait) = entry, wait.token == token { wait } else { nil }
                }
            }
            for wait in waits {
                wait.answer(.failure(WireError(.itemRepresentationUnavailable, debugDetail: "the offer ended")))
            }
        case .offerReceived, .offerEnded, .pullEnded:
            break
        }
    }
}
