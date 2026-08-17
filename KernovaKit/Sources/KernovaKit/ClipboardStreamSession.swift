import Foundation

/// One connection's streaming engine, frame routing and control-frame delivery,
/// for either end of either chunk-streamed channel.
///
/// The owner supplies the channel and says which end of which channel it is;
/// everything below the control frames — building the sender and receiver,
/// draining the channel off the owner's actor, routing stream payloads straight
/// to the engine, and the frames the control side writes back — is here.
@MainActor
public final class ClipboardStreamSession {
    /// Which end of the wire this session is.
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
    nonisolated public let channel: VsockChannel

    /// What the log lines call the peer — the VM name on the host, the channel
    /// name in the guest.
    nonisolated private let label: String

    /// Where an inbound payload lands; `nil` for a send-only session.
    private let staging: ClipboardFileStaging?

    private var senderStorage: ClipboardStreamSender?
    private var receiverStorage: ClipboardStreamReceiver?
    private var consumeTask: Task<Void, Never>?

    /// Latched before the pulls a teardown cancels are woken, so a paste fire
    /// that wakes cancelled can tell the end of its session from a supersession
    /// or a release, which raise their own explainer.
    private let endedFlag = EndedFlag()

    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "ClipboardStreamSession")

    /// Creates a session for one accepted channel.
    ///
    /// `staging` is where inbound payloads land; the host's drop session is
    /// send-only and passes none.
    public init(
        channel: VsockChannel, role: Role, kind: Kind, label: String,
        staging: ClipboardFileStaging? = nil
    ) {
        self.channel = channel
        self.role = role
        self.kind = kind
        self.label = label
        self.staging = staging
        self.connectionTag = role == .host ? .nextHost() : .nextGuest()
        if Self.receives(role: role, kind: kind), staging == nil {
            Self.logger.fault(
                "Clipboard stream session for '\(label, privacy: .public)' receives but was given no staging"
            )
            assertionFailure("Receiving session for '\(label)' was given no staging")
        }
    }

    // MARK: - Engines

    /// The engine streaming what this side offers, or `nil` before `start()` and
    /// after `stop()`.
    public var sender: ClipboardStreamSender? { senderStorage }

    /// The engine receiving what the peer streams, or `nil` before `start()`,
    /// after `stop()`, and for a send-only session.
    public var receiver: ClipboardStreamReceiver? { receiverStorage }

    /// Whether this side ever streams payload bytes on this channel.
    private static func sends(role: Role, kind: Kind) -> Bool {
        !(role == .guest && kind == .drop)
    }

    /// Whether this side ever receives payload bytes on this channel.
    private static func receives(role: Role, kind: Kind) -> Bool {
        !(role == .host && kind == .drop)
    }

    // MARK: - Lifecycle

    /// Whether this connection is over, by `stop()` or by the channel closing
    /// under it.
    ///
    /// `nonisolated` so a paste-time fire can read it from whichever thread the
    /// pasteboard server fired on.
    nonisolated public var hasEnded: Bool { endedFlag.isSet }

    /// Builds the engine and starts draining the channel; idempotent.
    ///
    /// `handleControlFrame` receives every frame that is not a stream payload, on
    /// the main actor and in arrival order. `onEnded` runs off the main actor the
    /// moment the channel is done, so a pull parked on the main thread is woken
    /// without waiting for a main-queue hop it is itself blocking.
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

        if Self.sends(role: role, kind: kind) {
            senderStorage = ClipboardStreamSender(
                channel: channel,
                // The only measured throughput number for what this side sends,
                // so it logs at `.notice` (persisted) rather than `.debug`.
                onTransferTimed: { metrics in
                    Self.logger.notice(
                        "\(sent, privacy: .public) \(subject, privacy: .public) \(metrics.transferID, privacy: .public) ('\(label, privacy: .public)', conn=\(tag, privacy: .public)) sent: \(metrics.logSummary, privacy: .public)"
                    )
                })
        }
        if let staging, Self.receives(role: role, kind: kind) {
            receiverStorage = ClipboardStreamReceiver(
                channel: channel, staging: staging,
                onTransferTimed: { metrics in
                    Self.logger.notice(
                        "\(received, privacy: .public) \(subject, privacy: .public) \(metrics.transferID, privacy: .public) ('\(label, privacy: .public)', conn=\(tag, privacy: .public)) completed: \(metrics.logSummary, privacy: .public)"
                    )
                },
                // A lazy pull's per-transfer awaiter takes precedence over these
                // channel-wide closures, so they fire only for an unawaited
                // transfer.
                onComplete: { transferID, _ in
                    Self.logger.warning(
                        "Unawaited inbound \(subject, privacy: .public) \(transferID, privacy: .public) (conn=\(tag, privacy: .public)) completed — dropped"
                    )
                },
                onAbort: { info in
                    Self.logger.debug(
                        "Unawaited inbound \(subject, privacy: .public) \(info.transferID, privacy: .public) (conn=\(tag, privacy: .public)) aborted (\(info.rawCode, privacy: .public))"
                    )
                })
        }

        let channel = self.channel
        let role = self.role
        let sender = senderStorage
        let receiver = receiverStorage
        let endedFlag = self.endedFlag
        consumeTask = Task {
            await Self.consume(
                channel: channel, label: label, connectionTag: tag, subject: subject, role: role,
                sender: sender, receiver: receiver,
                onControlFrame: { frame in
                    // Fire-and-forget: the consume loop must never wait on the
                    // main actor — a paste's promise callback occupies it, and
                    // the stream frames routed here are what resolve that
                    // callback. Serial `DispatchQueue.main` preserves
                    // control-frame FIFO order; a per-frame Task would not.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { handleControlFrame(frame) }
                    }
                })
            // Channel closed — wake any parked pull so a materialize doesn't hang
            // forever. Marked ended first, so a paste fire that wakes here can
            // tell this teardown from a supersession and explain itself.
            endedFlag.set()
            receiver?.cancelAll()
            onEnded()
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
        senderStorage?.cancelAll()
        receiverStorage?.cancelAll()
        senderStorage = nil
        receiverStorage = nil
        channel.close()
    }

    // MARK: - Frame consumer

    /// Which way a transfer this side *sends* travels, for the log lines.
    private static func sentDirectionWord(role: Role) -> String {
        role == .host ? "Host→guest" : "Guest→host"
    }

    /// Drains the channel, routing high-frequency stream frames off the main
    /// actor.
    ///
    /// `nonisolated` so the loop runs on a cooperative thread: stream frames go
    /// straight to the thread-safe engine and only the low-frequency control
    /// frames hop to main, keeping a multi-GB transfer's chunk/ack frames off the
    /// main actor entirely. [M1]
    nonisolated private static func consume(
        channel: VsockChannel,
        label: String,
        connectionTag: ClipboardConnectionTag,
        subject: String,
        role: Role,
        sender: ClipboardStreamSender?,
        receiver: ClipboardStreamReceiver?,
        onControlFrame: @Sendable @escaping (Frame) -> Void
    ) async {
        let routingRole: ClipboardStreamRouting.Role = role == .host ? .host : .guest
        do {
            for try await frame in channel.incoming where frame.protocolVersion == 1 {
                ClipboardStreamRouting.route(
                    frame, role: routingRole, sender: sender, receiver: receiver,
                    onControlFrame: onControlFrame)
            }
            logger.info(
                "Vsock \(subject, privacy: .public) channel closed for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public))"
            )
        } catch {
            logger.warning(
                "Vsock \(subject, privacy: .public) channel ended with error for '\(label, privacy: .public)' (conn=\(connectionTag, privacy: .public)): \(error.localizedDescription, privacy: .public)"
            )
        }
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

    /// Asks the peer to stream one representation of its offer.
    nonisolated public func sendRequest(
        generation: UInt64, transferID: UInt64, uti: String, maxAcceptByteCount: UInt64
    ) throws {
        try channel.send(
            .clipboardRequest(
                generation: generation, transferID: transferID, uti: uti,
                maxAcceptByteCount: maxAcceptByteCount))
    }

    /// Tells the peer's sender to stop streaming a transfer this side is
    /// abandoning. Best-effort: a dead channel needs no abort.
    nonisolated public func sendStreamAbort(
        transferID: UInt64, code: ClipboardStreamAbortCode, message: String
    ) {
        try? channel.send(
            .clipboardStreamAbort(transferID: transferID, code: code, message: message))
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

/// Thread-safe latch for "this session is over".
private final class EndedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set() {
        lock.withLock { value = true }
    }
}
