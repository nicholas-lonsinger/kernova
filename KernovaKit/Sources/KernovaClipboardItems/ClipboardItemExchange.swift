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
///   receiver holds each copy it received until its end releases it. A copy that arrives while an earlier one is
///   still landing supersedes it: the earlier one is refused there and then, and never written
///   (``land(_:then:)``). What a copy names of the receiver's own offers by reference
///   (`Representation.reference`) is filled from those offers as they stood when it arrived, never pulled. A copy
///   this side sent whose files are served from another connection's offer is withdrawn once that offer ends.
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

    /// How landing a copy ended (``land(_:then:)``).
    public enum CopyLanding: Sendable, Equatable {
        /// Every INLINE representation landed and no newer copy arrived: the end wrote it. `referencesLeftOut`
        /// counts the representations naming this side's own offer that it could no longer fill.
        case written(referencesLeftOut: Int)
        /// The copy is only references to one offer of this side's that this end's pasteboard still holds: it
        /// was refused `CLIPBOARD_ALREADY_HELD`, and nothing written.
        case alreadyHeld
        /// A newer copy arrived before this one landed, and refused it `ITEM_OFFER_REPLACED`, or it ended: nothing
        /// was written.
        case superseded
        /// A pull of it failed with this error, and it was refused with it; nothing was written.
        case failed(WireError)
    }

    /// The guest's answer to the host's ask for its clipboard (``askForCopy(_:)``).
    public enum CopyAnswer: Sendable {
        /// The guest's copy, its items read; the host holds it until ``releaseCopy(_:)`` or
        /// ``refuseCopy(_:_:)``.
        case copy(ClipboardRemoteOffer)
        /// The guest's clipboard holds nothing to copy.
        case nothing
        /// No copy came, and why: the connection left, the ask was not sent, or the guest refused it.
        case failed(WireError)
    }

    /// The host's ask for a snapshot of a guest's clipboard, which the guest answers once: with
    /// ``answer(_:with:)``, or ``decline(_:_:)``.
    public struct CopyAsk: Sendable, Hashable {
        fileprivate let token: Data
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
    /// The host: the guest's first offer on a connection reported an empty clipboard it did not change while
    /// unlinked, or cannot say whether it did, so the copy of this side's it held went with the last connection.
    public var onEmptyReturn: (() -> Void)?
    /// A guest: the host asks for a snapshot of this side's clipboard, to be answered once.
    public var onCopyAsked: ((CopyAsk) -> Void)?
    /// A guest: the host sent a copy of its clipboard, its items read; this end holds it until it releases it.
    public var onCopyReceived: ((ClipboardRemoteOffer) -> Void)?
    /// Hears each copy this end held that ended before it let it go: the connection left, or the far side
    /// withdrew it. What this end wrote of it can be pulled no more.
    public var onCopyEnded: ((ClipboardRemoteOffer) -> Void)?
    /// Hears each copy this side sent that the far side refused, and why: `CLIPBOARD_CHANGED` when its clipboard
    /// changed before the copy landed, `TOO_LARGE` over its paste ceiling, `CLIPBOARD_FILES_WITHHELD` when it
    /// was written without its files.
    public var onCopyRefused: ((_ copy: ClipboardOfferSource, _ error: WireError) -> Void)?
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
    /// The host: the ask awaiting the guest's answer on `link`, everyone waiting on it, and the guest's copy
    /// answering it once one arrived.
    private var ask: (token: Data, answers: [(CopyAnswer) -> Void], answeredBy: Data?)?
    /// A guest: the host's asks on `link` still to be answered.
    private var asks: Set<Data> = []
    /// The far side's newest copy on `link`, from its arrival until it is written: the one copy landing. A copy
    /// arriving refuses the one here before it.
    private var landing: Data?
    /// This side's offers each copy of the far side's on `link` may name by reference, as they stood when the
    /// copy arrived, by the copy's token: what the far side could see when it made the copy.
    private var fillSources: [Data: [Data: ClipboardOfferSource]] = [:]
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

    /// The connection this exchange runs over now, renewed each time its link is set: what the far side's offers
    /// arriving now arrived on, and what a snapshot sent as a copy now goes over.
    public private(set) var connection = ClipboardConnectionID()

    // MARK: The connection

    /// Runs over `link` from now on, or over nothing; this sends nothing. Every offer and copy the connection
    /// before carried ends here: the far side's offer as `.linkLost`, each copy held through ``onCopyEnded``,
    /// their pulls cancelled; this side's, whose ends follow as events; and an ask unanswered. What a new
    /// connection is offered is the end's to read from its pasteboard then.
    public func setLink(_ link: (any ClipboardItemLink)?) {
        self.link = link
        connection = ClipboardConnectionID()
        opening = nil
        localToken = nil
        localSource = nil
        lastLinkToken = nil
        heardOnLink = false
        reading.removeAll()
        readingCopies.removeAll()
        sentCopies.removeAll()
        asks.removeAll()
        landing = nil
        fillSources.removeAll()
        answerAsk(.failed(WireError(.cancelled, debugDetail: "the connection left")))
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
    /// connection says whether its clipboard changed while unlinked (`unlinkedChange`).
    public func offer(_ source: ClipboardOfferSource, unlinkedChange: ClipboardUnlinkedChange? = nil) {
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
            unlinkedChange: side == .guest ? unlinkedChange : nil)
        send(offer, on: link) {
            [weak self] opened in self?.answered(token, opened: opened)
        }
    }

    /// A guest: this side's first offer on a connection, when its clipboard offers nothing of its own: a report
    /// of no items saying whether its clipboard changed while unlinked, which the host releases.
    public func reportEmpty(_ unlinkedChange: ClipboardUnlinkedChange) {
        withdrawLocal()
        guard side == .guest, let link else { return }
        send(
            ItemOffer(token: Self.freshToken(), items: [], after: after, unlinkedChange: unlinkedChange), on: link
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
        let role =
            switch offer.copy {
            case .notACopy: ""
            case .snapshot: " as a copy"
            case .ask: " as an ask"
            }
        link.offerItems(offer) { refusal in
            if let refusal {
                logger.log(
                    .notice, "The clipboard offer was not opened: \(String(describing: refusal), privacy: .public)")
            } else {
                logger.log(
                    .notice, "Offered the clipboard\(role, privacy: .public): \(count, privacy: .public) item(s)")
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

    /// Sends `source` to the far side as a copy: served from `source` until the far side lets it go, whatever
    /// this end's clipboard does meanwhile. Returns whether a connection carried it.
    @discardableResult
    public func sendCopy(_ source: ClipboardOfferSource) -> Bool {
        sendCopy(source, answering: nil)
    }

    /// Sends `source` as a copy, naming the ask it answers, and hears on the main actor whether it opened.
    @discardableResult
    private func sendCopy(
        _ source: ClipboardOfferSource, answering ask: Data?, opened: @escaping @MainActor (Bool) -> Void = { _ in }
    ) -> Bool {
        guard let link else { return false }
        let token = Self.freshToken()
        sentCopies[token] = source
        let offer = ItemOffer(
            token: token, concealed: source.concealed, items: source.items, after: ask ?? Data(), copy: .snapshot)
        send(offer, on: link) { [weak self] wasOpened in
            opened(wasOpened)
            guard !wasOpened, let self, let source = self.sentCopies.removeValue(forKey: token) else { return }
            self.onCopyRefused?(source, WireError(.cancelled, debugDetail: "the copy was not opened"))
        }
        source.whenUpstreamEnds { [weak self] in self?.withdrawCopy(token) }
        return true
    }

    /// Ends this side's copy `token`, if the far side still holds it: an offer a file of it is served from
    /// ended, so the far side's write of it is owed a retraction, as at a link's end.
    private func withdrawCopy(_ token: Data) {
        guard sentCopies.removeValue(forKey: token) != nil else { return }
        logger.log(.notice, "What a clipboard copy's files were served from ended: the copy is withdrawn")
        link?.withdrawOffer(token)
    }

    /// The host: asks the guest for a snapshot of its clipboard as it stands now; `answer` hears the guest's
    /// answer once. An ask made while one is unanswered joins it.
    public func askForCopy(_ answer: @escaping (CopyAnswer) -> Void) {
        if ask != nil { return ask?.answers.append(answer) ?? () }
        guard side == .host, let link else {
            return answer(.failed(WireError(.cancelled, debugDetail: "no connection carries the clipboard")))
        }
        let token = Self.freshToken()
        ask = (token, [answer], nil)
        send(ItemOffer(token: token, items: [], copy: .ask), on: link) { [weak self] opened in
            guard !opened, let self, self.ask?.token == token else { return }
            self.answerAsk(.failed(WireError(.cancelled, debugDetail: "the ask was not opened")))
        }
    }

    /// Ends the host's ask, everyone waiting on it hearing `answer`.
    private func answerAsk(_ answer: CopyAnswer) {
        guard let ask else { return }
        self.ask = nil
        for waiting in ask.answers { waiting(answer) }
    }

    /// A guest: answers the host's `ask` with a copy of `source`, served as ``sendCopy(_:)`` serves one. The ask
    /// is released once the copy opens, or refused when it does not.
    public func answer(_ ask: CopyAsk, with source: ClipboardOfferSource) {
        guard asks.remove(ask.token) != nil, let link else { return }
        sendCopy(source, answering: ask.token) { opened in
            if opened {
                link.releaseOffer(ask.token)
            } else {
                link.refuseOffer(ask.token, WireError(.cancelled, debugDetail: "the answer was not opened"))
            }
        }
    }

    /// A guest: answers the host's `ask` with no copy, saying why with `error`: ``ErrorCode/clipboardNothingToCopy``,
    /// or ``ErrorCode/tooLarge`` with the ceiling.
    public func decline(_ ask: CopyAsk, _ error: WireError) {
        guard asks.remove(ask.token) != nil else { return }
        link?.refuseOffer(ask.token, error)
    }

    /// Lets `copy` go: this end's clipboard no longer holds what it wrote of it, so the far side serves it no
    /// more.
    public func releaseCopy(_ copy: ClipboardRemoteOffer) {
        fillSources[copy.token] = nil
        if landing == copy.token { landing = nil }
        guard copies.removeValue(forKey: copy.token) != nil else { return }
        copy.release()
    }

    /// Refuses `copy` with `error`, written nowhere: the far side hears why.
    public func refuseCopy(_ copy: ClipboardRemoteOffer, _ error: WireError) {
        fillSources[copy.token] = nil
        if landing == copy.token { landing = nil }
        guard copies.removeValue(forKey: copy.token) != nil else { return }
        copy.refuse(error)
    }

    /// A copy of the far side's arrived: an ask, an answer to this side's ask, or a copy for this end to write.
    private func receivedCopy(_ header: ItemSetHeaderValue, on link: any ClipboardItemLink) {
        switch (side, header.copy) {
        case (.guest, .ask):
            asks.insert(header.token)
            onCopyAsked?(CopyAsk(token: header.token))
            return
        case (.guest, .snapshot) where header.count > 0:
            break
        case (.host, .snapshot):
            guard let ask, header.after == ask.token, ask.answeredBy == nil else {
                logger.log(.notice, "Refused a guest clipboard copy that answers no ask of the host's")
                link.releaseOffer(header.token)
                return
            }
            self.ask?.answeredBy = header.token
            guard header.count > 0 else {
                link.releaseOffer(header.token)
                return answerAsk(.failed(WireError(.streamProtocolError, debugDetail: "a copy of no items")))
            }
        case (.guest, _), (.host, _):
            logger.log(.notice, "Refused a clipboard copy this side does not take")
            link.releaseOffer(header.token)
            return
        }
        supersedeLanding(by: header.token, on: link)
        var sources = sentCopies
        if let localToken, let localSource { sources[localToken] = localSource }
        fillSources[header.token] = sources
        readingCopies.insert(header.token)
        readItems(of: header, on: link) { [weak self] items in self?.copyRead(header, items, on: link) }
    }

    /// The far side's copy `token` arrived: the copy still landing before it, read or not, is refused
    /// `ITEM_OFFER_REPLACED` and never written.
    private func supersedeLanding(by token: Data, on link: any ClipboardItemLink) {
        defer { landing = token }
        guard let older = landing else { return }
        fillSources[older] = nil
        logger.log(.notice, "A newer clipboard copy arrived before the last one landed: the last is not written")
        let replaced = WireError(.itemOfferReplaced, debugDetail: "a newer copy arrived before this one landed")
        if readingCopies.remove(older) != nil { return link.refuseOffer(older, replaced) }
        copies.removeValue(forKey: older)?.refuse(replaced)
    }

    /// Fills every representation of `copy` that names this side's own offer by reference, from that offer's
    /// sources as they stand now, lands every INLINE one, then has `write` write it — synchronously, unless a
    /// newer copy arrived meanwhile, so an older copy never writes over a newer one. `write` hears how many
    /// references it could not fill, which it leaves out. A copy of only references to one offer this end's
    /// pasteboard still holds changes nothing, so it is refused `CLIPBOARD_ALREADY_HELD`; a failed pull refuses
    /// it too. `write` decides everything after: whether to write, and whether to release or refuse it.
    @discardableResult
    public func land(_ copy: ClipboardRemoteOffer, then write: @MainActor (_ referencesLeftOut: Int) -> Void) async
        -> CopyLanding
    {
        guard landing == copy.token else { return .superseded }
        let sources = fillSources.removeValue(forKey: copy.token) ?? [:]
        let references = copy.references
        if copy.isOnlyReferences, let offer = references.first?.reference.offer,
            references.allSatisfy({ $0.reference.offer == offer }), sources[offer]?.standsOnItsPasteboard == true
        {
            logger.log(.notice, "A clipboard copy names only what this side's clipboard holds: nothing written")
            landing = nil
            refuseCopy(copy, WireError(.clipboardAlreadyHeld))
            return .alreadyHeld
        }
        var leftOut = 0
        for (item, representation, reference) in references {
            guard let source = sources[reference.offer],
                let served = try? await source.serve(
                    item: Int(reference.item), representation: Int(reference.representation)),
                await copy.fill(
                    item: item, representation: representation, with: served, copying: Self.isOwned(served, by: source))
            else {
                leftOut += 1
                continue
            }
        }
        guard landing == copy.token else { return .superseded }
        if let error = await copy.landInline() {
            guard landing == copy.token else { return .superseded }
            landing = nil
            refuseCopy(copy, error)
            return .failed(error)
        }
        guard landing == copy.token else { return .superseded }
        landing = nil
        if leftOut > 0 {
            logger.log(.notice, "\(leftOut, privacy: .public) reference(s) of a clipboard copy could not be filled")
        }
        write(leftOut)
        return .written(referencesLeftOut: leftOut)
    }

    /// Whether `served` is a file of `source`'s own staging, which goes when `source` does.
    private static func isOwned(_ served: ClipboardServedRepresentation, by source: ClipboardOfferSource) -> Bool {
        switch served {
        case .bytes: false
        case .file(let url), .folder(let url): source.owns(url)
        }
    }

    private func copyRead(_ header: ItemSetHeaderValue, _ items: [OfferedItem]?, on link: any ClipboardItemLink) {
        guard readingCopies.remove(header.token) != nil else { return }
        guard let items else {
            fillSources[header.token] = nil
            if landing == header.token { landing = nil }
            logger.log(.notice, "The far side's clipboard copy ended before its items were read")
            link.releaseOffer(header.token)
            if ask?.answeredBy == header.token {
                answerAsk(.failed(WireError(.cancelled, debugDetail: "the copy ended before it was read")))
            }
            return
        }
        let copy = remoteOffer(header, items, on: link)
        copies[header.token] = copy
        logger.log(.notice, "Received a clipboard copy: \(items.count, privacy: .public) item(s)")
        switch side {
        case .host:
            guard ask?.answeredBy == header.token else { return releaseCopy(copy) }
            answerAsk(.copy(copy))
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
            if case .bytes = served, sentCopies[request.token] === source {
                source.spend(item: Int(request.item), representation: Int(request.representation))
            }
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
            if header.copy == .notACopy { received(header, on: link) } else { receivedCopy(header, on: link) }
        case .offerEnded(_, .local, let token, let closure):
            if let source = sentCopies.removeValue(forKey: token) {
                if case .resetByPeer(let error) = closure { onCopyRefused?(source, error) }
                return
            }
            if let ask, ask.token == token {
                // A guest releases its ask once its copy answering it opened, which arrived first.
                if case .resetByPeer(let error) = closure {
                    answerAsk(Self.answer(declined: error))
                } else if ask.answeredBy == nil {
                    answerAsk(.failed(WireError(.cancelled, debugDetail: "the ask ended unanswered")))
                }
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
            asks.remove(token)
            fillSources[token] = nil
            if landing == token { landing = nil }
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

    /// The host's answer when the guest refused its ask with `error`.
    static func answer(declined error: WireError) -> CopyAnswer {
        switch error.code {
        case .clipboardNothingToCopy: .nothing
        default: .failed(error)
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
                if first, header.unlinkedChange != .changed { onEmptyReturn?() }
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
            header: header, items: items, link: link, connection: connection, staging: staging,
            generation: generation,
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
