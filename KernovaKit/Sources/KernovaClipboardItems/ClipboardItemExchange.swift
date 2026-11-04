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
/// - The host's offer of no items is its clear (``clear()``): the guest empties its clipboard.
/// - A connection's leaving ends both offers it carried: what an end published of the far side's is the end's
///   to retract, since nothing more of it can be pulled.
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
        /// This side cleared the clipboard: neither end holds anything now.
        case cleared
        /// The connection left or no longer carries the feature, so nothing more of it can be pulled; the far
        /// side's clipboard may hold it still, and offers it again on the next connection.
        case linkLost
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
    /// Hears each pull of this side's offer that it served.
    public var onServed: (() -> Void)?
    /// Hears each pull of the far side's offer that landed here.
    public var onLanded: (() -> Void)?
    /// Hears each pull of the far side's offer that failed a paste, with the error it failed with:
    /// `TOO_LARGE` when the representation, or the offer's file set, is over the paste ceiling.
    public var onPullFailed: ((WireError) -> Void)?
    /// A guest: the host cleared the clipboard, so this end empties its own.
    public var onCleared: (() -> Void)?
    /// Hears each change of ``localSource``.
    public var onLocalSourceChanged: (() -> Void)?

    /// The far side's offer this end published, while it is this end's clipboard.
    public private(set) var remote: ClipboardRemoteOffer?
    /// This side's offer, while it is this end's clipboard and a connection carries it.
    public private(set) var localSource: ClipboardOfferSource? {
        didSet { if localSource !== oldValue { onLocalSourceChanged?() } }
    }

    /// Which end this is.
    public let side: Side
    private var link: (any ClipboardItemLink)?
    /// The token of `localSource`'s offer on `link`.
    private var localToken: Data?
    /// The host: the last offer sent on `link`. A guest: the last host offer received on it.
    private var lastLinkToken: Data?
    /// The tokens of the far side's offers whose items are still being read.
    private var reading: Set<Data> = []
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

    /// Runs over `link` from now on, or over nothing; this sends nothing. Both offers the connection before
    /// carried end here: the far side's as `.linkLost`, its pulls cancelled, and this side's, whose end follows as
    /// an event. What a new connection is offered is the end's to read from its pasteboard then.
    public func setLink(_ link: (any ClipboardItemLink)?) {
        self.link = link
        localToken = nil
        localSource = nil
        lastLinkToken = nil
        reading.removeAll()
        if let remote {
            self.remote = nil
            remote.close()
            onRemoteOfferEnded?(remote, .linkLost)
        }
    }

    // MARK: This side's offer

    /// Makes `source` this end's clipboard and offers it on the connection, replacing this side's offer before
    /// it (`ITEM_OFFER_REPLACED`) and ending the far side's. A source with no items offers nothing, so it
    /// withdraws this side's offer instead. With no connection, nothing is held.
    public func offer(_ source: ClipboardOfferSource) {
        guard !source.items.isEmpty else { return withdrawLocal() }
        endRemote(.superseded)
        open(source.items, concealed: source.concealed, servedBy: source)
    }

    /// Empties this end's clipboard and the far side's: the far side's offer ends (`.cleared`), and this side
    /// offers no items in place of its own, which the far side publishes as a clear. With no connection, only the
    /// far side's offer ends.
    public func clear() {
        endRemote(.cleared)
        open([], concealed: false, servedBy: nil)
    }

    /// Offers `items` on the connection as this side's offer, each pull served from `source`; with no
    /// connection, nothing is held.
    private func open(_ items: [OfferedItem], concealed: Bool, servedBy source: ClipboardOfferSource?) {
        guard let link else { return }
        // A far-side offer still being read predates this side's offer too.
        for token in reading { link.releaseOffer(token) }
        reading.removeAll()
        localSource = source
        let token = Self.freshToken()
        localToken = token
        if side == .host { lastLinkToken = token }
        let logger = logger
        let count = items.count
        let offer = ItemOffer(
            token: token, concealed: concealed, items: items, after: side == .guest ? lastLinkToken ?? Data() : Data())
        link.offerItems(offer) { refusal in
            if let refusal {
                logger.log(
                    .notice, "The clipboard offer was not opened: \(String(describing: refusal), privacy: .public)")
            } else {
                logger.log(.notice, "Offered the clipboard: \(count, privacy: .public) item(s)")
            }
        }
    }

    /// Withdraws this side's offer, `CANCELLED`: no newer one follows. The far side's offer, if it is this
    /// end's clipboard, stays so.
    public func withdrawLocal() {
        if let localToken { link?.withdrawOffer(localToken) }
        localToken = nil
        localSource = nil
    }

    /// Ends the far side's offer as this end's clipboard, releasing it: this side pulls nothing more of it.
    private func endRemote(_ ending: RemoteEnding) {
        guard let remote else { return }
        self.remote = nil
        remote.release()
        onRemoteOfferEnded?(remote, ending)
    }

    /// The host: whether the guest made `header`'s offer before it received this side's latest, or while this
    /// side holds a copy it has yet to offer.
    private func crosses(_ header: ItemSetHeaderValue) -> Bool {
        if let lastLinkToken, header.after != lastLinkToken { return true }
        return holdsUnsentCopy()
    }

    private static func freshToken() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

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

    private func serve(_ request: PullRequest) async -> Result<ItemContent, WireError> {
        guard let source = localSource, request.token == localToken else {
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
            received(header, on: link)
        case .offerEnded(_, .local, let token, _):
            guard token == localToken else { return }
            localToken = nil
            localSource = nil
        case .offerEnded(_, .remote, let token, let closure):
            reading.remove(token)
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
    /// The host first refuses, unread, a guest offer that crosses a copy of its own.
    private func received(_ header: ItemSetHeaderValue, on link: any ClipboardItemLink) {
        switch side {
        case .guest:
            lastLinkToken = header.token
        case .host:
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
        let generation = nextGeneration
        nextGeneration += 1
        let count = header.count
        let read = Locked<[OfferedItem?]>(Array(repeating: nil, count: count))
        let left = Locked(count)
        let finish: @Sendable () -> Void = { [weak self] in
            let items = read.withLock { $0 }
            MainActorBridge.async { self?.read(header, items, on: link, generation: generation) }
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

    private func read(
        _ header: ItemSetHeaderValue, _ items: [OfferedItem?], on link: any ClipboardItemLink, generation: UInt64
    ) {
        guard reading.remove(header.token) != nil else { return }
        let held = items.compactMap { $0 }
        guard held.count == items.count else {
            logger.log(.notice, "The far side's clipboard offer ended before its items were read")
            link.releaseOffer(header.token)
            return
        }
        guard !held.isEmpty else { return farSideCleared(header, on: link) }
        let ceiling = pasteCeiling
        let remote = ClipboardRemoteOffer(
            header: header, items: held, link: link, staging: staging, generation: generation,
            ceiling: { UInt64(clamping: max(ceiling(), 0)) }, registry: pulls, logger: logger,
            landed: { [weak self] in MainActorBridge.async { self?.onLanded?() } },
            failed: { [weak self] error in MainActorBridge.async { self?.onPullFailed?(error) } })
        withdrawLocal()
        self.remote = remote
        logger.log(.notice, "Received a clipboard offer: \(held.count, privacy: .public) item(s)")
        onRemoteOffer?(remote)
    }

    /// The far side offered no items: a guest takes it as the host's clear, emptying its clipboard; the host
    /// takes none from a guest, whose clipboard emptying withdraws its offer instead. Either way the offer,
    /// which has nothing to pull, is released.
    private func farSideCleared(_ header: ItemSetHeaderValue, on link: any ClipboardItemLink) {
        link.releaseOffer(header.token)
        guard side == .guest else {
            return logger.log(.notice, "Refused a guest clipboard offer of no items")
        }
        withdrawLocal()
        logger.log(.notice, "The host cleared the clipboard")
        onCleared?()
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
