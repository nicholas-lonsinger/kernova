import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaKit
import KernovaLogging
import KernovaPlatformDarwin
import KernovaSynchronization
import KernovaWire

/// The guest's clipboard over the session peer's CLIPBOARD items: each copy in this session offered to the host
/// while the session owns the console and its connection can use the feature, and each host offer published on
/// the guest pasteboard, its bytes pulled only when a paste asks for them. The host's clipboard commands cross
/// as copies: a snapshot of this pasteboard sent when the host asks, and a host copy written here as data, its
/// files promised.
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
    /// The paste ceiling the host's policy sets: what the exchange's pulls read, from any thread.
    private let pasteCeiling: Locked<Int>

    private var onConsole = false
    private var link: (any ClipboardItemLink)?
    /// The pasteboard change last seen by the poll, moved past every write this agent makes so its own
    /// promise is never read as a copy.
    private var seenChangeCount: Int
    /// The change of the pasteboard whose read is in flight.
    private var readingChangeCount: Int?
    /// The host offer the guest pasteboard was last written with.
    private var published: ClipboardRemoteOffer?
    /// The pasteboard change when copies last stopped being offered, moved past every write this agent makes
    /// meanwhile: what the next connection's first offer reports a change against. Nil before the first.
    private var unlinkedChangeCount: Int?
    private var pollingTimer: Timer?

    /// The latest clipboard activity, for the menu-bar status line.
    private(set) var activity: ClipboardActivity = .disabled

    /// A clipboard over `pasteboard`, landing the host's representations and calling in copied promises under
    /// `stagingRoot`, and raising `onNotice` when a refusal lands in ``activity``. A paste lands no more than
    /// `pasteCeiling` bytes until the host's policy sets it.
    init(
        pasteboard: any ClipboardPasteboard, stagingRoot: ProcessStagingRoot,
        pasteCeiling: Int = ClipboardPasteLimit.defaultBytes, onNotice: @escaping @Sendable () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.onNotice = onNotice
        let ceiling = Locked(pasteCeiling)
        self.pasteCeiling = ceiling
        exchange = ClipboardItemExchange(
            side: .guest, stagingLabel: "agent", stagingRoot: stagingRoot, pasteCeiling: { ceiling.withLock { $0 } },
            logger: Self.logger)
        promiseStaging = ClipboardFileStaging(label: "agent-promises", root: stagingRoot)
        publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        seenChangeCount = pasteboard.changeCount
        exchange.onRemoteOffer = { [weak self] in self?.publish($0) }
        exchange.onRemoteOfferEnded = { [weak self] remote, ending in
            switch ending {
            case .byFarSide, .linkLost: self?.retract(remote)
            case .superseded: if self?.published === remote { self?.published = nil }
            }
        }
        exchange.onCopyAsked = { [weak self] in self?.sendSnapshot(answering: $0) }
        exchange.onCopyReceived = { [weak self] in self?.write($0) }
        exchange.onCopyEnded = { [weak self] copy in self?.retractWrite(servingOffer: copy.token) }
        exchange.onServed = { [weak self] in self?.activity = .sentToHost }
        exchange.onLanded = { [weak self] in self?.activity = .receivedFromHost }
        exchange.onPullFailed = { [weak self] in self?.pullFailed($0) }
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
            content: { exchange.content($0, $1, $2) },
            policy: { [weak self] policy in MainActorBridge.async { self?.apply(policy) } })
    }

    /// Takes the paste ceiling the host's policy sets, the default when it sets none, for every later publish
    /// and pull.
    func apply(_ policy: PolicySnapshot) {
        let ceiling = ClipboardPasteLimit.fromPolicy(ClipboardPolicyValue(policy)?.maxPasteBytes ?? 0)
        let changed = pasteCeiling.withLock { held in
            defer { held = ceiling }
            return held != ceiling
        }
        guard changed else { return }
        Self.logger.log(.notice, "The host sets the paste ceiling to \(ceiling, privacy: .public) bytes")
    }

    /// The paste ceiling in force.
    var pasteCeilingBytes: Int { pasteCeiling.withLock { $0 } }

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

    /// The gate opening offers the pasteboard as it stands, saying whether it changed while the gate was
    /// closed, and that change is seen: the poll offers only a later one. Closing it marks where that change is
    /// told from.
    private func gateChanged(from was: Bool) {
        guard isOffering != was else { return }
        let changeCount = pasteboard.changeCount
        guard isOffering else {
            unlinkedChangeCount = changeCount
            return
        }
        Self.logger.log(.notice, "The clipboard is offered to the host again")
        seenChangeCount = changeCount
        readAndOffer(changeCount, changedWhileUnlinked: unlinkedChangeCount.map { $0 != changeCount } ?? true)
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
    /// has moved on by the time the read lands. The connection's first offer, `changedWhileUnlinked` set, is
    /// made whatever the pasteboard holds: a report of no items when it offers nothing.
    private func readAndOffer(_ changeCount: Int, changedWhileUnlinked: Bool? = nil) {
        if let changedWhileUnlinked, changeCount == publisher.lastWriteChangeCount {
            return exchange.reportEmpty(changedWhileUnlinked: changedWhileUnlinked)
        }
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
                exchange.offer(source, changedWhileUnlinked: changedWhileUnlinked ?? false)
                activity = lost > 0 ? .copyPartlyCarried(skipped: lost) : .offeredToHost
                if lost > 0 { onNotice() }
            case .nothingOfferable:
                reportNothing(changedWhileUnlinked)
                activity = .copyCarriedNothing
                onNotice()
            case .empty, .suppressed:
                reportNothing(changedWhileUnlinked)
            }
        }
    }

    /// This side's clipboard offers nothing: its offer is withdrawn, and a connection's first offer reports it.
    private func reportNothing(_ changedWhileUnlinked: Bool?) {
        guard let changedWhileUnlinked else { return exchange.withdrawLocal() }
        exchange.reportEmpty(changedWhileUnlinked: changedWhileUnlinked)
    }

    /// Answers the host's ask with a snapshot of the pasteboard now — or nothing, off the console or with nothing
    /// to copy. A pasteboard that changed while it was read is read once more.
    private func sendSnapshot(answering ask: Data) {
        guard isOffering else {
            exchange.sendCopy(nil, answering: ask)
            return
        }
        let promiseStaging = promiseStaging
        let generation = nextPromiseGeneration
        nextPromiseGeneration += 1
        let receivers = pasteboard.filePromiseReceivers
        Task { @MainActor [weak self] in
            guard let self else { return }
            var outcome = ClipboardPasteboardReader.SnapshotOutcome.changed
            for _ in 0..<2 {
                outcome = await ClipboardPasteboardReader.readSnapshot(
                    from: pasteboard, promises: receivers,
                    promiseDestination: { try promiseStaging.reserveScratchDirectory(generation: generation) })
                if case .changed = outcome { continue }
                break
            }
            guard case .snapshot(let snapshot, let lost) = outcome else {
                Self.logger.log(.notice, "The host asked for the clipboard, which holds nothing to copy")
                exchange.sendCopy(nil, answering: ask)
                return
            }
            exchange.sendCopy(snapshot, answering: ask)
            activity = lost > 0 ? .copyPartlyCarried(skipped: lost) : .sentToHost
            if lost > 0 { onNotice() }
        }
    }

    // MARK: Host → guest

    /// Writes the host's copy once every INLINE representation landed, as data, its files promised — unless the
    /// pasteboard changed since the copy arrived, when it is left as it is and the host told why. A file set
    /// over the paste ceiling is left off, and the host told that too. The copy is released once the pasteboard
    /// lets its files go, or at once when it promised none.
    private func write(_ copy: ClipboardRemoteOffer) {
        let arrivedAt = pasteboard.changeCount
        Task { @MainActor [weak self] in
            if let error = await copy.landInline() {
                self?.exchange.refuseCopy(copy, error)
                if error.code == .tooLarge { self?.pullFailed(error) }
                return
            }
            guard let self else { return }
            guard pasteboard.changeCount == arrivedAt else {
                Self.logger.log(.notice, "The clipboard changed before the host's copy landed: left as it is")
                exchange.refuseCopy(copy, WireError(.clipboardChanged))
                return
            }
            let ceiling = pasteCeilingBytes
            let budget = ClipboardPromisePolicy.pasteBudget(copy.items, limit: ceiling)
            let (written, promised) = publisher.publishCopy(
                copy.items, concealed: copy.concealed, servingFileURLs: !budget.exceeds,
                landed: { copy.landedBytes(item: $0, representation: $1) }, puller: copy, servingOffer: copy.token,
                onReleased: { [weak self] in self?.exchange.releaseCopy(copy) })
            if let changeCount = publisher.lastWriteChangeCount { seenChangeCount = changeCount }
            guard written else {
                Self.logger.log(.error, "The host's clipboard copy could not be written to the pasteboard")
                exchange.refuseCopy(copy, WireError(.writeFailed))
                return
            }
            // The pasteboard holds the host's copy now, so neither current offer is this clipboard's.
            if let published {
                self.published = nil
                exchange.release(published)
            }
            exchange.withdrawLocal()
            activity = .receivedFromHost
            if budget.exceeds {
                exchange.refuseCopy(copy, WireError(.tooLarge, limit: UInt64(ceiling)))
                activity = .pasteRefused(.pasteTooLarge, pasteLimitBytes: ceiling)
                onNotice()
            } else if !promised {
                exchange.releaseCopy(copy)
            }
        }
    }

    /// Publishes the host's offer on the guest pasteboard, promised: nothing is pulled until a paste asks. A file
    /// set over the paste ceiling is published without its file URLs, and the refusal shown.
    private func publish(_ remote: ClipboardRemoteOffer) {
        let ceiling = pasteCeilingBytes
        let budget = ClipboardPromisePolicy.pasteBudget(remote.items, limit: ceiling)
        let written = publisher.publish(
            remote.items, concealed: remote.concealed, servingFileURLs: !budget.exceeds, puller: remote,
            servingOffer: remote.token)
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
            activity = .pasteRefused(.pasteTooLarge, pasteLimitBytes: ceiling)
            onNotice()
        } else {
            activity = .offeredFromHost
        }
    }

    /// A pull of the host's offer failed a paste: one over the paste ceiling — the representation, or the offer's
    /// file set — is shown as the refusal a publish over it shows.
    private func pullFailed(_ error: WireError) {
        guard error.code == .tooLarge else { return }
        let ceiling = pasteCeilingBytes
        Self.logger.log(
            .notice, "A paste of the host's clipboard is over the \(ceiling, privacy: .public)-byte paste ceiling")
        activity = .pasteRefused(.pasteTooLarge, pasteLimitBytes: ceiling)
        onNotice()
    }

    /// The host's offer ended — its clipboard moved on, or the connection carrying it left: a promise still
    /// standing for it could serve only what already landed, so it is withdrawn, unless a copy has replaced it
    /// since. The host's next connection offers what it holds then.
    private func retract(_ remote: ClipboardRemoteOffer) {
        guard published === remote else { return }
        published = nil
        retractWrite(servingOffer: remote.token)
    }

    /// Retracts this agent's write serving the offer `token`, if the pasteboard still holds it, as this agent's
    /// own change: the poll must not read it as a copy, nor the next connection's first offer as a change.
    private func retractWrite(servingOffer token: Data) {
        guard publisher.retractWrite(servingOffer: token) else { return }
        seenChangeCount = pasteboard.changeCount
        if !isOffering { unlinkedChangeCount = pasteboard.changeCount }
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
    func refuseOffer(_ token: Data, _ error: WireError) { calls.refuseOffer(token, error) }

    func readItem(_ token: Data, item: UInt32, _ completion: @escaping @Sendable (OfferedItem?) -> Void) {
        calls.readItem(token, item: item, completion)
    }

    func pullItem(_ order: ItemPullOrder, _ completion: @escaping @Sendable (Result<ItemPullID, WireError>) -> Void) {
        calls.pullItem(order, completion)
    }

    func cancelPull(_ id: ItemPullID) { calls.cancelPull(id) }

    func order(
        token: Data, item: UInt32, representation: UInt32, byteCeiling: UInt64, landing: ItemLanding,
        budget: ByteBudget?
    ) throws(WireError) -> ItemPullOrder {
        try calls.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
            budget: budget)
    }
}
