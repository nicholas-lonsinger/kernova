import AppKit
import Foundation
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaClipboardItems
import KernovaKit
import KernovaLogging
import KernovaPlatformDarwin
import KernovaSynchronization
import KernovaTransferProgress
import KernovaWire

/// The guest's clipboard over the session peer's CLIPBOARD items: each copy in this session offered to the host
/// while passthrough runs, the session owns the console and its connection can use the feature, and each host
/// offer published on the guest pasteboard, its bytes pulled only when a paste asks for them. Neither that gate
/// opening nor a new connection offers what the pasteboard already holds: only a copy made after. The host's clipboard commands cross
/// as copies: a snapshot of this pasteboard sent when the host asks, and a host copy written here as data, its
/// files promised.
@MainActor
final class GuestClipboard {
    /// The logger a clipboard logs through unless it is built with another.
    nonisolated static let defaultLogger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "GuestClipboard")

    private let logger: KernovaLogger

    /// The exchange both directions run through.
    let exchange: ClipboardItemExchange

    private let pasteboard: any ClipboardPasteboard
    /// Where a copied file promise is called in when the host pulls passthrough's offer of it.
    private let promiseStaging: ClipboardFileStaging
    /// Where a snapshot calls its file promises in, each into a lease of its own.
    private let snapshotStaging: ClipboardFileStaging
    private var nextPromiseGeneration: UInt64 = 1
    /// The one write choke point a host offer reaches the guest pasteboard through. Its provider registry is
    /// this agent's own: the providers it holds are the guest pasteboard's alone.
    private let publisher: ClipboardPasteboardPublisher
    private let onNotice: @Sendable () -> Void
    /// The paste ceiling the host's policy sets: what the exchange's pulls read, from any thread.
    private let pasteCeiling: Locked<Int>

    private var onConsole = false
    /// Whether the host's policy runs passthrough.
    private var passthrough = false
    private var link: (any ClipboardItemLink)?
    /// The pasteboard change last seen by the poll, moved past every write this agent makes so its own
    /// promise is never read as a copy.
    private var seenChangeCount: Int
    /// The change of the pasteboard whose read is in flight.
    private var readingChangeCount: Int?
    /// The host offer the guest pasteboard was last written with.
    private var published: ClipboardRemoteOffer?
    /// This clipboard's place in the pasteboard's watch while a connection can use CLIPBOARD.
    private var pasteboardWatch: ClipboardPasteboardWatch.Observation?

    /// The latest clipboard activity, for the menu-bar status line.
    private(set) var activity: ClipboardActivity = .disabled

    /// A clipboard over `pasteboard`, landing the host's representations and calling in copied promises under
    /// `stagingRoot`, logging through `logger`, reporting its pulls of the host's offers to `transfers` measured on
    /// `transferClock`, and raising `onNotice` when a refusal lands in ``activity``. A paste lands no more than
    /// `pasteCeiling` bytes until the host's policy sets it.
    init(
        pasteboard: any ClipboardPasteboard, stagingRoot: ProcessStagingRoot,
        pasteCeiling: Int = ClipboardPasteLimit.defaultBytes, logger: KernovaLogger = GuestClipboard.defaultLogger,
        transfers: ClipboardTransferReporter = ClipboardTransferReporter(),
        transferClock: any EngineClock = makePlatformEngineClock(),
        onNotice: @escaping @Sendable () -> Void = {}
    ) {
        self.pasteboard = pasteboard
        self.logger = logger
        self.onNotice = onNotice
        let ceiling = Locked(pasteCeiling)
        self.pasteCeiling = ceiling
        exchange = ClipboardItemExchange(
            side: .guest, stagingLabel: "agent", stagingRoot: stagingRoot, pasteCeiling: { ceiling.withLock { $0 } },
            logger: logger, transfers: transfers, peerName: { MacAgentPeer.hostName }, transferClock: transferClock)
        promiseStaging = ClipboardFileStaging(label: "agent-promises", root: stagingRoot)
        snapshotStaging = .leased(label: "agent-copies", root: stagingRoot)
        publisher = ClipboardPasteboardPublisher(
            pasteboard: pasteboard, providerRegistry: LazyClipboardProviderRegistry())
        seenChangeCount = pasteboard.changeCount
        exchange.onRemoteOffer = { [weak self] in self?.publish($0) }
        exchange.onRemoteOfferEnded = { [weak self] in self?.retract($0, $1) }
        exchange.onCopyAsked = { [weak self] in self?.sendSnapshot(answering: $0) }
        exchange.onCopyReceived = { [weak self] in self?.write($0) }
        exchange.onCopyEnded = { [weak self] in self?.copyEnded($0, $1) }
        exchange.onServed = { [weak self] in self?.activity = .sentToHost }
        exchange.onLanded = { [weak self] in self?.activity = .receivedFromHost }
        exchange.onPullFailed = { [weak self] in self?.pullFailed($0) }
        publisher.onPasteRefused = { [weak self] in self?.writeRefused() }
    }

    /// The general pasteboard's clipboard, reporting its pulls to `transfers`.
    convenience init(
        stagingRoot: ProcessStagingRoot, transfers: ClipboardTransferReporter,
        onNotice: @escaping @Sendable () -> Void
    ) {
        self.init(pasteboard: NSPasteboard.general, stagingRoot: stagingRoot, transfers: transfers, onNotice: onNotice)
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
    /// and pull, and whether passthrough runs.
    func apply(_ policy: PolicySnapshot) {
        let value = ClipboardPolicyValue(policy)
        let ceiling = ClipboardPasteLimit.fromPolicy(value?.maxPasteBytes ?? 0)
        let changed = pasteCeiling.withLock { held in
            defer { held = ceiling }
            return held != ceiling
        }
        if changed { logger.log(.notice, "The host sets the paste ceiling to \(ceiling, privacy: .public) bytes") }
        let was = isOffering
        passthrough = value?.passthrough ?? false
        gateChanged(from: was)
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
            pasteboardWatch?.cancel()
            pasteboardWatch = nil
        } else {
            if case .disabled = activity { activity = .enabled }
            startPolling()
        }
        gateChanged(from: was)
    }

    /// Copies are offered while this is true.
    var isOffering: Bool { passthrough && onConsole && link != nil }

    /// The gate opening sees the pasteboard as it stands, offering nothing: the poll offers only a later copy.
    /// Closing it withdraws this side's offer, so nothing of it stands while passthrough is off, RESET with the
    /// cause: `DISABLED_BY_POLICY` when passthrough stopped, `CAPABILITY_WITHDRAWN` when the session left the
    /// console or the link went — never `CANCELLED`, which the host reads as this clipboard moving on.
    private func gateChanged(from was: Bool) {
        guard isOffering != was else { return }
        guard isOffering else {
            return exchange.withdrawLocal(passthrough ? .capabilityWithdrawn : .disabledByPolicy)
        }
        logger.log(.notice, "Copies on the clipboard are offered to the host from now on")
        seenChangeCount = pasteboard.changeCount
    }

    // MARK: Guest → host

    private func startPolling() {
        guard pasteboardWatch == nil else { return }
        pasteboardWatch = ClipboardPasteboardWatch.observe(pasteboard, in: .newCopies) { [weak self] in
            self?.checkPasteboard()
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

    /// Reads the pasteboard as it stands at `changeCount` and offers it, unless it is this agent's write or has
    /// moved on by the time the read lands.
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

    /// Answers the host's ask with a snapshot of the pasteboard now, whether or not passthrough runs, or declines
    /// it: off the console or with nothing to copy. What the pasteboard holds only as the host's promise goes by
    /// reference.
    private func sendSnapshot(answering ask: ClipboardItemExchange.CopyAsk) {
        guard onConsole, link != nil else { return exchange.decline(ask, WireError(.clipboardNothingToCopy)) }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await ClipboardPasteboardReader.readSnapshot(
                from: pasteboard, ceiling: pasteCeilingBytes, staging: snapshotStaging,
                copyingTo: exchange.connection)
            switch outcome {
            case .snapshot(let snapshot, let lost):
                exchange.answer(ask, with: snapshot, leftOut: lost)
                activity = lost > 0 ? .copyPartlyCarried(skipped: lost) : .sentToHost
                if lost > 0 { onNotice() }
            case .nothing:
                logger.log(.notice, "The host asked for the clipboard, which holds nothing to copy")
                exchange.decline(ask, WireError(.clipboardNothingToCopy))
            case .unreadable:
                logger.log(.notice, "The host asked for the clipboard, whose files this agent cannot read")
                exchange.decline(ask, WireError(.readFailed))
                activity = .copyCarriedNothing
                onNotice()
            case .changed:
                exchange.decline(ask, WireError(.cancelled, debugDetail: "the clipboard kept changing as it was read"))
            case .tooLarge(let limitBytes):
                logger.log(.notice, "The host asked for the clipboard, which is over the paste ceiling")
                exchange.decline(ask, WireError(.tooLarge, limit: UInt64(limitBytes)))
            }
        }
    }

    // MARK: Host → guest

    /// Writes the host's copy once every INLINE representation landed, as data, its files promised — unless the
    /// pasteboard changed since the copy arrived, when it is left as it is and the host told why, or a newer copy
    /// arrived first (``ClipboardItemExchange/land(_:then:)``). What it names of this agent's own offers by
    /// reference is filled from them; what they can no longer give is left out, and the host told so. Files
    /// over the paste ceiling are left out of the write, and the host told that too; with nothing else in the
    /// copy, nothing is written. The copy is released once something replaces its write, or at once when the
    /// write does not hold it: it promised no file, and is not concealed.
    private func write(_ copy: ClipboardRemoteOffer) {
        let arrivedAt = pasteboard.changeCount
        let exchange = exchange
        Task { @MainActor [weak self] in
            let landing = await exchange.land(copy) { self?.writeLanded(copy, arrivedAt: arrivedAt, leftOut: $0) }
            if case .failed(let error) = landing, error.code == .tooLarge { self?.pullFailed(error) }
        }
    }

    /// Writes `copy`, every INLINE representation landed and every reference filled but `leftOut`, unless the
    /// pasteboard changed since `arrivedAt`.
    private func writeLanded(_ copy: ClipboardRemoteOffer, arrivedAt: Int, leftOut: Int) {
        guard pasteboard.changeCount == arrivedAt else {
            logger.log(.notice, "The clipboard changed before the host's copy landed: left as it is")
            exchange.refuseCopy(copy, WireError(.clipboardChanged))
            return
        }
        let ceiling = pasteCeilingBytes
        let plan = ClipboardPromisePolicy.copyPlan(copy.items, room: copy.pasteRoom)
        guard plan != .tooLarge else {
            logger.log(.notice, "The host's copy is files over the paste ceiling alone: not written")
            exchange.refuseCopy(copy, WireError(.tooLarge, limit: UInt64(ceiling)))
            activity = .pasteRefused(.pasteTooLarge, pasteLimitBytes: ceiling)
            onNotice()
            return
        }
        let (written, holdsCopy) = publisher.publishCopy(
            copy.items, concealed: copy.concealed, servingFileURLs: plan.servesFileURLs,
            held: { copy.held(item: $0, representation: $1) }, puller: copy, serving: copy.serving,
            onReleased: { [weak self] in self?.exchange.releaseCopy(copy) })
        if let changeCount = publisher.lastWriteChangeCount { seenChangeCount = changeCount }
        guard written else {
            guard leftOut == 0 else {
                logger.log(.notice, "Nothing the host's copy named of this agent's clipboard remains: not written")
                exchange.refuseCopy(copy, WireError(.clipboardPartsGone))
                return
            }
            logger.log(.error, "The host's clipboard copy could not be written to the pasteboard")
            exchange.refuseCopy(copy, WireError(.writeFailed))
            return writeRefused()
        }
        // The pasteboard holds the host's copy now, so neither current offer is this clipboard's.
        if let published {
            self.published = nil
            exchange.release(published)
        }
        exchange.withdrawLocal()
        activity = .receivedFromHost
        if case .withoutFiles = plan {
            exchange.refuseCopy(copy, WireError(.clipboardFilesWithheld, limit: UInt64(ceiling)))
            activity = .pasteRefused(.pasteTooLarge, pasteLimitBytes: ceiling)
            onNotice()
        } else if !holdsCopy {
            // A copy naming this agent's own offers by reference promises nothing: its references are all it
            // names of the agent's, so the host hears now what was left out.
            if leftOut > 0 {
                exchange.refuseCopy(copy, WireError(.clipboardPartsGone))
            } else {
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
            serving: remote.serving)
        if let changeCount = publisher.lastWriteChangeCount { seenChangeCount = changeCount }
        guard written else {
            logger.log(.error, "The host's clipboard offer could not be written to the pasteboard")
            exchange.release(remote)
            return writeRefused()
        }
        published = remote
        if budget.exceeds {
            logger.log(
                .notice,
                "The host's files total \(budget.total, privacy: .public) bytes, over the \(ceiling, privacy: .public)-byte paste ceiling: published without them"
            )
            activity = .pasteRefused(.pasteTooLarge, pasteLimitBytes: ceiling)
            onNotice()
        } else {
            activity = .offeredFromHost
        }
    }

    /// The pasteboard refused a write of the host's clipboard, or a paste's bytes of it: shown as a paste that
    /// failed.
    private func writeRefused() {
        activity = .pasteRefused(.pasteFailed, pasteLimitBytes: nil)
        onNotice()
    }

    /// A pull of the host's offer failed a paste: one over the paste ceiling — the representation, or the offer's
    /// file set — is shown as the refusal a publish over it shows.
    private func pullFailed(_ error: WireError) {
        guard error.code == .tooLarge else { return }
        let ceiling = pasteCeilingBytes
        logger.log(
            .notice, "A paste of the host's clipboard is over the \(ceiling, privacy: .public)-byte paste ceiling")
        activity = .pasteRefused(.pasteTooLarge, pasteLimitBytes: ceiling)
        onNotice()
    }

    /// The host's offer stopped being this clipboard, as `ending` says. A promise still standing for it could serve
    /// only what already landed, so its write is retracted, unless a copy has replaced it since: every promise
    /// when the host's clipboard moved on, and what no paste had when passthrough stopped or the link carrying it
    /// ended, since the host may hold it still. The host's next connection offers only its next copy.
    private func retract(_ remote: ClipboardRemoteOffer, _ ending: ClipboardItemExchange.RemoteEnding) {
        guard published === remote else { return }
        published = nil
        let withdrawal: ClipboardWithdrawal
        switch ending {
        case .superseded: return
        case .byFarSide, .movedOn: withdrawal = .everyPromise
        case .passthroughStopped, .linkLost: withdrawal = .unread
        }
        retractWrite(servingOffer: remote.token, withdrawing: withdrawal, of: .clipboard, because: .ended(ending))
    }

    /// A copy the host sent ended, with the link or withdrawn by the host: what this clipboard holds of it
    /// that no paste had is retracted, its files being on the Mac's disk, and a concealed copy goes whole, pasted
    /// or not. A withdrawal that took something back is a notice; a link's end shows as sharing going off, and a
    /// concealed copy the Mac's clipboard moved on from goes unannounced, as passthrough's does.
    private func copyEnded(_ copy: ClipboardRemoteOffer, _ ending: ClipboardItemExchange.RemoteEnding) {
        let retraction = retractWrite(
            servingOffer: copy.token, withdrawing: .unread, of: .copy, because: .ended(ending))
        guard case .byFarSide = ending else { return }
        switch retraction {
        case .cleared: activity = .copyWithdrawn(filesOnly: false)
        case .keptPart: activity = .copyWithdrawn(filesOnly: true)
        case .keptEverything, nil: return
        }
        onNotice()
    }

    /// Withdraws `withdrawal`'s promises of this agent's write of `write` serving the offer `token`, if the
    /// pasteboard still holds it, as this agent's own change — the poll must not read it as a copy — and logs what
    /// that took back and its `cause`. Returns what it took back; nil when the pasteboard no longer held the write.
    @discardableResult
    private func retractWrite(
        servingOffer token: Data, withdrawing withdrawal: ClipboardWithdrawal, of write: ClipboardRetractionLog.Write,
        because cause: ClipboardRetractionLog.Cause
    ) -> ClipboardRetraction? {
        guard let retraction = publisher.retractWrite(servingOffer: token, withdrawing: withdrawal) else { return nil }
        seenChangeCount = pasteboard.changeCount
        if let line = ClipboardRetractionLog.line(retraction, of: write, on: .guest, because: cause) {
            logger.log(.notice, "\(line, privacy: .public)")
        }
        return retraction
    }

    /// Stops polling; the pasteboard's promises keep serving what already landed.
    func stop() {
        pasteboardWatch?.cancel()
        pasteboardWatch = nil
    }
}

/// CLIPBOARD's calls through the session peer's connection.
struct AgentClipboardLink: ClipboardItemLink {
    let calls: PeerItemCalls

    func offerItems(_ offer: ItemOffer, _ completion: @escaping @Sendable (WireError?) -> Void) {
        calls.offerItems(offer, feature: .clipboard, completion)
    }

    func withdrawOffer(_ token: Data, code: ErrorCode) { calls.withdrawOffer(token, code: code) }
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
        budget: ByteBudget?, progress: (any ItemLandingProgress)?
    ) throws(WireError) -> ItemPullOrder {
        try calls.order(
            token: token, item: item, representation: representation, byteCeiling: byteCeiling, landing: landing,
            budget: budget, progress: progress)
    }
}
