import Foundation
import KernovaLogging
import KernovaSynchronization

/// One connection's control channel and the two transfer tables riding beside
/// it, for either end of either clipboard channel.
///
/// The owner supplies the channel and says which end of which channel it is;
/// everything below the control frames — draining the channel off the owner's
/// actor, the inbox of transfers this side is pulling, the outbox of transfers
/// it is serving, and the frames the control side writes back — is here. No
/// payload byte crosses this channel: each transfer carries its own on a data
/// connection of its own.
@MainActor
public final class ClipboardControlSession {
    /// Which end of the wire this session is — the same value the transfer id's
    /// direction bit is read against, so there is one of it.
    public enum Role: Sendable {
        /// The Mac running Kernova.
        case host
        /// The agent inside the VM.
        case guest
    }

    /// Which channel this session serves.
    ///
    /// Both channels carry offers both ways; what an offer does depends on
    /// which end sent it (``ClipboardOfferDiscipline``).
    public enum Kind: Sendable {
        /// Clipboard sync, offered and pulled in both directions.
        case clipboard
        /// Files dragged between the Mac and the VM display: dropped on it
        /// host→guest, dragged out of it guest→host.
        case drop
    }

    /// How this side obtains a transfer's data connection.
    ///
    /// macOS guests only ever *initiate* vsock connections, so this is the one
    /// axis the two roles differ on: the guest dials the kind's data port and
    /// the host takes what its listener accepted.
    public enum DataLink: Sendable {
        /// Dial `port` for each transfer, through `connect`.
        case dials(port: UInt32, connect: @Sendable (UInt32) throws -> Int32)
        /// Take each connection from a listener, through
        /// ``ClipboardEndpoint/acceptDataConnection(fd:)``.
        case accepts
    }

    /// The end of the wire this session is.
    ///
    /// This and the three below are `nonisolated`: a paste-time provider fire
    /// reads them from whichever thread the pasteboard server fired on.
    nonisolated public let role: Role

    /// The channel this session serves.
    nonisolated public let kind: Kind

    /// Log coordinate for this connection: generations and transfer ids restart
    /// with every accepted channel, and one session serves exactly one.
    nonisolated public let connectionTag: ClipboardConnectionTag

    /// The channel this session drains and writes to.
    ///
    /// Not public: what crosses the wire goes through this type's own frame
    /// senders, and only ``stop()`` closes it, so an owner cannot end the
    /// connection behind the bookkeeping that describes it.
    nonisolated let channel: VsockChannel

    /// What the log lines call the peer — the VM name on the host, the channel
    /// name in the guest.
    nonisolated private let label: String

    /// Where an inbound payload lands.
    private let staging: ClipboardFileStaging

    /// How the offers this side sends behave.
    nonisolated let outboundDiscipline: ClipboardOfferDiscipline

    /// How the offers the peer sends behave.
    nonisolated let inboundDiscipline: ClipboardOfferDiscipline

    nonisolated private let dataLink: DataLink
    nonisolated let dataSocketTimeout: TimeInterval

    /// The inbox, held where a thread that is not the main one can reach it.
    ///
    /// A data connection answering a pull this side opened must be adopted
    /// without a hop to the main actor: the paste fire that opened that pull can
    /// be holding the main thread inside a tracking or modal loop, which runs
    /// nothing queued to main until it returns — and what would resolve it is
    /// that connection. [M1]
    private let inboxHolder = Locked<ClipboardTransferInbox?>(nil)
    private var outboxStorage: ClipboardTransferOutbox?

    /// ``State``, with the drain each case past ``State/idle`` holds — held for
    /// the session's life, so a wait begun after the end still reaches the
    /// drain's.
    private enum Lifecycle: Sendable {
        case idle
        case live(consumeTask: Task<Void, Never>)
        case ended(consumeTask: Task<Void, Never>)
        /// `nil` when ``stop()`` came before any ``start()``.
        case stopped(consumeTask: Task<Void, Never>?)

        var state: State {
            switch self {
            case .idle: .idle
            case .live: .live
            case .ended: .ended
            case .stopped: .stopped
            }
        }

        var consumeTask: Task<Void, Never>? {
            switch self {
            case .idle: nil
            case .live(let task), .ended(let task): task
            case .stopped(let task): task
            }
        }
    }

    /// The main actor moves it out of `idle` and into `stopped`; the drain's
    /// tail moves it from `live` to `ended`, off the main actor.
    private let lifecycle = Locked(Lifecycle.idle)

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardControlSession")

    /// Creates a session for one accepted channel.
    ///
    /// `staging` is where inbound payloads land: every session receives, since
    /// both channels carry offers both ways.
    public init(
        channel: VsockChannel, role: Role, kind: Kind, label: String,
        staging: ClipboardFileStaging, dataLink: DataLink = .accepts,
        dataSocketTimeout: TimeInterval
    ) {
        self.channel = channel
        self.role = role
        self.kind = kind
        self.label = label
        self.staging = staging
        self.dataLink = dataLink
        self.dataSocketTimeout = dataSocketTimeout
        self.connectionTag = role == .host ? .nextHost() : .nextGuest()
        self.outboundDiscipline = ClipboardOfferDiscipline(kind: kind, sender: role)
        self.inboundDiscipline = ClipboardOfferDiscipline(
            kind: kind, sender: role == .host ? .guest : .host)
        // A guest cannot be connected to: a session that expects to accept data
        // connections in that role would leave every transfer waiting for one
        // that can never arrive.
        if role == .guest, case .accepts = dataLink {
            Self.logger.log(
                .fault,
                "Guest clipboard control session for '\(label, privacy: .public)' was given no data dialler"
            )
            assertionFailure("Guest session for '\(label)' was given no data dialler")
        }
    }

    // MARK: - Transfers

    /// The transfers this side is pulling, or `nil` before `start()` and after
    /// `stop()`.
    ///
    /// `nonisolated` so an arriving data connection can be adopted from the
    /// thread that read its header — see `inboxHolder`.
    nonisolated var inbox: ClipboardTransferInbox? { inboxHolder.withLock { $0 } }

    /// The transfers this side is serving, or `nil` before `start()` and after
    /// `stop()`.
    var outbox: ClipboardTransferOutbox? { outboxStorage }

    /// Opens one transfer's data connection, or `nil` when this side accepts
    /// them instead.
    ///
    /// `nonisolated` because it is handed to a transfer that dials on its own
    /// queue, never on the owner's actor.
    nonisolated var dataDialer: (@Sendable () throws -> Int32)? {
        guard case .dials(let port, let connect) = dataLink else { return nil }
        return { try connect(port) }
    }

    // MARK: - Lifecycle

    /// Where a session is in its one pass over its channel; nothing returns to
    /// an earlier case.
    public enum State: Sendable, Equatable {
        /// Before ``ClipboardControlSession/start(handleControlFrame:onEnded:)``.
        case idle
        /// Draining the channel.
        case live
        /// The channel closed under the session, from ``live``.
        case ended
        /// ``ClipboardControlSession/stop()`` ran — this side deciding it is
        /// done listening — from any other case.
        case stopped
    }

    /// `nonisolated` so a data connection or a paste-time fire reads it from
    /// whichever thread it arrived on.
    nonisolated public var state: State { lifecycle.withLock { $0.state } }

    /// Whether this connection is over, by `stop()` or by the channel closing
    /// under it.
    ///
    /// Set before the pulls a teardown cancels are woken, so a paste fire that
    /// wakes cancelled can tell the end of its session from a supersession or a
    /// release, which raise their own explainer.
    nonisolated public var hasEnded: Bool { [.ended, .stopped].contains(state) }

    /// Whether `stop()` has run, which is what a queued control frame is dropped
    /// for.
    ///
    /// Distinct from ``hasEnded``: a peer that sent a frame and then closed — a
    /// `DropComplete`, a `ClipboardRelease` — is still owed its delivery.
    nonisolated public var hasStopped: Bool { state == .stopped }

    /// Opens the transfer tables and starts draining the channel, once: a call
    /// after the first, or after ``stop()``, does nothing and returns `false`.
    ///
    /// `handleControlFrame` receives every frame, on the main actor and in
    /// arrival order — including one this session has since stopped for, which
    /// its owner decides about (``hasStopped``). `onEnded` runs off the main
    /// actor the moment the channel is done, so a pull parked on the main
    /// thread is woken without waiting for a main-queue hop it is itself
    /// blocking.
    @discardableResult
    public func start(
        handleControlFrame: @escaping @MainActor (Frame) -> Void,
        onEnded: @escaping @Sendable () -> Void = {}
    ) -> Bool {
        guard case .idle = lifecycle.withLock({ $0 }) else { return false }
        let tag = connectionTag
        let label = self.label
        let sent = Self.sentDirectionWord(role: role)
        let received = Self.sentDirectionWord(role: role == .host ? .guest : .host)
        let subject = kind == .clipboard ? "clipboard transfer" : "drop"

        outboxStorage = ClipboardTransferOutbox(
            socketTimeout: dataSocketTimeout,
            // The only measured throughput number for what this side sends, so
            // it logs at `.notice` (persisted) rather than `.debug`.
            onTransferTimed: { metrics in
                Self.logger.log(
                    .notice,
                    "\(sent, privacy: .public) \(subject, privacy: .public) \(metrics.transferID, privacy: .public) ('\(label, privacy: .public)', conn=\(tag, privacy: .public)) sent: \(metrics.logSummary, privacy: .public)"
                )
            })
        let inbox = ClipboardTransferInbox(
            staging: staging, socketTimeout: dataSocketTimeout,
            onTransferTimed: { metrics in
                Self.logger.log(
                    .notice,
                    "\(received, privacy: .public) \(subject, privacy: .public) \(metrics.transferID, privacy: .public) ('\(label, privacy: .public)', conn=\(tag, privacy: .public)) completed: \(metrics.logSummary, privacy: .public)"
                )
            })

        inboxHolder.withLock { $0 = inbox }
        let channel = self.channel
        let lifecycle = self.lifecycle
        let drain: @Sendable () async -> Void = { [inbox] in
            await Self.consume(
                channel: channel, label: label, connectionTag: tag, subject: subject,
                inbox: inbox, lifecycle: lifecycle, onEnded: onEnded,
                onControlFrame: { frame in
                    // Fire-and-forget: the consume loop must never wait on the
                    // main actor — a paste's promise callback occupies it, and
                    // a transfer this loop's frames open is what resolves that
                    // callback. The serial main queue preserves control-frame
                    // FIFO order; a per-frame Task would not.
                    MainActorBridge.async { handleControlFrame(frame) }
                })
        }
        // Armed under the lock the drain's tail takes to move the session to
        // `ended`, so the tail cannot run ahead of the `live` it moves from.
        lifecycle.withLock { $0 = .live(consumeTask: Task.detached(operation: drain)) }
        return true
    }

    /// Returns once the drain and its settling tail have run, whether the channel
    /// closed on its own or ``stop()`` ended it; at once if ``start()`` never
    /// armed one.
    ///
    /// The tail's `onEnded` has run by then, but anything it queued to the main
    /// actor is still queued, not delivered.
    public func waitUntilEnded() async {
        await lifecycle.withLock { $0.consumeTask }?.value
    }

    #if DEBUG
    /// The task draining the channel, held from `start()` on — empty only before
    /// it.
    var lifecycleTasksForTesting: [Task<Void, Never>] {
        [lifecycle.withLock { $0.consumeTask }].compactMap { $0 }
    }
    #endif

    /// Ends the connection: stops draining, wakes every transfer, and closes the
    /// channel. Idempotent, and terminal: the session never starts afterwards.
    public func stop() {
        // Before any wake, so a paste fire this cancels explains itself.
        let consumeTask = lifecycle.withLock { lifecycle in
            let task = lifecycle.consumeTask
            lifecycle = .stopped(consumeTask: task)
            return task
        }
        consumeTask?.cancel()
        let inbox = inboxHolder.withLock { inbox in
            defer { inbox = nil }
            return inbox
        }
        outboxStorage?.cancelAll()
        inbox?.cancelAll()
        outboxStorage = nil
        channel.close()
    }

    // MARK: - Frame consumer

    /// Which way a transfer this side *sends* travels, for the log lines.
    private static func sentDirectionWord(role: Role) -> String {
        role == .host ? "Host→guest" : "Guest→host"
    }

    /// Drains the channel and settles the session once it is done.
    ///
    /// `nonisolated` so the loop runs on a cooperative thread. [M1] The settling
    /// tail lives here for the same reason: a pull parked on the main thread —
    /// inside a tracking or modal loop it parks rather than running the event
    /// loop — is woken by it, so it must not itself be a main-queue job that
    /// pull is blocking.
    nonisolated private static func consume(
        channel: VsockChannel,
        label: String,
        connectionTag: ClipboardConnectionTag,
        subject: String,
        inbox: ClipboardTransferInbox,
        lifecycle: Locked<Lifecycle>,
        onEnded: @Sendable () -> Void,
        onControlFrame: @Sendable @escaping (Frame) -> Void
    ) async {
        do {
            for try await frame in channel.incoming where frame.protocolVersion == 1 {
                onControlFrame(frame)
            }
            // A guest disconnect has to survive in the log after the fact, so this
            // persists rather than logging at `.debug`/`.info`.
            logger.log(
                .notice,
                "Vsock \(subject, privacy: .public) channel closed for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public))"
            )
        } catch {
            logger.log(
                .warning,
                "Vsock \(subject, privacy: .public) channel ended with error for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
        // Channel closed — wake any parked pull so a materialize doesn't hang
        // forever. Ended first, so a paste fire that wakes here can tell this
        // teardown from a supersession and explain itself; a `stop()` that got
        // here first keeps the session stopped.
        lifecycle.withLock { phase in
            if case .live(let task) = phase { phase = .ended(consumeTask: task) }
        }
        inbox.cancelAll()
        onEnded()
    }

    // MARK: - Sending control frames

    /// Announces `reps` under `generation` in the vocabulary of what this side
    /// offers — a `ClipboardOffer`, a host's `DropOffer`, a guest's `DragOffer`.
    nonisolated public func sendOffer(
        generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo], isConcealed: Bool
    ) throws {
        try channel.send(
            outboundDiscipline.offerFrame(
                generation: generation, reps: reps, isConcealed: isConcealed))
    }

    /// Retires the offer for `generation` in the vocabulary of what this side
    /// offers — a `ClipboardRelease`, a host's `DropRelease`, a guest's
    /// `DragRelease`.
    nonisolated public func sendRelease(generation: UInt64) throws {
        try channel.send(outboundDiscipline.releaseFrame(generation: generation))
    }

    /// Asks the peer to dial one representation's data connection.
    ///
    /// Only the side that cannot dial ever sends this: the peer answers by
    /// opening the transfer's connection and writing the reply that names it.
    nonisolated public func sendRequest(
        generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64
    ) throws {
        try channel.send(
            .clipboardRequest(
                generation: generation, transferID: transferID, uti: uti,
                maxAcceptByteCount: maxAcceptByteCount))
    }

    /// Reports a refusal to the peer. Best-effort, as the refusal has already
    /// been recorded on this side.
    nonisolated public func sendError(
        code: ClipboardErrorCode, message: String, inReplyTo: String?
    ) {
        try? channel.sendErrorFrame(
            code: code.rawValue, message: message, inReplyTo: inReplyTo)
    }

    /// Reports how the drop for `generation` ended. Best-effort: a channel that
    /// died took the drop with it.
    nonisolated public func sendDropComplete(
        generation: UInt64, outcome: Kernova_V1_DropComplete.Outcome,
        code: ClipboardErrorCode? = nil, message: String = ""
    ) {
        try? channel.send(
            .dropComplete(
                generation: generation, outcome: outcome, code: code, message: message))
    }

    /// Tells the guest the host is done with the drag for `generation`.
    /// Best-effort: a channel that died took the drag with it.
    nonisolated public func sendDragComplete(generation: UInt64) {
        try? channel.send(.dragComplete(generation: generation))
    }

    /// Asks the guest to hand the drag for `generation` over. Best-effort: a
    /// channel that died took the drag with it.
    nonisolated public func sendDragTake(generation: UInt64) {
        try? channel.send(.dragTake(generation: generation))
    }

    /// Shows the guest's catcher for `generation` again, or stands it down.
    /// Best-effort: a channel that died took the drag with it.
    nonisolated public func sendDragCatcher(generation: UInt64, shown: Bool) {
        try? channel.send(.dragCatcher(generation: generation, shown: shown))
    }

    /// Reports one step of handing the drag for `generation` to the host.
    /// Best-effort: a channel that died took the drag with it.
    nonisolated public func sendDragHandOff(generation: UInt64, step: ClipboardDragHandOffStep) {
        try? channel.send(.dragHandOff(generation: generation, step: step))
    }
}
