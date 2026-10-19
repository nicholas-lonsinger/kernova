import Foundation
import KernovaKit
import KernovaLogging
import KernovaSynchronization

/// Forwards guest-emitted log records to the host on `KernovaVsockPort.log`.
///
/// Connection lifecycle is delegated to `VsockGuestClient`; this class layers
/// log-specific buffering and inbound drain on top.
///
/// Every log call here is made outside a `state` hold: this class is the sink
/// `KernovaLogger` forwards through, so its own records re-enter `forwardLog`,
/// which takes that same non-reentrant lock.
final class VsockHostConnection: Sendable {
    private let logger: KernovaLogger

    /// Maximum number of `LogRecord` frames held between the logging thread
    /// and the host channel — waiting or in flight — oldest dropped first.
    ///
    /// Sized for the bursty pre-connect window: agent boot can take 30 s+ from
    /// VM start to the first vsock connect on macOS.
    static let logBufferLimit = 256

    private let client: VsockGuestClient

    /// Serial worker holding every send on the log channel.
    ///
    /// A send parks in `write(2)` for as long as the host takes to read, and
    /// `forwardLog` runs on whatever thread emitted the record — the control
    /// channel's liveness handling included — so the park belongs here rather
    /// than on the caller.
    private let drainQueue = DispatchQueue(
        label: "app.kernova.macosagent.log-drain", qos: .utility)

    private let state = Locked(State())

    private struct State: Sendable {
        /// Records waiting for the drain, oldest first, each already framed for
        /// the wire.
        ///
        /// Framed on the way in, so a record that could not be sent is never
        /// admitted, and a send that fails means only that the channel has
        /// ended.
        var pendingLogs: [Data] = []

        /// Whether the record the drain took off `pendingLogs` is still this
        /// connection's — set while its send runs, cleared by the send's
        /// outcome or by a discard.
        ///
        /// It counts against `logBufferLimit` and in what an ended channel
        /// leaves held, so neither depends on how far the send has got; a send
        /// that fails returns the record only while it is still owned.
        var recordInFlight = false

        /// Whether a `drainPending()` run is enqueued or in flight — one run at
        /// a time, however many records arrive.
        var drainScheduled = false

        /// The channel the drain sends on: installed by `serveLogChannel` for
        /// as long as it serves, and cleared by whichever side learns the
        /// channel is dead first — the serve loop at its end, or the drain on a
        /// failed send.
        var channel: VsockChannel?

        /// Records the ring has evicted since the drain last emptied it.
        var droppedCount = 0

        var policy: ForwardingPolicy = .undecided

        /// Records the connection holds for the host: the ring, and a record in
        /// flight it still owns.
        var heldCount: Int {
            pendingLogs.count + (recordInFlight ? 1 : 0)
        }

        /// Appends `framed` unless host policy is `.disabled`, evicting the
        /// oldest waiting records until what the connection holds fits
        /// `logBufferLimit`, charging them to `droppedCount`.
        ///
        /// - Returns: `true` when this is the append that started dropping.
        mutating func append(_ framed: Data) -> Bool {
            guard policy != .disabled else { return false }
            pendingLogs.append(framed)
            let evicted = heldCount - VsockHostConnection.logBufferLimit
            guard evicted > 0 else { return false }
            pendingLogs.removeFirst(evicted)
            let wasDropping = droppedCount > 0
            droppedCount += evicted
            return !wasDropping
        }

        /// Drops every held record — the ring and one in flight — together
        /// with the overflow tally that only describes them.
        mutating func discardPending() {
            pendingLogs.removeAll(keepingCapacity: false)
            recordInFlight = false
            droppedCount = 0
        }

        /// Marks a drain run scheduled, and returns whether one already was.
        mutating func scheduleDrain() -> Bool {
            defer { drainScheduled = true }
            return drainScheduled
        }

        /// Without a channel to carry a record the run ends, leaving the ring
        /// and the overflow tally for the next connection.
        mutating func nextDrainStep() -> DrainStep {
            guard let channel else {
                drainScheduled = false
                return .finished
            }
            if !pendingLogs.isEmpty {
                recordInFlight = true
                return .send(pendingLogs.removeFirst(), on: channel)
            }
            if droppedCount > 0 {
                defer { droppedCount = 0 }
                return .reportDrops(droppedCount)
            }
            drainScheduled = false
            return .finished
        }

        /// Returns `framed`, the record a send on the ended `failedChannel` did
        /// not deliver, to the head of the ring while it is still owned, and
        /// retires `failedChannel` if it is still the installed one.
        mutating func holdForNextConnection(_ framed: Data, failedOn failedChannel: VsockChannel) {
            if recordInFlight {
                recordInFlight = false
                pendingLogs.insert(framed, at: 0)
            }
            if channel === failedChannel { channel = nil }
        }
    }

    /// Whether the host has decided log forwarding yet, and if so, its verdict.
    ///
    /// `.undecided` buffers records rather than dropping them, so the boot
    /// window survives to the host's first `PolicyUpdate`.
    private enum ForwardingPolicy {
        case undecided
        case enabled
        case disabled
    }

    /// The forwarding policy, for the main-thread menu.
    var isLogForwardingEnabled: Bool {
        state.withLock { $0.policy == .enabled }
    }

    #if DEBUG
    /// The records waiting for the drain, oldest first, each framed for the
    /// wire.
    func pendingLogsForTesting() -> [Data] {
        state.withLock { $0.pendingLogs }
    }
    #endif

    /// Production init — forwards on `KernovaVsockPort.log`.
    convenience init() {
        self.init(client: VsockGuestClient(port: KernovaVsockPort.log, label: "log"), logSink: nil)
    }

    /// Designated init; tests inject a socketpair-backed client, and a
    /// `logSink` that captures what this connection logs — `nil` forwards to
    /// the process sink.
    init(client: VsockGuestClient, logSink: KernovaLogger.ForwardingSink?) {
        self.client = client
        self.logger = KernovaLogger(
            subsystem: "app.kernova.macosagent", category: "VsockHostConnection", sink: logSink)
        // Default-disabled: no connect attempts until the host's first
        // `PolicyUpdate(logForwardingEnabled: true)`.
        self.client.pause()
    }

    /// Begins the connect/serve/reconnect loop (idempotent).
    func start() {
        client.start { [weak self] channel in
            await self?.serveLogChannel(channel)
        }
    }

    /// Discards the buffered log records, then stops the loop and tears down
    /// any active channel.
    func stop() {
        state.withLock { $0.discardPending() }
        client.stop()
    }

    /// Applies a host policy update for log forwarding.
    ///
    /// Enabling resumes the loop, flushing whatever was buffered while the policy
    /// was undecided; an update that only restates "enabled" still reaches
    /// `VsockGuestClient.resume()`. Disabling discards every held record — in
    /// flight included — in the lock hold that closes admission, then closes the
    /// channel: an explicit "off" ships nothing retroactively, and repeating it
    /// does nothing.
    func setEnabled(_ enabled: Bool) {
        let target: ForwardingPolicy = enabled ? .enabled : .disabled
        let needsTransition = state.withLock { state in
            let was = state.policy
            state.policy = target
            if target == .disabled, was != .disabled { state.discardPending() }
            return was != target
        }
        // Ahead of the no-change guard — see `VsockGuestClient.resume()`.
        if enabled { client.resume() }
        guard needsTransition else { return }
        if enabled {
            logger.log(.notice, "Log forwarding enabled by host policy")
        } else {
            client.pause()
            logger.log(.notice, "Log forwarding disabled by host policy")
        }
    }

    /// Buffers a `LogRecord` frame for the drain worker to send to the host.
    ///
    /// Safe to call from any thread, and never touches the socket: the frame
    /// joins the ring and `drainQueue` carries it to the wire, so a host that
    /// has stopped reading costs the caller nothing. With the ring full the
    /// oldest records go, counted and reported once the drain catches up.
    func forwardLog(
        level: KernovaLogLevel,
        subsystem: String,
        category: String,
        segments: [LogSegment]
    ) {
        let policy = state.withLock { $0.policy }
        if policy == .disabled { return }

        var frame = Frame()
        frame.protocolVersion = 1
        frame.logRecord = Kernova_V1_LogRecord.with {
            // Stamped at forward time, so chronology survives the deferred send.
            $0.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            $0.level = Self.wireLevel(level)
            $0.subsystem = subsystem
            $0.category = category
            $0.segments = segments.map { segment in
                Kernova_V1_LogSegment.with {
                    $0.text = segment.text
                    $0.private = segment.isPrivate
                }
            }
        }

        bufferFrameUnlessDisabled(frame)
        scheduleDrain()
    }

    /// The wire spelling of a level. `KernovaLogging` owns the level so it can
    /// stay clear of SwiftProtobuf; this is the one place the two meet.
    private static func wireLevel(_ level: KernovaLogLevel) -> Kernova_V1_LogRecord.Level {
        switch level {
        case .debug: .debug
        case .info: .info
        case .notice: .notice
        case .warning: .warning
        case .error: .error
        case .fault: .fault
        }
    }

    /// The one way a record enters the ring: frames `frame` for the wire and
    /// appends it, unless host policy is `.disabled` or the frame exceeds what
    /// the wire carries.
    ///
    /// The policy check shares this lock hold with the insert because
    /// `forwardLog` sampled the policy before building its frame.
    func bufferFrameUnlessDisabled(_ frame: Frame) {
        guard let framed = try? VsockChannel.serializeFramed(frame) else { return }
        if state.withLock({ $0.append(framed) }) { reportDroppingStarted() }
    }

    /// Announces that the ring has started evicting; the count follows from the
    /// drain that empties it.
    ///
    /// This record re-enters `forwardLog`, but `droppedCount` is nonzero by
    /// then, so the append it makes announces nothing and the recursion stops
    /// one frame deep.
    private func reportDroppingStarted() {
        logger.log(
            .warning,
            "Log forward buffer full at \(Self.logBufferLimit, privacy: .public) records — dropping the oldest until the host channel drains"
        )
    }

    // MARK: - Drain

    /// Enqueues one `drainPending()` run unless one is already pending.
    ///
    /// A run reads the ring and `channel` in the same lock hold that decides
    /// its end, so a record or channel installed after that hold finds
    /// `drainScheduled` clear here and gets a run of its own.
    private func scheduleDrain() {
        guard !state.withLock({ $0.scheduleDrain() }) else { return }
        drainQueue.async { [weak self] in self?.drainPending() }
    }

    /// What a drain does next, decided under `state` so a record or a channel
    /// arriving alongside the drain either joins this run or schedules the next.
    private enum DrainStep {
        case send(Data, on: VsockChannel)
        case reportDrops(Int)
        case finished
    }

    /// Sends the ring to the host until it empties or the channel goes away.
    ///
    /// The one place a log frame reaches the wire, so records arrive in ring
    /// order. A failed send reports nothing: it means the channel has ended,
    /// and `serveLogChannel` reports every end.
    private func drainPending() {
        while true {
            switch state.withLock({ $0.nextDrainStep() }) {
            case .finished:
                return
            case .reportDrops(let dropped):
                // `drainScheduled` still stands here, so this line's own record
                // rides the run reporting it rather than scheduling another.
                logger.log(
                    .warning,
                    "Dropped \(dropped, privacy: .public) buffered log record(s) while the host channel was behind"
                )
            case .send(let framed, let channel):
                do {
                    try channel.writeFramed(framed)
                    state.withLock { $0.recordInFlight = false }
                } catch {
                    // Head re-insertion is what keeps the host's view
                    // chronological across the next connection, and retiring
                    // the channel means this run's next step and every run a
                    // record schedules before the serve loop notices find
                    // nothing to send on.
                    state.withLock { $0.holdForNextConnection(framed, failedOn: channel) }
                }
            }
        }
    }

    // MARK: - Per-connection serve

    private func serveLogChannel(_ channel: VsockChannel) async {
        state.withLock { $0.channel = channel }
        // Wakes the worker rather than sending here: a host that accepts the
        // connection and then stops reading parks the drain, not this loop.
        scheduleDrain()

        // The log channel is one-way; draining is how EOF and errors are seen.
        var failure: (any Error)?
        do {
            for try await frame in channel.incoming {
                guard frame.protocolVersion == 1 else {
                    logger.log(
                        .warning,
                        "Dropping inbound frame with unsupported protocol version \(frame.protocolVersion, privacy: .public)"
                    )
                    continue
                }
                logger.log(
                    .debug,
                    "Received inbound vsock frame (type: \(String(describing: frame.payload), privacy: .public))")
            }
        } catch {
            failure = error
        }

        // Every channel ends here exactly once, so this is where an outage
        // reports what it leaves held: the ring, and a record a send on this
        // channel still has in flight. The channel is retired before the line
        // is logged, so the drain run its own record wakes finds nothing to
        // send on.
        let held = state.withLock { state in
            state.channel = nil
            return state.heldCount
        }
        if let failure {
            logger.log(
                .warning,
                "Vsock channel ended with error, holding \(held, privacy: .public) record(s) for the next connection: \(failure.localizedDescription, privacy: .public)"
            )
        } else {
            logger.log(
                .notice,
                "Vsock channel closed by host, holding \(held, privacy: .public) record(s) for the next connection"
            )
        }
    }
}
