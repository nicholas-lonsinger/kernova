import Foundation

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
    public enum Kind: Sendable {
        /// Clipboard sync, offered and pulled in both directions.
        case clipboard
        /// Files dropped on the VM display, host→guest only.
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

    /// Where an inbound payload lands; `nil` for a send-only session.
    private let staging: ClipboardFileStaging?

    nonisolated private let dataLink: DataLink

    /// The inbox, held where a thread that is not the main one can reach it.
    ///
    /// A data connection answering a pull this side opened must be adopted
    /// without a hop to the main actor: the paste fire that opened that pull can
    /// be holding the main thread inside a tracking or modal loop, which runs
    /// nothing queued to main until it returns — and what would resolve it is
    /// that connection. [M1]
    private let inboxHolder = InboxHolder()
    private var outboxStorage: ClipboardTransferOutbox?
    private var consumeTask: Task<Void, Never>?

    /// Latched before the pulls a teardown cancels are woken, so a paste fire
    /// that wakes cancelled can tell the end of its session from a supersession
    /// or a release, which raise their own explainer.
    private let endedFlag = Latch()

    /// Latched by `stop()` alone, so a control frame queued to main before the
    /// teardown is dropped rather than delivered.
    ///
    /// Distinct from `endedFlag`, which the channel closing also sets: a peer
    /// that sent a frame and then closed — a `DropComplete`, a
    /// `ClipboardRelease` — is still owed its delivery, while a local `stop()`
    /// is this side deciding it is done listening.
    private let stoppedFlag = Latch()

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardControlSession")

    /// Creates a session for one accepted channel.
    ///
    /// `staging` is where inbound payloads land; the host's drop session is
    /// send-only and passes none.
    public init(
        channel: VsockChannel, role: Role, kind: Kind, label: String,
        staging: ClipboardFileStaging? = nil, dataLink: DataLink = .accepts
    ) {
        self.channel = channel
        self.role = role
        self.kind = kind
        self.label = label
        self.staging = staging
        self.dataLink = dataLink
        self.connectionTag = role == .host ? .nextHost() : .nextGuest()
        if Self.receives(role: role, kind: kind), staging == nil {
            Self.logger.fault(
                "Clipboard control session for '\(label, privacy: .public)' receives but was given no staging"
            )
            assertionFailure("Receiving session for '\(label)' was given no staging")
        }
        // A guest cannot be connected to: a session that expects to accept data
        // connections in that role would leave every transfer waiting for one
        // that can never arrive.
        if role == .guest, case .accepts = dataLink {
            Self.logger.fault(
                "Guest clipboard control session for '\(label, privacy: .public)' was given no data dialler"
            )
            assertionFailure("Guest session for '\(label)' was given no data dialler")
        }
    }

    // MARK: - Transfers

    /// The transfers this side is pulling, or `nil` before `start()`, after
    /// `stop()`, and for a send-only session.
    ///
    /// `nonisolated` so an arriving data connection can be adopted from the
    /// thread that read its header — see `inboxHolder`.
    nonisolated var inbox: ClipboardTransferInbox? { inboxHolder.value }

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

    /// Whether this side ever streams payload bytes on this channel.
    static func sends(role: Role, kind: Kind) -> Bool {
        !(role == .guest && kind == .drop)
    }

    /// Whether this side ever receives payload bytes on this channel.
    static func receives(role: Role, kind: Kind) -> Bool {
        !(role == .host && kind == .drop)
    }

    // MARK: - Lifecycle

    /// Whether this connection is over, by `stop()` or by the channel closing
    /// under it.
    ///
    /// `nonisolated` so a paste-time fire can read it from whichever thread the
    /// pasteboard server fired on.
    nonisolated public var hasEnded: Bool { endedFlag.isSet }

    /// Whether `stop()` has run — this side deciding it is done listening,
    /// which is what a queued control frame is dropped for.
    nonisolated public var hasStopped: Bool { stoppedFlag.isSet }

    /// Opens the transfer tables and starts draining the channel; idempotent.
    ///
    /// `handleControlFrame` receives every frame, on the main actor and in
    /// arrival order — including one this session has since stopped for, which
    /// its owner decides about (``hasStopped``). `onEnded` runs off the main
    /// actor the moment the channel is done, so a pull parked on the main
    /// thread is woken without waiting for a main-queue hop it is itself
    /// blocking.
    public func start(
        handleControlFrame: @escaping @MainActor (Frame) -> Void,
        onEnded: @escaping @Sendable () -> Void = {}
    ) {
        guard consumeTask == nil else { return }
        let tag = connectionTag
        let label = self.label
        let sent = Self.sentDirectionWord(role: role)
        let received = Self.sentDirectionWord(role: role == .host ? .guest : .host)
        let subject = kind == .clipboard ? "clipboard transfer" : "drop"
        let connectionRole: ClipboardDataConnection.Role = role == .host ? .host : .guest

        if Self.sends(role: role, kind: kind) {
            outboxStorage = ClipboardTransferOutbox(
                role: connectionRole,
                // The only measured throughput number for what this side sends,
                // so it logs at `.notice` (persisted) rather than `.debug`.
                onTransferTimed: { metrics in
                    Self.logger.notice(
                        "\(sent, privacy: .public) \(subject, privacy: .public) \(metrics.transferID, privacy: .public) ('\(label, privacy: .public)', conn=\(tag, privacy: .public)) sent: \(metrics.logSummary, privacy: .public)"
                    )
                })
        }
        if let staging, Self.receives(role: role, kind: kind) {
            inboxHolder.value = ClipboardTransferInbox(
                staging: staging, role: connectionRole,
                onTransferTimed: { metrics in
                    Self.logger.notice(
                        "\(received, privacy: .public) \(subject, privacy: .public) \(metrics.transferID, privacy: .public) ('\(label, privacy: .public)', conn=\(tag, privacy: .public)) completed: \(metrics.logSummary, privacy: .public)"
                    )
                })
        }

        let channel = self.channel
        let endedFlag = self.endedFlag
        let inbox = inboxHolder.value
        consumeTask = Task.detached {
            await Self.consume(
                channel: channel, label: label, connectionTag: tag, subject: subject,
                inbox: inbox, endedFlag: endedFlag, onEnded: onEnded,
                onControlFrame: { frame in
                    // Fire-and-forget: the consume loop must never wait on the
                    // main actor — a paste's promise callback occupies it, and
                    // a transfer this loop's frames open is what resolves that
                    // callback. The serial main queue preserves control-frame
                    // FIFO order; a per-frame Task would not.
                    MainActorBridge.async { handleControlFrame(frame) }
                })
        }
    }

    /// Returns once the channel is done, whether it closed on its own or `stop()`
    /// ended it.
    public func waitUntilEnded() async {
        await consumeTask?.value
    }

    /// Ends the connection: stops draining, wakes every transfer, and closes the
    /// channel. Idempotent.
    public func stop() {
        consumeTask?.cancel()
        consumeTask = nil
        // Marked before any wake, so a paste fire this cancels explains itself.
        endedFlag.set()
        stoppedFlag.set()
        outboxStorage?.cancelAll()
        inboxHolder.value?.cancelAll()
        outboxStorage = nil
        inboxHolder.value = nil
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
        inbox: ClipboardTransferInbox?,
        endedFlag: Latch,
        onEnded: @Sendable () -> Void,
        onControlFrame: @Sendable @escaping (Frame) -> Void
    ) async {
        do {
            for try await frame in channel.incoming where frame.protocolVersion == 1 {
                onControlFrame(frame)
            }
            // A guest disconnect has to survive in the log after the fact, so this
            // persists rather than logging at `.debug`/`.info`.
            logger.notice(
                "Vsock \(subject, privacy: .public) channel closed for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public))"
            )
        } catch {
            logger.warning(
                "Vsock \(subject, privacy: .public) channel ended with error for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
        // Channel closed — wake any parked pull so a materialize doesn't hang
        // forever. Marked ended first, so a paste fire that wakes here can tell
        // this teardown from a supersession and explain itself.
        endedFlag.set()
        inbox?.cancelAll()
        onEnded()
    }

    // MARK: - Sending control frames

    /// Announces `reps` under `generation` in this channel's offer vocabulary.
    nonisolated public func sendOffer(
        generation: UInt64, reps: [Kernova_V1_ClipboardRepresentationInfo], isConcealed: Bool
    ) throws {
        switch kind {
        case .clipboard:
            try channel.send(
                .clipboardOffer(generation: generation, reps: reps, isConcealed: isConcealed))
        case .drop:
            try channel.send(.dropOffer(generation: generation, reps: reps))
        }
    }

    /// Retires the offer for `generation` in this channel's release vocabulary.
    nonisolated public func sendRelease(generation: UInt64) throws {
        switch kind {
        case .clipboard: try channel.send(.clipboardRelease(generation: generation))
        case .drop: try channel.send(.dropRelease(generation: generation))
        }
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
}

/// Holds one session's inbox where any thread can read it.
private final class InboxHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ClipboardTransferInbox?

    var value: ClipboardTransferInbox? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Thread-safe one-way flag.
private final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}
