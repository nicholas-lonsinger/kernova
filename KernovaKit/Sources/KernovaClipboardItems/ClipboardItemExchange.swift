import Dispatch
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaKit
import KernovaLogging
import KernovaSynchronization
import KernovaWire

/// One end's clipboard over CLIPBOARD items, the same at the host and the macOS guest agent: its own offer and
/// the far side's, over whichever connection can use the feature now.
///
/// - This side's offer is one ``ClipboardOfferSource`` at a time. It is held across connections, so
///   ``reofferLocal()`` sends it again on a new one, and each pull of it is served from it.
/// - The far side's offer arrives as ``ClipboardRemoteOffer``, its items read whole, for the end to publish. The
///   end releases it once its pasteboard has moved on.
///
/// Offers and ends hop onto the main actor in the order the connection emitted them; a pull's end is handled on
/// the connection's queue, so a paste waiting on a pull never needs the main actor.
@MainActor
public final class ClipboardItemExchange {
    /// Hears each offer of the far side once its items are read.
    public var onRemoteOffer: ((ClipboardRemoteOffer) -> Void)?
    /// Hears each offer of the far side that ended: `byFarSide` when the far side ended it, its clipboard having
    /// moved on, and false when the connection left or no longer carries the feature.
    public var onRemoteOfferEnded: ((_ offer: ClipboardRemoteOffer, _ byFarSide: Bool) -> Void)?
    /// Hears each pull of this side's offer that it served.
    public var onServed: (() -> Void)?
    /// Hears each pull of the far side's offer that landed here.
    public var onLanded: (() -> Void)?

    /// The far side's open offer, if any.
    public private(set) var remote: ClipboardRemoteOffer?
    /// This side's offer, held whether or not a connection carries it now.
    public private(set) var localSource: ClipboardOfferSource?

    private var link: (any ClipboardItemLink)?
    /// The token of `localSource`'s offer open on `link`, if it is.
    private var localToken: Data?
    /// The tokens of the far side's offers whose items are still being read.
    private var reading: Set<Data> = []
    private var nextGeneration: UInt64 = 1
    private let staging: ClipboardFileStaging
    private let pasteCeiling: Locked<Int>
    private let pulls = ClipboardPullRegistry()
    private let logger: KernovaLogger

    /// An exchange landing the far side's FILE and FOLDER representations in clipboard staging labelled
    /// `stagingLabel` under `stagingRoot`, each pull no larger than `pasteCeiling` bytes.
    public init(stagingLabel: String, stagingRoot: ProcessStagingRoot, pasteCeiling: Int, logger: KernovaLogger) {
        staging = ClipboardFileStaging(label: stagingLabel, root: stagingRoot)
        self.pasteCeiling = Locked(pasteCeiling)
        self.logger = logger
    }

    /// The most bytes one paste's file set, and any one pull, may land.
    public var pasteCeilingBytes: Int { pasteCeiling.withLock { $0 } }

    /// Changes ``pasteCeilingBytes`` for every later pull.
    public func setPasteCeiling(_ bytes: Int) {
        pasteCeiling.withLock { $0 = bytes }
    }

    /// Whether a connection can carry the clipboard now.
    public var isLinked: Bool { link != nil }

    // MARK: The connection

    /// Runs over `link` from now on, or over nothing. Offers open on the connection before are ended by it, or
    /// by its leaving, and their ends follow as events; this sends nothing.
    public func setLink(_ link: (any ClipboardItemLink)?) {
        self.link = link
        localToken = nil
    }

    // MARK: This side's offer

    /// Makes `source` this side's offer, replacing the one before, and offers it on the connection if there is
    /// one. A source with no items withdraws the offer before it and is held as nothing.
    public func offer(_ source: ClipboardOfferSource) {
        guard !source.items.isEmpty else { return withdrawLocal() }
        localSource = source
        send(source)
    }

    /// Offers the held source again, under a fresh token, on the current connection.
    public func reofferLocal() {
        guard let localSource else { return }
        send(localSource)
    }

    /// Withdraws this side's offer, and holds none.
    public func withdrawLocal() {
        if let localToken { link?.withdrawOffer(localToken) }
        localToken = nil
        localSource = nil
    }

    private func send(_ source: ClipboardOfferSource) {
        guard let link else {
            localToken = nil
            return
        }
        let token = Self.freshToken()
        localToken = token
        let logger = logger
        let count = source.items.count
        link.offerItems(ItemOffer(token: token, concealed: source.concealed, items: source.items)) { refusal in
            if let refusal {
                logger.log(
                    .notice, "The clipboard offer was not opened: \(String(describing: refusal), privacy: .public)")
            } else {
                logger.log(.notice, "Offered the clipboard: \(count, privacy: .public) item(s)")
            }
        }
    }

    private static func freshToken() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// The content of `representation` of this side's offer that `request` pulls, served from its source. Called
    /// on the pull's own queue, never the main thread: it waits for the main actor to read the source.
    nonisolated public func content(
        _ request: PullRequest, _ representation: Representation
    ) -> Result<ItemContent, WireError> {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let answer = Locked<Result<ItemContent, WireError>?>(nil)
        let served = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let result = await self.serve(request)
            answer.withLock { $0 = result }
            served.signal()
        }
        served.wait()
        return answer.withLock { $0 } ?? .failure(WireError(.itemRepresentationUnavailable))
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
                return .success(
                    .tree(
                        directory: url.deletingLastPathComponent().path, name: Array(url.lastPathComponent.utf8)))
            }
        } catch {
            switch error {
            case .unavailable:
                return .failure(WireError(.itemRepresentationUnavailable, debugDetail: "the source is gone"))
            case .readFailed:
                return .failure(WireError(.readFailed, debugDetail: "the source could not be read"))
            }
        }
    }

    // MARK: The far side's offer

    /// Hands `event`, of the connection `link` names, to the exchange. Pulls' ends go to ``pullEnded(_:_:)``.
    public func handle(_ event: ItemTransferEvent, on link: any ClipboardItemLink) {
        switch event {
        case .offerReceived(let header):
            received(header, on: link)
        case .offerEnded(_, .local, let token, _):
            if token == localToken { localToken = nil }
        case .offerEnded(_, .remote, let token, let closure):
            reading.remove(token)
            guard let remote, remote.token == token else { return }
            self.remote = nil
            remote.close()
            let byFarSide: Bool
            switch closure {
            case .completed, .resetByPeer: byFarSide = true
            case .resetLocally, .connectionClosedLocally, .connectionClosedByPeer, .connectionLost: byFarSide = false
            }
            onRemoteOfferEnded?(remote, byFarSide)
        case .pullEnded(_, let id, let result):
            pullEnded(id, result)
        case .serveEnded:
            break
        }
    }

    /// A pull of the far side's offer ended: handled where it arrives, on any queue.
    nonisolated public func pullEnded(_ id: ItemPullID, _ result: ItemPullResult) {
        pulls.ended(id, result)
    }

    /// Releases `remote`: this side pulls nothing more of it, and what it landed stays servable.
    public func release(_ remote: ClipboardRemoteOffer) {
        if self.remote === remote { self.remote = nil }
        remote.release()
    }

    /// Reads every item of the far side's offer `header`, then hands the offer over, unless it ended meanwhile.
    private func received(_ header: ItemSetHeaderValue, on link: any ClipboardItemLink) {
        if let remote {
            // The far side replaced its offer: the end of the one before is already on its way.
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
        guard held.count == items.count, !held.isEmpty else {
            logger.log(.notice, "The far side's clipboard offer ended before its items were read")
            link.releaseOffer(header.token)
            return
        }
        let ceiling = pasteCeiling
        let remote = ClipboardRemoteOffer(
            header: header, items: held, link: link, staging: staging, generation: generation,
            ceiling: { UInt64(clamping: max(ceiling.withLock { $0 }, 0)) }, registry: pulls, logger: logger,
            landed: { [weak self] in MainActorBridge.async { self?.onLanded?() } })
        self.remote = remote
        logger.log(.notice, "Received a clipboard offer: \(held.count, privacy: .public) item(s)")
        onRemoteOffer?(remote)
    }
}
