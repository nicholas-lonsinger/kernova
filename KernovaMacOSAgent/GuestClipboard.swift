import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaKit
import KernovaLogging
import KernovaPlatformDarwin
import KernovaWire

/// The guest's clipboard over the session peer's CLIPBOARD items: each copy in this session offered to the host
/// while the session owns the console and its connection can use the feature, and each host offer published on
/// the guest pasteboard, its bytes pulled only when a paste asks for them.
@MainActor
final class GuestClipboard {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestClipboard")
    private static let pollingInterval: TimeInterval = 0.5

    /// The exchange both directions run through.
    let exchange: ClipboardItemExchange

    private let pasteboard: any ClipboardPasteboard
    /// Where a copied file promise is called in when the host pulls it.
    private let promiseStaging: ClipboardFileStaging
    private var nextPromiseGeneration: UInt64 = 1
    /// The one write choke point a host offer reaches the guest pasteboard through. Its provider registry is
    /// this agent's own: the providers it holds are the guest pasteboard's alone.
    private let publisher: ClipboardPasteboardPublisher
    private let onNotice: @Sendable () -> Void

    private var onConsole = false
    private var link: (any ClipboardItemLink)?
    /// The pasteboard change last seen by the poll, moved past every write this agent makes so its own
    /// promise is never read as a copy.
    private var seenChangeCount: Int
    /// The change of the pasteboard whose read is in flight.
    private var readingChangeCount: Int?
    /// The host offer the guest pasteboard was last written with.
    private var published: ClipboardRemoteOffer?
    private var pollingTimer: Timer?

    /// The latest clipboard activity, for the menu-bar status line.
    private(set) var activity: ClipboardActivity = .disabled

    /// A clipboard over `pasteboard`, landing the host's files and calling in copied promises under
    /// `stagingRoot`, and raising `onNotice` when a refusal lands in ``activity``. Each pull lands no more than
    /// `pasteCeiling` bytes until the host's policy sets it.
    init(
        pasteboard: any ClipboardPasteboard, stagingRoot: ProcessStagingRoot,
        pasteCeiling: Int = ClipboardPasteLimit.defaultBytes, onNotice: @escaping @Sendable () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.onNotice = onNotice
        exchange = ClipboardItemExchange(
            side: .guest, stagingLabel: "agent", stagingRoot: stagingRoot, pasteCeiling: pasteCeiling, logger: Self.logger)
        promiseStaging = ClipboardFileStaging(label: "agent-promises", root: stagingRoot)
        publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        seenChangeCount = pasteboard.changeCount
        exchange.onRemoteOffer = { [weak self] in self?.publish($0) }
        exchange.onRemoteOfferEnded = { [weak self] remote, ending in
            switch ending {
            case .byFarSide: self?.retract(remote)
            case .superseded: if self?.published === remote { self?.published = nil }
            case .linkLost: break
            }
        }
        exchange.onServed = { [weak self] in self?.activity = .sentToHost }
        exchange.onLanded = { [weak self] in self?.activity = .receivedFromHost }
    }

    /// The general pasteboard's clipboard.
    convenience init(stagingRoot: ProcessStagingRoot, onNotice: @escaping @Sendable () -> Void) {
        self.init(pasteboard: NSPasteboard.general, stagingRoot: stagingRoot, onNotice: onNotice)
    }

    /// CLIPBOARD's owner on the session peer's connection, calling into it through `calls`.
    nonisolated func owner(calls: PeerItemCalls) -> ItemFeatureOwner<Void> {
        let exchange = exchange
        let link = AgentClipboardLink(calls: calls)
        return ItemFeatureOwner(
            usable: { [weak self] usable in
                MainActorBridge.async { self?.setLink(usable == nil ? nil : link) }
            },
            events: { _, event in
                if case .pullEnded(_, let id, let result) = event { return exchange.pullEnded(id, result) }
                MainActorBridge.async { exchange.handle(event, on: link) }
            },
            content: { exchange.content($0, $1) },
            policy: { [weak self] policy in MainActorBridge.async { self?.apply(policy) } })
    }

    /// Takes the paste ceiling the host's policy sets, the default when it sets none, for every later publish
    /// and pull.
    func apply(_ policy: PolicySnapshot) {
        let ceiling = ClipboardPasteLimit.fromPolicy(ClipboardPolicyValue(policy)?.maxPasteBytes ?? 0)
        guard ceiling != exchange.pasteCeilingBytes else { return }
        exchange.setPasteCeiling(ceiling)
        Self.logger.log(.notice, "The host sets the paste ceiling to \(ceiling, privacy: .public) bytes")
    }

    // MARK: Gating

    /// Whether this session owns the console now.
    func setOnConsole(_ onConsole: Bool) {
        let was = isOffering
        self.onConsole = onConsole
        gateChanged(from: was)
    }

    /// The connection that can use CLIPBOARD now, or none.
    func setLink(_ link: (any ClipboardItemLink)?) {
        let was = isOffering
        self.link = link
        exchange.setLink(link)
        if link == nil {
            activity = .disabled
            pollingTimer?.invalidate()
            pollingTimer = nil
        } else {
            if case .disabled = activity { activity = .enabled }
            startPolling()
        }
        gateChanged(from: was)
    }

    /// Copies are offered while this is true.
    var isOffering: Bool { onConsole && link != nil }

    private func gateChanged(from was: Bool) {
        guard isOffering, !was else { return }
        Self.logger.log(.notice, "The clipboard is offered to the host again")
        readAndOffer(pasteboard.changeCount)
    }

    // MARK: Guest → host

    private func startPolling() {
        guard pollingTimer == nil else { return }
        // A run-loop timer, in the default mode only: a poll reading this agent's own promise fires its provider,
        // whose wait drains the main queue only from the run loop's base (`NestedEventLoopWait`).
        pollingTimer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
    }

    /// A copy since the last poll replaces the host's offer standing on the pasteboard, which this side then
    /// releases, and is offered to the host while ``isOffering``.
    func checkPasteboard() {
        let changeCount = pasteboard.changeCount
        guard changeCount != seenChangeCount else { return }
        seenChangeCount = changeCount
        if let published {
            self.published = nil
            exchange.release(published)
        }
        guard isOffering else { return }
        readAndOffer(changeCount)
    }

    /// Reads the pasteboard as it stands at `changeCount` and offers it, unless it is this agent's own write or
    /// has moved on by the time the read lands.
    private func readAndOffer(_ changeCount: Int) {
        guard changeCount != publisher.lastWriteChangeCount, readingChangeCount != changeCount else { return }
        readingChangeCount = changeCount
        let promiseStaging = promiseStaging
        let generation = nextPromiseGeneration
        nextPromiseGeneration += 1
        let receivers = pasteboard.filePromiseReceivers
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await ClipboardPasteboardReader.readOffer(
                from: pasteboard, promises: receivers,
                promiseDestination: { try promiseStaging.reserveScratchDirectory(generation: generation) })
            if readingChangeCount == changeCount { readingChangeCount = nil }
            guard pasteboard.changeCount == changeCount, isOffering else { return }
            switch outcome {
            case .offer(let source, let lost):
                exchange.offer(source)
                activity = lost > 0 ? .copyPartlyCarried(skipped: lost) : .offeredToHost
                if lost > 0 { onNotice() }
            case .nothingOfferable:
                exchange.withdrawLocal()
                activity = .copyCarriedNothing
                onNotice()
            case .empty, .suppressed:
                exchange.withdrawLocal()
            }
        }
    }

    // MARK: Host → guest

    /// Publishes the host's offer on the guest pasteboard, promised: nothing is pulled until a paste asks. A file
    /// set over the paste ceiling is published without its file URLs, and the refusal shown.
    private func publish(_ remote: ClipboardRemoteOffer) {
        let ceiling = exchange.pasteCeilingBytes
        let budget = ClipboardPromisePolicy.pasteBudget(remote.items, limit: ceiling)
        let written = publisher.publish(
            remote.items, concealed: remote.concealed, servingFileURLs: !budget.exceeds, puller: remote)
        if let changeCount = publisher.lastWriteChangeCount { seenChangeCount = changeCount }
        guard written else {
            Self.logger.log(.error, "The host's clipboard offer could not be written to the pasteboard")
            exchange.release(remote)
            return
        }
        published = remote
        if budget.exceeds {
            Self.logger.log(
                .notice,
                "The host's files total \(budget.total, privacy: .public) bytes, over the \(ceiling, privacy: .public)-byte paste ceiling: published without them"
            )
            activity = .pasteRefused(.copyTooLarge, pasteLimitBytes: ceiling)
            onNotice()
        } else {
            activity = .offeredFromHost
        }
    }

    /// The host's clipboard moved on: a promise still standing for its offer could serve only what already
    /// landed, so it is withdrawn, unless a copy has replaced it since. An offer ended by the connection leaving
    /// keeps its promise, serving what landed, until the host's return offers what it holds then.
    private func retract(_ remote: ClipboardRemoteOffer) {
        guard published === remote else { return }
        published = nil
        guard publisher.retractPromisedWrite() else { return }
        // The clear moved the pasteboard on; the poll must not read that as a copy.
        seenChangeCount = pasteboard.changeCount
    }

    /// Stops polling; the pasteboard's promises keep serving what already landed.
    func stop() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
}

/// CLIPBOARD's calls through the session peer's connection.
struct AgentClipboardLink: ClipboardItemLink {
    let calls: PeerItemCalls

    func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
        calls.offerItems(offer, feature: .clipboard, completion)
    }

    func withdrawOffer(_ token: Data) { calls.withdrawOffer(token) }
    func releaseOffer(_ token: Data) { calls.releaseOffer(token) }

    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        calls.readItem(token, item: item, completion)
    }

    func pullItem(_ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void) {
        calls.pullItem(order, completion)
    }

    func cancelPull(_ id: ItemPullID) { calls.cancelPull(id) }

    func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding
    ) throws(WireError) -> ItemPullOrder {
        try calls.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing)
    }
}
