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
/// - This side's offer is one ``ClipboardOfferSource``, each pull of it served from it, withdrawn once the
///   pasteboard it was read from moves on (``ClipboardOfferSource/whenMovedOn(_:)``). Making one ends the far
///   side's (``onRemoteOfferEnded`` hears `.superseded`), and the source lives only while its offer does: a new
///   connection carries only a copy made after it came up, never a source held from before.
/// - The far side's offer arrives as ``ClipboardRemoteOffer``, its items read whole, for the end to publish.
///   Taking it withdraws this side's offer.
/// - Offers made before either side saw the other's cross; the host's wins (``side``).
/// - The far side's offer is taken only as this end's gate admits it (``gate``): every one while this end offers at
///   every copy; while it offers on command, only the answer to the request it has open and — at a guest — the
///   host's own commands. Changing the gate ends every offer and request of either side's that this end sent or
///   took.
/// - The host's request that the guest offer its clipboard is no offer: the guest answers it once, with an offer
///   naming it or a refusal, and no offer withdraws it.
/// - A connection's leaving ends every offer and request it carried: what an end wrote of the far side's is the
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

        /// Whether, while this end offers on command, it takes a far-side offer answering no request of its own:
        /// a guest does, since its host offers then only by the host's own command; the host does not, since a
        /// guest has no command and offers then only to answer the host's request.
        var takesFarSideCommands: Bool { self == .guest }
    }

    /// The host's request that this side offer its clipboard, which this side answers once: with an offer
    /// (``offer(_:answering:)``), or a refusal (``refuseRequest(_:_:)``).
    struct OfferRequest: Sendable, Hashable {
        let token: Data
    }

    /// Why the far side offered nothing for this end's request (``requestOffer(on:)``).
    public enum RequestRefusal: Sendable, Equatable {
        /// Its clipboard holds nothing to copy (`CLIPBOARD_NOTHING_TO_COPY`).
        case nothingToCopy
        /// Its clipboard names files none of which it could read (`READ_FAILED`).
        case unreadable
        /// The request went unanswered, or was refused for another reason.
        case failed(WireError)
    }

    /// How the far side's offer stopped being this end's clipboard.
    public enum RemoteEnding: Sendable, Equatable {
        /// The far side withdrew it: `hasSuccessor` when its next offer follows.
        case byFarSide(hasSuccessor: Bool)
        /// This side made a copy of its own.
        case superseded
        /// The clipboard setting changed — this end's gate (``setGate(_:)``), or the far side's, which withdraws
        /// it `DISABLED_BY_POLICY` — and ended it: the far side's clipboard may hold it still.
        case settingChanged
        /// The link ended — the connection left, or the feature stopped being usable on either side — so nothing
        /// more of it can be pulled; the far side's clipboard may hold it still, and the next link carries only
        /// its next copy.
        case linkLost
    }

    /// Hears each offer of the far side once its items are read: it is this end's clipboard now.
    var onRemoteOffer: ((ClipboardRemoteOffer) -> Void)?
    /// Hears each offer of the far side that stopped being this end's clipboard, and how.
    var onRemoteOfferEnded: ((_ offer: ClipboardRemoteOffer, _ ending: RemoteEnding) -> Void)?
    /// The host: whether a copy of this side's own exists that it has not offered yet, which a crossing guest
    /// offer must lose to. False by default.
    var holdsUnsentCopy: () -> Bool = { false }
    /// The host: a guest offer was refused for crossing a copy of this side's; offer that copy now.
    var onCrossingRefused: (() -> Void)?
    /// Hears each pull of this side's offer that it served.
    var onServed: (() -> Void)?
    /// Hears each pull of the far side's offer that landed here.
    var onLanded: (() -> Void)?
    /// Hears each pull of the far side's offer that failed a paste, with the error it failed with:
    /// `TOO_LARGE` when the representation, or the offer's file set, is over the paste ceiling.
    var onPullFailed: ((WireError) -> Void)?
    /// A guest: the host asks this side to offer its clipboard, to be answered once.
    var onOfferRequested: ((OfferRequest) -> Void)?
    /// The host: the far side offered nothing for this end's request, and why; an answer naming only what this
    /// end's clipboard holds already (`CLIPBOARD_ALREADY_HELD`) ends it unheard.
    var onRequestRefused: ((RequestRefusal) -> Void)?

    /// The far side's offer this end published, while it is this end's clipboard.
    private var remote: ClipboardRemoteOffer?

    /// Which end this is.
    let side: Side
    /// Which far-side offers this end takes, which only ``setGate(_:)`` changes.
    private(set) var gate: ClipboardOfferGate
    private var link: (any ClipboardItemLink)?

    /// This side's offer on `link`.
    private enum Local {
        case none
        /// Sent and not yet answered: once it opens, it is served from `source`.
        case opening(token: Data, source: ClipboardOfferSource)
        /// This end's clipboard, served from `source`.
        case open(token: Data, source: ClipboardOfferSource)
    }

    private var local = Local.none
    /// This side's offers withdrawn while they opened, by token, with the code each is withdrawn with once it opens.
    private var abandoned: [Data: ErrorCode] = [:]
    /// This side's open offer: its token and the source it is served from.
    private var openLocal: (token: Data, source: ClipboardOfferSource)? {
        if case .open(let token, let source) = local { (token, source) } else { nil }
    }
    /// The host: the request this end has open on `link` (``requestOffer(on:)``), until a far-side offer answers
    /// it.
    private var request: Data?
    /// A guest: the host's requests on `link` still to be answered.
    private var requests: Set<Data> = []
    /// The host: the last offer the connection opened on `link`. A guest: the last host offer received on it.
    private var lastLinkToken: Data?
    /// The tokens of the far side's offers whose items are still being read.
    private var reading: Set<Data> = []
    private var nextGeneration: UInt64 = 1
    private let staging: ClipboardFileStaging
    private let pasteCeiling: @Sendable () -> Int
    private let pulls = ClipboardPullRegistry()
    private let serves = ClipboardServeWaits()
    private let logger: KernovaLogger

    /// An exchange taking the far side's offers as `gate` admits them, landing their representations in clipboard
    /// staging labelled `stagingLabel` under `stagingRoot`, reading the paste ceiling from `pasteCeiling` each
    /// time a pull needs it.
    init(
        side: Side, gate: ClipboardOfferGate, stagingLabel: String, stagingRoot: ProcessStagingRoot,
        pasteCeiling: @escaping @Sendable () -> Int, logger: KernovaLogger
    ) {
        self.side = side
        self.gate = gate
        staging = ClipboardFileStaging(label: stagingLabel, root: stagingRoot)
        self.pasteCeiling = pasteCeiling
        self.logger = logger
    }

    // MARK: The connection

    /// Runs over `link` from now on, or over nothing; this sends nothing. Every offer and request the connection
    /// before carried ends here: the far side's offer as `.linkLost`, its pulls cancelled; this side's, whose
    /// ends follow as events; and a request of either side's.
    func setLink(_ link: (any ClipboardItemLink)?) {
        self.link = link
        local = .none
        abandoned.removeAll()
        requests.removeAll()
        let unanswered = request
        request = nil
        lastLinkToken = nil
        reading.removeAll()
        if let remote {
            self.remote = nil
            remote.close()
            onRemoteOfferEnded?(remote, .linkLost)
        }
        if unanswered != nil { onRequestRefused?(.failed(WireError(.cancelled, debugDetail: "the connection left"))) }
    }

    // MARK: The gate

    /// Takes the far side's offers as `gate` admits them from now on, ending everything either side's offers
    /// carried before: this side's offer is withdrawn `DISABLED_BY_POLICY`; the far side's is let go, ending as
    /// `.settingChanged`, and so is each still being read, unread; this end's request is called off unheard, and
    /// each of the host's this end has yet to answer is refused `DISABLED_BY_POLICY`.
    func setGate(_ gate: ClipboardOfferGate) {
        self.gate = gate
        withdrawLocal(.disabledByPolicy)
        for token in reading { link?.releaseOffer(token) }
        reading.removeAll()
        if let request {
            self.request = nil
            link?.withdrawOffer(request, code: .disabledByPolicy)
        }
        for token in requests { link?.refuseOffer(token, WireError(.disabledByPolicy)) }
        requests.removeAll()
        guard let remote else { return }
        self.remote = nil
        remote.release()
        onRemoteOfferEnded?(remote, .settingChanged)
    }

    /// Whether this end takes the far side's offer `header` under its gate: one answering a request only while
    /// it is the request this end has open, whatever the gate; any other while this end offers at every copy,
    /// or — while it offers on command — when it takes the far side's commands (``Side/takesFarSideCommands``).
    private func admits(_ header: ItemSetHeaderValue) -> Bool {
        guard header.request.isEmpty else { return header.request == request }
        switch gate {
        case .everyCopy: return true
        case .onCommand: return side.takesFarSideCommands
        }
    }

    // MARK: This side's offer

    /// Makes `source`, which holds at least one item, this end's clipboard and offers it on the connection,
    /// replacing this side's offer before it (`ITEM_OFFER_REPLACED`) and ending the far side's, answering the
    /// host's `request` when one is named, which is released once the offer opens. The offer is withdrawn once
    /// the pasteboard it was read from moves on from it. False when nothing was sent: `request` was answered or
    /// ended already, or no connection carries the clipboard.
    @discardableResult
    func offer(_ source: ClipboardOfferSource, answering request: OfferRequest?) -> Bool {
        if let request, requests.remove(request.token) == nil { return false }
        endRemote(.superseded)
        guard let link else { return false }
        // A far-side offer still being read predates this side's offer too.
        for token in reading { link.releaseOffer(token) }
        reading.removeAll()
        withdrawLocal()
        let token = Self.freshToken()
        local = .opening(token: token, source: source)
        let offer = ItemOffer(
            token: token, concealed: source.concealed, items: source.items, after: after,
            request: request?.token ?? Data())
        send(offer, on: link) { [weak self] opened in
            self?.answered(token, opened: opened)
            guard let request else { return }
            if opened {
                link.releaseOffer(request.token)
            } else {
                link.refuseOffer(request.token, WireError(.cancelled, debugDetail: "the answer was not opened"))
            }
        }
        source.whenMovedOn { [weak self, weak source] in
            guard let self, let source else { return }
            self.movedOn(from: source)
        }
        return true
    }

    /// The pasteboard `source` was read from moved on: this side's offer of it, sent or open, is withdrawn.
    private func movedOn(from source: ClipboardOfferSource) {
        switch local {
        case .opening(_, let offered), .open(_, let offered):
            guard offered === source else { return }
            logger.log(.notice, "The clipboard moved on from what this side offered: the offer is withdrawn")
            withdrawLocal()
        case .none:
            return
        }
    }

    /// The `after` this side's next offer carries: a guest's names the last host offer it received.
    private var after: Data { side == .guest ? lastLinkToken ?? Data() : Data() }

    /// The connection answered this side's offer `token`: it is this end's clipboard now, unless something
    /// withdrew or replaced it while it opened, when it is withdrawn at once.
    private func answered(_ token: Data, opened: Bool) {
        guard case .opening(let opening, let source) = local, opening == token else {
            let code = abandoned.removeValue(forKey: token) ?? .cancelled
            if opened { link?.withdrawOffer(token, code: code) }
            return
        }
        guard opened else {
            local = .none
            return
        }
        local = .open(token: token, source: source)
        if side == .host { lastLinkToken = token }
    }

    /// Sends `offer` on `link`, hearing on the main actor whether it opened.
    private func send(
        _ offer: ItemOffer, on link: any ClipboardItemLink, _ opened: @escaping @MainActor (Bool) -> Void
    ) {
        let logger = logger
        let count = offer.items.count
        link.offerItems(offer) { refusal in
            if let refusal {
                logger.log(
                    .notice, "The clipboard offer was not opened: \(String(describing: refusal), privacy: .public)")
            } else {
                logger.log(.notice, "Offered the clipboard: \(count, privacy: .public) item(s)")
            }
            MainActorBridge.async { opened(refusal == nil) }
        }
    }

    /// Withdraws this side's offer, sent or open, RESET with `code`: `CANCELLED` when this end's clipboard moved
    /// on, `DISABLED_BY_POLICY` when the clipboard setting changed, `CAPABILITY_WITHDRAWN` when this side can no
    /// longer offer for another reason (``ending(_:)`` reads each); no newer one follows. The far side's offer, if
    /// it is this end's clipboard, stays so.
    func withdrawLocal(_ code: ErrorCode = .cancelled) {
        switch local {
        case .none: break
        case .opening(let token, _): abandoned[token] = code
        case .open(let token, _): link?.withdrawOffer(token, code: code)
        }
        local = .none
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
        let opening: Data? = if case .opening(let token, _) = local { token } else { nil }
        if let sent = opening ?? lastLinkToken, header.after != sent { return true }
        return holdsUnsentCopy()
    }

    // MARK: Requests

    /// The host: asks the far side, over `link` — the one this end runs over — to offer its clipboard as it
    /// stands now, by a request this end holds open until an offer answering it arrives, which this end takes
    /// whatever its gate, or the far side refuses it (``onRequestRefused``). A request made while one is open
    /// replaces it.
    func requestOffer(on link: any ClipboardHostItemLink) {
        if let open = request {
            request = nil
            link.withdrawOffer(open, code: .itemOfferReplaced)
        }
        let token = Self.freshToken()
        request = token
        let logger = logger
        link.requestOffer(token) { [weak self] refusal in
            guard let refusal else { return logger.log(.notice, "Asked the far side for its clipboard") }
            logger.log(
                .notice,
                "The request for the far side's clipboard was not opened: \(String(describing: refusal), privacy: .public)"
            )
            MainActorBridge.async { self?.requestEnded(token, refusedWith: refusal) }
        }
    }

    /// The host's request `token` ended, the far side or the connection refusing it with `error`.
    private func requestEnded(_ token: Data, refusedWith error: WireError) {
        guard request == token else { return }
        request = nil
        guard let refusal = Self.refusal(error) else {
            return logger.log(.notice, "The far side's clipboard holds only what this side's holds already")
        }
        onRequestRefused?(refusal)
    }

    /// Why a request refused with `error` was refused; nil for `CLIPBOARD_ALREADY_HELD`, an answer nobody is told
    /// of.
    static func refusal(_ error: WireError) -> RequestRefusal? {
        switch error.code {
        case .clipboardNothingToCopy: .nothingToCopy
        case .readFailed: .unreadable
        case .clipboardAlreadyHeld: nil
        default: .failed(error)
        }
    }

    /// A guest: refuses the host's `request` with `error`, which says why this side offers nothing.
    func refuseRequest(_ request: OfferRequest, _ error: WireError) {
        guard requests.remove(request.token) != nil else { return }
        link?.refuseOffer(request.token, error)
    }

    /// The host's request `token` arrived: a guest answers it once; the host takes none.
    private func receivedRequest(_ token: Data, on link: any ClipboardItemLink) {
        guard side == .guest, let onOfferRequested else {
            logger.log(.notice, "Refused a request for this side's clipboard, which this side does not answer")
            return link.refuseOffer(token, WireError(.unsupportedKind))
        }
        requests.insert(token)
        onOfferRequested(OfferRequest(token: token))
    }

    private static func freshToken() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: Serving

    /// The content of the representation of this side's offer that pull `id`'s `request` pulls, served from its
    /// source. Called on the pull's own queue, never the main thread: it waits for the main actor to read the
    /// source, and for as long as a promise it calls in takes, until the pull or its offer ends.
    nonisolated func content(_ id: ItemPullID, _ request: PullRequest) -> Result<ItemContent, WireError> {
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

    /// Serves `request` from this side's offer.
    private func serve(_ request: PullRequest) async -> Result<ItemContent, WireError> {
        guard let offered = openLocal, offered.token == request.token else {
            return .failure(WireError(.itemRepresentationUnavailable, debugDetail: "not this side's open offer"))
        }
        let source = offered.source
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
                if openLocal?.source === source { withdrawLocal() }
                return .failure(WireError(.itemRepresentationUnavailable, debugDetail: "the source is gone"))
            case .readFailed:
                return .failure(WireError(.readFailed, debugDetail: "the source could not be read"))
            }
        }
    }

    // MARK: The far side's offer

    /// Hands `event`, of the connection `link` names, to the exchange. Pulls' ends go to ``pullEnded(_:_:)``.
    func handle(_ event: ItemTransferEvent, on link: any ClipboardItemLink) {
        serves.end(by: event)
        switch event {
        case .offerRequested(let token):
            receivedRequest(token, on: link)
        case .requestEnded(.local, let token, let closure):
            guard case .resetByPeer(let error) = closure else {
                return requestEnded(
                    token, refusedWith: WireError(.cancelled, debugDetail: "the request ended unanswered"))
            }
            requestEnded(token, refusedWith: error)
        case .requestEnded(.remote, let token, _):
            requests.remove(token)
        case .offerReceived(let header):
            received(header, on: link)
        case .offerEnded(_, .local, let token, _):
            guard token == openLocal?.token else { return }
            local = .none
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

    /// How a far-side offer that ended with `closure` stopped being this end's clipboard, the same at both ends.
    /// Only the far side withdrawing it is `.byFarSide`: RESET `CANCELLED`, or `ITEM_OFFER_REPLACED` when its next
    /// offer follows. `DISABLED_BY_POLICY` is the clipboard setting changing. Every other end,
    /// `CAPABILITY_WITHDRAWN` from a side the feature stopped being usable on included, is the link ending: the far
    /// side's clipboard may hold it still.
    static func ending(_ closure: StreamClosure) -> RemoteEnding {
        guard case .resetByPeer(let error) = closure else { return .linkLost }
        switch error.code {
        case .cancelled: return .byFarSide(hasSuccessor: false)
        case .itemOfferReplaced: return .byFarSide(hasSuccessor: true)
        case .disabledByPolicy: return .settingChanged
        default: return .linkLost
        }
    }

    /// A pull of the far side's offer ended: handled where it arrives, on any queue.
    nonisolated func pullEnded(_ id: ItemPullID, _ result: ItemPullResult) {
        pulls.ended(id, result)
    }

    /// Releases `remote`, which this end's pasteboard no longer holds: this side pulls nothing more of it, and
    /// what it landed stays servable.
    func release(_ remote: ClipboardRemoteOffer) {
        if self.remote === remote { self.remote = nil }
        remote.release()
    }

    /// Reads every item of the far side's offer `header`, then hands the offer over, unless it ended meanwhile.
    /// First an offer this end's gate does not admit is refused unread `DISABLED_BY_POLICY` (``admits(_:)``),
    /// and the host refuses, unread, a guest offer that crosses a copy of its own.
    private func received(_ header: ItemSetHeaderValue, on link: any ClipboardItemLink) {
        guard admits(header) else {
            logger.log(.notice, "Refused, unread, a far-side clipboard offer this end's gate does not admit")
            return link.refuseOffer(header.token, WireError(.disabledByPolicy))
        }
        // The far side answered this end's request: nothing else answers it.
        if !header.request.isEmpty { request = nil }
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
        case .offerReceived, .offerEnded, .offerRequested, .requestEnded, .pullEnded:
            break
        }
    }
}
