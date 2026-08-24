import Foundation

/// One clipboard-protocol connection — either end of either clipboard channel —
/// as its owner sees it.
///
/// Everything the protocol itself decides is here: the control channel and the
/// per-transfer data connections beside it, what this side has offered and the
/// transfers answering the peer's pulls, what the peer has offered and every
/// pull that materializes it, and the control-frame vocabulary each
/// `(role, kind)` pair accepts. An owner holds one of these, conforms to
/// ``ClipboardEndpointDelegate``, and decides only what its own surface does
/// with what arrives — what to snapshot, when to publish, where to render.
@MainActor
public final class ClipboardEndpoint {
    /// Which end of the wire this connection is.
    public typealias Role = ClipboardControlSession.Role

    /// Which channel this connection serves.
    public typealias Kind = ClipboardControlSession.Kind

    /// How this side obtains each transfer's data connection.
    public typealias DataLink = ClipboardControlSession.DataLink

    /// One offer the peer has made, as its owner reads it back.
    public typealias InboundOffer = ClipboardInboundOffers.InboundOffer

    /// Why an offer this side was holding is no longer live.
    public typealias RetractReason = ClipboardInboundOffers.RetractReason

    /// How long a reported paste refusal silences further refusals of the same
    /// offer.
    public static let refusalBurstWindow = ClipboardInboundOffers.refusalBurstWindow

    /// Something this connection just did that a surface may want to render.
    public enum Activity: Equatable, Sendable {
        /// An offer went out to the peer.
        case offerSent
        /// A transfer began streaming in answer to the peer's request.
        case transferServed
        /// A pull delivered a representation's bytes.
        case representationReceived
        /// A paste on this side was refused. `limitBytes` is the ceiling that
        /// refused it, for the codes a ceiling explains.
        case pasteRefused(ClipboardErrorCode, limitBytes: Int?)
    }

    /// What became of an ``offer(_:)``.
    ///
    /// A caller gating on its own change counter needs the three silent outcomes
    /// apart: content the peer already has is as good as sent, while a failed
    /// send leaves it owed the offer.
    public enum OfferOutcome: Equatable, Sendable {
        /// The offer is away and registered under this generation.
        case sent(generation: UInt64)
        /// The peer already holds this content.
        case duplicate
        /// Nothing in the content survived the offer limits.
        case nothingToOffer
        /// The frame never left; nothing is registered.
        case sendFailed
    }

    /// Everything one connection needs beyond its channel and its reporter.
    public struct Configuration {
        /// The end of the wire this side is.
        public var role: Role
        /// The channel this connection serves.
        public var kind: Kind
        /// Log coordinate — the VM name on the host, the channel name in the
        /// guest.
        public var label: String
        /// What a readout calls the peer.
        public var peerName: String
        /// The ceiling an inbound paste's file set is measured against, read at
        /// each gate check so a change reaches a live connection.
        public var maxPasteBytes: @MainActor () -> Int
        /// Where an inbound payload lands; `nil` only for a send-only
        /// connection.
        public var staging: ClipboardFileStaging?
        /// How long a pull waits without progress before giving up.
        public var lazyPullTimeout: TimeInterval
        /// How long an offered drop waits for the peer to ask for its first item
        /// before this side calls it off.
        public var dropClaimTimeout: TimeInterval
        /// Runs that deadline after its delay; tests fire it by hand.
        public var dropClaimSchedule: @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void
        /// How long a transfer runs before its readout surfaces.
        public var progressRevealDelay: TimeInterval
        /// How long a readout waits after its last unit before calling the
        /// gesture over.
        public var progressIdleGap: TimeInterval
        /// Time source for the refusal-burst window.
        public var clock: any EngineClock
        /// How each transfer's data connection is obtained: the guest dials the
        /// kind's data port, the host takes what its listener accepted.
        public var dataLink: DataLink
        /// The generation this connection's first offer carries, so a counter
        /// outliving the channel is never reused.
        public var firstGeneration: UInt64

        /// Describes one connection; every field past `peerName` has the
        /// production default.
        public init(
            role: Role,
            kind: Kind,
            label: String,
            peerName: String,
            maxPasteBytes: @escaping @MainActor () -> Int = { ClipboardPasteLimit.defaultBytes },
            staging: ClipboardFileStaging? = nil,
            lazyPullTimeout: TimeInterval = ClipboardStreamTuning.lazyPullTimeout,
            dropClaimTimeout: TimeInterval = ClipboardStreamTuning.dropClaimTimeout,
            dropClaimSchedule:
                @escaping @Sendable (
                    TimeInterval, @escaping @MainActor @Sendable () -> Void
                ) -> Void = ClipboardOutboundOffers.scheduleOnMainQueue,
            progressRevealDelay: TimeInterval = ClipboardTransferOperation.defaultRevealDelay,
            progressIdleGap: TimeInterval = ClipboardTransferOperation.defaultIdleGap,
            clock: any EngineClock = makePlatformEngineClock(),
            dataLink: DataLink = .accepts,
            firstGeneration: UInt64 = 1
        ) {
            self.role = role
            self.kind = kind
            self.label = label
            self.peerName = peerName
            self.maxPasteBytes = maxPasteBytes
            self.staging = staging
            self.lazyPullTimeout = lazyPullTimeout
            self.dropClaimTimeout = dropClaimTimeout
            self.dropClaimSchedule = dropClaimSchedule
            self.progressRevealDelay = progressRevealDelay
            self.progressIdleGap = progressIdleGap
            self.clock = clock
            self.dataLink = dataLink
            self.firstGeneration = firstGeneration
        }
    }

    // MARK: - Stored state

    /// The surface this connection reports to. Weak: the owner holds the
    /// endpoint, and the pasteboard promises a guest writes hold it past the
    /// owner's own teardown.
    public weak var delegate: (any ClipboardEndpointDelegate)?

    /// The end of the wire this connection is.
    ///
    /// This and the two below are `nonisolated`: a paste-time provider fire
    /// reads them from whichever thread the pasteboard server fired on.
    nonisolated public let role: Role

    /// The channel this connection serves.
    nonisolated public let kind: Kind

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one endpoint serves exactly one.
    nonisolated public var connectionTag: ClipboardConnectionTag { session.connectionTag }

    /// Whether this connection is over, by ``stop()`` or by the channel closing
    /// under it.
    nonisolated public var hasEnded: Bool { session.hasEnded }

    /// Whether this connection is live — `true` between ``start()`` and either
    /// ``stop()`` or the channel's own end.
    ///
    /// `nonisolated` so the accept path can gate on it from the listener's
    /// queue; written only on the main actor, at the lifecycle transitions.
    nonisolated public var isConnected: Bool { connectedFlag.value }

    nonisolated private let connectedFlag = LockedFlag()

    nonisolated private let session: ClipboardControlSession
    private let outbound: ClipboardOutboundOffers

    /// `nonisolated` so a paste-time provider fire can serve from whichever
    /// thread the pasteboard server fired on; `nil` for a send-only connection.
    nonisolated private let inbound: ClipboardInboundOffers?

    nonisolated private let reporter: ClipboardTransferReporter
    nonisolated private let label: String

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardEndpoint")

    // MARK: - Init

    /// Builds the endpoint for one accepted channel.
    ///
    /// Nothing crosses the wire until ``start()``.
    public init(
        channel: VsockChannel, configuration: Configuration, reporter: ClipboardTransferReporter
    ) {
        self.role = configuration.role
        self.kind = configuration.kind
        self.reporter = reporter
        self.label = configuration.label
        let session = ClipboardControlSession(
            channel: channel, role: configuration.role, kind: configuration.kind,
            label: configuration.label, staging: configuration.staging,
            dataLink: configuration.dataLink)
        self.session = session
        self.outbound = ClipboardOutboundOffers(
            session: session, reporter: reporter, peerName: configuration.peerName,
            progressRevealDelay: configuration.progressRevealDelay,
            progressIdleGap: configuration.progressIdleGap,
            dropClaimTimeout: configuration.dropClaimTimeout,
            dropClaimSchedule: configuration.dropClaimSchedule,
            firstGeneration: configuration.firstGeneration)
        // A send-only connection has no staging and never receives a byte; the
        // session raises the fault for any other combination.
        self.inbound = configuration.staging.map { staging in
            ClipboardInboundOffers(
                session: session, reporter: reporter, staging: staging,
                peerName: configuration.peerName, maxPasteBytes: configuration.maxPasteBytes,
                lazyPullTimeout: configuration.lazyPullTimeout,
                progressRevealDelay: configuration.progressRevealDelay,
                progressIdleGap: configuration.progressIdleGap, clock: configuration.clock)
        }
        outbound.onActivity = { [weak self] activity in self?.record(activity) }
        inbound?.onOfferReceived = { [weak self] offer in
            guard let self else { return }
            self.delegate?.endpoint(self, didReceiveOffer: offer)
        }
        inbound?.onOfferRetracted = { [weak self] generation, reason in
            guard let self else { return }
            self.delegate?.endpoint(self, didRetractOffer: generation, reason: reason)
        }
        inbound?.onActivity = { [weak self] activity in self?.record(activity) }
        inbound?.onRefusal = { [weak self] gesture, failure in
            guard let self else { return }
            self.delegate?.endpoint(self, didRefuse: gesture, failure: failure)
        }
    }

    // MARK: - Lifecycle

    /// Builds the engine and starts draining the channel; idempotent.
    ///
    /// A clipboard connection retires the report the last one left standing:
    /// what it described is a transfer of a session that is over.
    public func start() {
        guard !isConnected else { return }
        connectedFlag.value = true
        if kind == .clipboard { reporter.clearFinished() }
        session.start(
            handleControlFrame: { [weak self] frame in self?.handleControlFrame(frame) },
            onEnded: { [weak self] in
                // Off the main actor and before anything hops to it: a pull
                // parked on the main thread is what would block that hop.
                self?.inbound?.endSession()
                MainActorBridge.async { self?.channelDidEnd() }
            })
    }

    /// Returns once the channel is done, whether it closed on its own or
    /// ``stop()`` ended it.
    public func waitUntilEnded() async {
        await session.waitUntilEnded()
    }

    /// Ends the connection: stops draining, wakes every parked pull, retires
    /// what this side offered, and closes the channel. Idempotent.
    ///
    /// The peer's clipboard offers and their materialization caches deliberately
    /// survive: a pasteboard write this side published outlives the session
    /// behind it, and every representation already pulled stays servable
    /// (docs/CLIPBOARD.md §3).
    public func stop() {
        session.stop()
        inbound?.endSession()
        outbound.endSession()
        connectedFlag.value = false
    }

    /// Settles a connection the channel ended under, and tells the owner.
    ///
    /// Only the channel's own end reaches the delegate: ``stop()`` is the owner
    /// deciding, and it needs no answer.
    private func channelDidEnd() {
        guard isConnected else { return }
        connectedFlag.value = false
        delegate?.endpointDidEnd(self)
    }

    // MARK: - Outbound (this side offers, the peer pulls)

    /// The generation the next offer will carry, so an owner outliving this
    /// connection can seed the next one's counter.
    public var nextGeneration: UInt64 { outbound.nextGeneration }

    /// The content of the clipboard offer the peer currently holds, or `nil`.
    public var currentOutboundContent: ClipboardContent? { outbound.currentContent }

    /// The content offered under `generation`, or `nil` once it is retired.
    public func outboundContent(generation: UInt64) -> ClipboardContent? {
        outbound.content(generation: generation)
    }

    /// Announces `content` to the peer, reporting what became of it.
    ///
    /// `skippedBeforeOffer` is how many of the gesture's items this side already
    /// knows it cannot send, counted into a drop's verdict alongside the ones
    /// that fail once the peer asks.
    @discardableResult
    public func offer(_ content: ClipboardContent, skippedBeforeOffer: Int = 0) -> OfferOutcome {
        outbound.offer(content, skippedBeforeOffer: skippedBeforeOffer)
    }

    /// Called once per drop generation when that drop is over, whatever ended
    /// it, so an owner can free what it staged for the peer to pull.
    ///
    /// Set after construction rather than taken in the configuration: the owner
    /// holds this endpoint as a stored property and has no `self` to hand over
    /// while building it.
    public var onDropSettled: @MainActor (UInt64) -> Void {
        get { outbound.onDropSettled }
        set { outbound.onDropSettled = newValue }
    }

    /// Forgets what was last offered, so re-announcing the same content counts
    /// as a fresh offer.
    public func resetOfferDedup() {
        outbound.resetDedup()
    }

    /// Latches `digest` as already announced, suppressing an offer of content
    /// the peer is itself the source of.
    public func latchOfferDedup(_ digest: Data) {
        outbound.latchDedup(digest)
    }

    /// Retires the clipboard offer the peer holds, reporting whether one was
    /// actually withdrawn.
    @discardableResult
    public func release() -> Bool {
        outbound.release()
    }

    /// Calls off what the peer is pulling for `generation`, because the user
    /// cancelled its readout.
    public func cancelOutbound(generation: UInt64) {
        outbound.cancel(generation: generation)
    }

    // MARK: - Inbound (the peer offers, this side pulls)

    /// The clipboard offer the peer currently holds here, or `nil`.
    public var inboundOffer: InboundOffer? { inbound?.inboundOffer }

    /// Whether `generation` still names an offer this side may pull from.
    ///
    /// `nonisolated` for a caller reading it the moment its pull wakes: a cancel
    /// retires the offer *before* waking the pulls it aborts, so this is how a
    /// blocking caller tells a cancellation from a transfer that failed.
    nonisolated public func hasLiveInboundOffer(generation: UInt64) -> Bool {
        inbound?.hasLiveOffer(generation: generation) ?? false
    }

    /// Forgets the live offer without telling the peer — the buffer it was
    /// published into holds something else now.
    public func discardInboundOffer() {
        inbound?.discardInboundOffer()
    }

    /// The representation already pulled for `(generation, repIndex)`, or `nil`.
    public func materialized(
        generation: UInt64, repIndex: Int
    ) -> ClipboardContent.Representation? {
        inbound?.materialized(generation: generation, repIndex: repIndex)
    }

    /// How many representations of `generation` have been cached, so an owner
    /// hashing off its actor can tell one landed while it worked.
    public func materializationEpoch(generation: UInt64) -> Int {
        inbound?.materializationEpoch(generation: generation) ?? 0
    }

    /// The offer's paste-bound total against the ceiling in force, or `nil` when
    /// `generation` names no live offer.
    public func pasteBudget(generation: UInt64) -> ClipboardPromisePolicy.PasteBudget? {
        inbound?.pasteBudget(generation: generation)
    }

    /// The pasteboard items to promise for `generation`, or `nil` when it names
    /// no live offer.
    public func promisePlan(generation: UInt64) -> ClipboardPasteboardItemPlan? {
        inbound?.promisePlan(generation: generation)
    }

    /// Starts or joins the pull for one representation without holding a thread,
    /// caching what it delivers.
    public func join(
        generation: UInt64, repIndex: Int, operation: ClipboardTransferOperation
    ) async -> ClipboardContent.Representation? {
        await inbound?.join(generation: generation, repIndex: repIndex, operation: operation)
    }

    /// Starts or joins the pull for one representation, holding the calling
    /// thread until it resolves. The caller owns `operation` and the outcome.
    nonisolated public func pull(
        generation: UInt64, repIndex: Int, operation: ClipboardTransferOperation
    ) -> LazyPullOutcome {
        inbound?.pull(generation: generation, repIndex: repIndex, operation: operation)
            ?? .cancelled
    }

    /// Serves the pasteboard `.fileURL` for a promised representation at paste
    /// time. Safe to call on the main thread even though it blocks; where the
    /// event-loop wait is unavailable there it serves nothing rather than
    /// parking (`LazyPullCoordinator`).
    nonisolated public func serveFileURL(generation: UInt64, repIndex: Int) -> URL? {
        inbound?.serveFileURL(generation: generation, repIndex: repIndex)
    }

    /// Serves an inline pasteboard flavor's bytes for a promised representation
    /// at paste time. Safe to call on the main thread even though it blocks; where the
    /// event-loop wait is unavailable there it serves nothing rather than
    /// parking (`LazyPullCoordinator`).
    nonisolated public func serveData(generation: UInt64, repIndex: Int, uti: String) -> Data? {
        inbound?.serveData(generation: generation, repIndex: repIndex, uti: uti)
    }

    /// Stops the pulls an owner's readout started for `generation`, leaving one
    /// another gesture is also waiting on.
    public func cancelJoinedPulls(generation: UInt64) {
        inbound?.cancelJoinedPulls(generation: generation)
    }

    /// Calls off everything `generation` has in flight and retires it.
    public func cancelInbound(generation: UInt64) {
        inbound?.cancelInbound(generation: generation)
    }

    /// Forgets one inbound offer and everything it holds, telling the peer
    /// nothing — the gesture it belonged to is over.
    public func retireInbound(generation: UInt64) {
        inbound?.retire(generation: generation)
    }

    /// Reports how the drop for `generation` ended. Best-effort: a channel that
    /// died took the drop with it.
    nonisolated public func sendDropComplete(
        generation: UInt64, outcome: Kernova_V1_DropComplete.Outcome,
        code: ClipboardErrorCode? = nil, message: String = ""
    ) {
        session.sendDropComplete(
            generation: generation, outcome: outcome, code: code, message: message)
    }

    // MARK: - Data connections

    /// Where an accepted data connection's opening frame is read, for every
    /// connection in the process.
    ///
    /// Concurrent, and never the main actor's: the read blocks until the peer's
    /// header arrives, and several transfers can be opening at once.
    nonisolated private static let dataAcceptQueue = DispatchQueue(
        label: "app.kernova.clipboard.data-accept", qos: .userInitiated, attributes: .concurrent)

    /// This connection's share of that queue.
    ///
    /// Per connection rather than shared, so the peer that saturates its own
    /// share is the only one held up by it.
    nonisolated private let dataAccepts = BoundedWorkQueue(
        width: ClipboardStreamTuning.maxConcurrentDataAccepts,
        queue: ClipboardEndpoint.dataAcceptQueue)

    /// Takes over a data connection this side's listener accepted, from
    /// whatever thread the listener hands it over on.
    ///
    /// Takes ownership of `fd` on every path. The stall bound goes on here
    /// rather than at the listener because this is the first read on the
    /// descriptor — the transfer that adopts it then states its own — and these
    /// reads run under ``dataAccepts``, so a peer that connects and then says
    /// nothing parks a bounded number of workers however many connections it
    /// opens (docs/CLIPBOARD.md §10).
    nonisolated public func acceptDataConnection(fd: Int32) {
        guard isConnected, !session.hasStopped else {
            ClipboardDataConnection.end(fd: fd)
            return
        }
        ClipboardDataConnection.applySocketOptions(fd: fd)
        dataAccepts.submit { [weak self] in
            guard let frame = try? ClipboardDataConnection.readFrame(fd: fd) else {
                ClipboardDataConnection.end(fd: fd)
                return
            }
            guard let self, !self.session.hasStopped else {
                ClipboardDataConnection.end(fd: fd)
                return
            }
            // A reply answers a pull this side already opened, and is taken on
            // right here rather than through the main actor: the paste fire that
            // opened that pull can be holding the main thread inside a tracking
            // or modal loop, which runs nothing queued to main until it returns
            // — and what would let it return is this very connection. [M1]
            if case .clipboardTransferReply(let reply) = frame.payload {
                guard let inbound = self.inbound else {
                    return self.refuseDataConnection(fd: fd, saying: "a transfer reply")
                }
                inbound.adoptDataConnection(fd: fd, reply: reply)
                return
            }
            // A request opens a transfer this side has to look up an offer and a
            // readout for, which are the owner's actor's to read.
            MainActorBridge.async { self.handleDataRequest(frame, fd: fd) }
        }
    }

    /// Hands one accepted data connection to the outbound half.
    ///
    /// A frame outside this `(role, kind)` pair's vocabulary closes the
    /// connection alone: it is one transfer's peer crossing wires, not the
    /// control channel's, so the session it belongs to keeps running.
    private func handleDataRequest(_ frame: Frame, fd: Int32) {
        guard !session.hasStopped else {
            ClipboardDataConnection.end(fd: fd)
            return
        }
        guard case .clipboardTransferRequest(let request) = frame.payload,
            ClipboardControlSession.sends(role: role, kind: kind)
        else {
            return refuseDataConnection(fd: fd, saying: "a payload this side cannot answer")
        }
        outbound.handleRequest(ClipboardPullRequest(request), link: .accepted(fd))
    }

    nonisolated private func refuseDataConnection(fd: Int32, saying what: String) {
        Self.logger.warning(
            "Closing a \(self.channelWord, privacy: .public) data connection for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) — it opened with \(what, privacy: .public) this side cannot answer"
        )
        ClipboardDataConnection.end(fd: fd)
    }

    // MARK: - Frame consumer

    /// Dispatches one control frame to the half that owns it.
    ///
    /// A payload outside this `(role, kind)` pair's vocabulary is a peer that
    /// crossed wires: the connection ends, and a conformant agent reconnects.
    /// No payload byte arrives here — each transfer carries its own on a data
    /// connection of its own.
    ///
    /// A frame the peer sent and then closed on is still delivered; one queued
    /// behind a local ``stop()`` is not, because that is this side deciding it
    /// is done listening.
    private func handleControlFrame(_ frame: Frame) {
        guard !session.hasStopped else { return }
        switch frame.payload {
        case .clipboardOffer(let offer):
            guard kind == .clipboard, let inbound else { return closeOnWrongPort() }
            inbound.handleOffer(offer)
        case .clipboardRelease(let release):
            guard kind == .clipboard, let inbound else { return closeOnWrongPort() }
            inbound.handleRelease(release)
        case .clipboardRequest(let request):
            // Only a side that cannot dial ever asks over the control channel,
            // and only the guest can answer, so this frame travels host→guest
            // on the clipboard channel and nowhere else.
            guard role == .guest, ClipboardControlSession.sends(role: role, kind: kind),
                let dial = session.dataDialer
            else {
                return closeOnWrongPort()
            }
            outbound.handleRequest(ClipboardPullRequest(request), link: .dial(dial))
        case .dropOffer(let offer):
            guard kind == .drop, let inbound else { return closeOnWrongPort() }
            inbound.handleDropOffer(offer)
        case .dropRelease(let release):
            guard kind == .drop, let inbound else { return closeOnWrongPort() }
            inbound.handleDropRelease(release)
        case .dropComplete(let complete):
            guard kind == .drop, role == .host else { return closeOnWrongPort() }
            outbound.handleDropComplete(complete)
        case .error(let error):
            guard let inbound else {
                // A send-only connection has no inbound gesture to refuse, so
                // the peer's account of one is only ever news for the log.
                Self.logger.warning(
                    "Peer error on the \(self.channelWord, privacy: .public) channel for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)): \(error.code, privacy: .public) — \(error.message, privacy: .public)"
                )
                return
            }
            inbound.handlePeerError(error)
        case .hello, .heartbeat, .policyUpdate, .logRecord:
            // Control-plane and log payloads have their own channels.
            closeOnWrongPort()
        case .clipboardTransferRequest, .clipboardTransferReply:
            // A transfer's header frames belong to its own data connection.
            closeOnWrongPort()
        case .none:
            Self.logger.debug(
                "Frame with no payload for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public))"
            )
        }
    }

    /// Ends a connection the peer is speaking the wrong protocol on.
    ///
    /// The owner is told, unlike after its own ``stop()``: the peer crossed the
    /// wires, so this is the connection ending under the owner rather than the
    /// owner deciding, and the consume tail's own settle is already past the
    /// point where it could say so.
    private func closeOnWrongPort() {
        Self.logger.warning(
            "Unexpected payload on the \(self.channelWord, privacy: .public) channel for '\(self.label, privacy: .public)' (conn=\(self.connectionTag, privacy: .public)) — wrong port; closing the channel"
        )
        let wasConnected = isConnected
        stop()
        guard wasConnected else { return }
        delegate?.endpointDidEnd(self)
    }

    nonisolated private var channelWord: String {
        kind == .clipboard ? "clipboard" : "drop"
    }

    /// Hands what just happened to the surface that renders it.
    private func record(_ activity: Activity) {
        delegate?.endpoint(self, didRecord: activity)
    }

    // MARK: - Test seams

    #if DEBUG
    /// Test seam: awaited between a join's pull resolving and the supersession
    /// re-check that decides whether to cache it.
    public var afterInboundPullForTesting: (@MainActor () async -> Void)? {
        get { inbound?.afterInboundPullForTesting }
        set { inbound?.afterInboundPullForTesting = newValue }
    }

    /// Delivers a control frame as the consume loop's hop would, but
    /// synchronously on the caller's own main-actor turn.
    public func handleControlFrameForTesting(_ frame: Frame) {
        handleControlFrame(frame)
    }

    /// Waiters sharing the pull for `(generation, repIndex)` — a preview loop
    /// and a paste fire on the one transfer read as 2.
    nonisolated public func inboundPullWaiterCountForTesting(
        generation: UInt64, repIndex: Int
    ) -> Int {
        inbound?.inboundPullWaiterCountForTesting(generation: generation, repIndex: repIndex) ?? 0
    }

    /// Test seam for the refusal hop's staleness check.
    public func recordRefusalForTesting(_ code: ClipboardErrorCode, generation: UInt64) {
        inbound?.recordRefusalForTesting(code, generation: generation)
    }

    /// Accepted data connections whose opening frame is being read right now,
    /// and those waiting for a slot to read it in.
    nonisolated var dataAcceptsForTesting: (running: Int, waiting: Int) {
        (dataAccepts.runningCountForTesting, dataAccepts.waitingCountForTesting)
    }
    #endif
}

/// Reversible thread-safe flag — for lifecycle state any thread reads and the
/// main actor sets and clears.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: - Promise serving

/// The endpoint is what a pasteboard promise this side published is served
/// from, whichever thread the OS fires the promise on.
extension ClipboardEndpoint: ClipboardPromiseServing {}

// MARK: - Delegate

/// What one ``ClipboardEndpoint`` reports to its owner.
///
/// Every method is optional: a send-only connection receives no offer, and only
/// a surface that renders one implements the reporting pair.
@MainActor
public protocol ClipboardEndpointDelegate: AnyObject {
    /// The peer has offered content, metadata only — nothing has been pulled.
    func endpoint(_ endpoint: ClipboardEndpoint, didReceiveOffer offer: ClipboardEndpoint.InboundOffer)

    /// An offer this side was holding stopped being servable. `generation` is
    /// `nil` when there was none, which is still the moment to withdraw whatever
    /// this side published for the peer's last offer.
    func endpoint(
        _ endpoint: ClipboardEndpoint, didRetractOffer generation: UInt64?,
        reason: ClipboardEndpoint.RetractReason)

    /// A gesture on this side was refused — a pre-flight check, a gate, or a
    /// transfer that failed under an operation the endpoint owned.
    func endpoint(
        _ endpoint: ClipboardEndpoint, didRefuse gesture: ClipboardTransferGesture,
        failure: ClipboardTransferFailure)

    /// Something happened that a status surface may want to render.
    func endpoint(_ endpoint: ClipboardEndpoint, didRecord activity: ClipboardEndpoint.Activity)

    /// The channel closed under the endpoint. Never raised by
    /// ``ClipboardEndpoint/stop()``, which the owner already knows about.
    func endpointDidEnd(_ endpoint: ClipboardEndpoint)
}

extension ClipboardEndpointDelegate {
    /// Does nothing.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didReceiveOffer offer: ClipboardEndpoint.InboundOffer
    ) {}

    /// Does nothing.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didRetractOffer generation: UInt64?,
        reason: ClipboardEndpoint.RetractReason
    ) {}

    /// Does nothing.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didRefuse gesture: ClipboardTransferGesture,
        failure: ClipboardTransferFailure
    ) {}

    /// Does nothing.
    public func endpoint(
        _ endpoint: ClipboardEndpoint, didRecord activity: ClipboardEndpoint.Activity
    ) {}

    /// Does nothing.
    public func endpointDidEnd(_ endpoint: ClipboardEndpoint) {}
}
