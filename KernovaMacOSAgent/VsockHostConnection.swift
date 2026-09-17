import Foundation
import KernovaKit
import KernovaLogging

/// Forwards guest-emitted log records to the host on `KernovaVsockPort.log`.
///
/// Connection lifecycle is delegated to `VsockGuestClient`; this class layers
/// log-specific buffering and inbound drain on top.
///
/// Every log call here is made outside a `lock` hold: this class is the sink
/// `KernovaLogger` forwards through, so its own records re-enter `forwardLog`,
/// which takes that same non-reentrant lock.
final class VsockHostConnection: @unchecked Sendable {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "VsockHostConnection")

    /// Maximum number of `LogRecord` frames buffered between the logging thread
    /// and the host channel, oldest dropped first.
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

    let lock = NSLock()
    var pendingLogs: [Frame] = []

    /// Whether a `drainPending()` run is enqueued or in flight, guarded by
    /// `lock` — one run at a time, however many records arrive.
    private var drainScheduled = false

    /// A `scheduleDrain()` the running drain has not yet accounted for, guarded
    /// by `lock`.
    ///
    /// A connect wakes the drain without appending a frame, so a wake landing
    /// between the drain's channel read and its finishing lock hold would
    /// otherwise be swallowed by `drainScheduled` and leave the ring parked
    /// until the next record. The drain finishes only once it has seen a step
    /// with no wake outstanding.
    private var wakePending = false

    /// Records the ring has evicted since the drain last emptied it, guarded by
    /// `lock`.
    private var droppedCount = 0

    /// Whether the current outage has been reported, guarded by `lock`.
    ///
    /// A failed send's warning is itself a record, so every line the agent logs
    /// into a broken channel would otherwise cost a second one: one outage, one
    /// warning, until a send succeeds again.
    private var sendFailureAnnounced = false

    /// Whether the host has decided log forwarding yet, and if so, its verdict.
    ///
    /// `.undecided` buffers records rather than dropping them, so the boot
    /// window survives to the host's first `PolicyUpdate`.
    private enum ForwardingPolicy {
        case undecided
        case enabled
        case disabled
    }

    /// Current forwarding policy, guarded by `lock`.
    private var policy: ForwardingPolicy = .undecided

    /// Lock-guarded read of the forwarding policy for the main-thread menu.
    var isLogForwardingEnabled: Bool {
        lock.withLock { policy == .enabled }
    }

    /// Production init — forwards on `KernovaVsockPort.log`.
    convenience init() {
        self.init(client: VsockGuestClient(port: KernovaVsockPort.log, label: "log"))
    }

    /// Designated init; tests inject a socketpair-backed client.
    init(client: VsockGuestClient) {
        self.client = client
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

    /// Stops the loop, tears down any active channel, and discards the
    /// buffered log records.
    ///
    /// - Returns: the client's cancelled loop task, still winding down — see
    ///   `VsockGuestClient.stop()`. Only this call has it: the client's own
    ///   `stop` is one-shot.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        let loop = client.stop()
        lock.withLock { discardPendingLocked() }
        return loop
    }

    /// Applies a host policy update for log forwarding.
    ///
    /// Enabling resumes the loop, flushing whatever was buffered while the policy
    /// was undecided; an update that only restates "enabled" still reaches
    /// `VsockGuestClient.resume()`. Disabling closes the channel and discards the
    /// buffer — an explicit "off" ships nothing retroactively, and repeating it
    /// does nothing.
    func setEnabled(_ enabled: Bool) {
        let target: ForwardingPolicy = enabled ? .enabled : .disabled
        let needsTransition: Bool = lock.withLock {
            let was = policy
            policy = target
            return was != target
        }
        // Ahead of the no-change guard — see `VsockGuestClient.resume()`.
        if enabled { client.resume() }
        guard needsTransition else { return }
        if enabled {
            #log(Self.logger, .notice, "Log forwarding enabled by host policy")
        } else {
            client.pause()
            lock.withLock { discardPendingLocked() }
            #log(Self.logger, .notice, "Log forwarding disabled by host policy")
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
        let policy = lock.withLock { self.policy }
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

    /// Appends `frame` to the ring unless host policy has meanwhile gone
    /// explicitly `.disabled`.
    ///
    /// `forwardLog` samples the policy before building the frame, so re-checking
    /// under the same lock hold as the append is what keeps a concurrent
    /// `setEnabled(false)` from leaving this frame behind its own buffer clear.
    func bufferFrameUnlessDisabled(_ frame: Frame) {
        let startedDropping: Bool = lock.withLock {
            guard policy != .disabled else { return false }
            pendingLogs.append(frame)
            return trimToLimitLocked()
        }
        if startedDropping { reportDroppingStarted() }
    }

    /// Trims the ring to `logBufferLimit`, charging what it evicts to
    /// `droppedCount`.
    ///
    /// - Returns: `true` when this is the trim that started dropping.
    private func trimToLimitLocked() -> Bool {
        guard pendingLogs.count > Self.logBufferLimit else { return false }
        let evicted = pendingLogs.count - Self.logBufferLimit
        pendingLogs.removeFirst(evicted)
        let wasDropping = droppedCount > 0
        droppedCount += evicted
        return !wasDropping
    }

    /// Drops the ring together with the overflow tally that only describes it.
    private func discardPendingLocked() {
        pendingLogs.removeAll(keepingCapacity: false)
        droppedCount = 0
    }

    /// Announces that the ring has started evicting; the count follows from the
    /// drain that empties it.
    ///
    /// This record re-enters `forwardLog`, but `droppedCount` is nonzero by
    /// then, so the append it makes announces nothing and the recursion stops
    /// one frame deep.
    private func reportDroppingStarted() {
        #log(
            Self.logger, .warning,
            "Log forward buffer full at \(Self.logBufferLimit, privacy: .public) records — dropping the oldest until the host channel drains"
        )
    }

    // MARK: - Drain

    /// Enqueues one `drainPending()` run unless one is already pending.
    private func scheduleDrain() {
        let alreadyScheduled: Bool = lock.withLock {
            wakePending = true
            let scheduled = drainScheduled
            drainScheduled = true
            return scheduled
        }
        guard !alreadyScheduled else { return }
        drainQueue.async { [weak self] in self?.drainPending() }
    }

    /// What a drain does next, decided under `lock` so a record arriving
    /// alongside the drain either joins this run or schedules the next.
    private enum DrainStep {
        case send(Frame, on: VsockChannel)
        case reportDrops(Int)
        /// No channel, but a wake arrived since the last step: read the channel
        /// again rather than finish on a stale `nil`.
        case retry
        case finished
    }

    /// Without a channel to carry a frame the run ends, leaving the ring and
    /// the overflow tally as they are: nothing is handed out only to be put
    /// back, so what is buffered is what a reader sees at every instant, and the
    /// tally still reaches the host alongside the records it describes.
    private func nextDrainStep(channel: VsockChannel?) -> DrainStep {
        lock.withLock {
            let woken = wakePending
            wakePending = false
            guard let channel else {
                if woken { return .retry }
                drainScheduled = false
                return .finished
            }
            if !pendingLogs.isEmpty { return .send(pendingLogs.removeFirst(), on: channel) }
            if droppedCount > 0 {
                let dropped = droppedCount
                droppedCount = 0
                return .reportDrops(dropped)
            }
            // A wake from an append is already visible as a frame above, and one
            // from a connect changes nothing with the ring empty.
            drainScheduled = false
            return .finished
        }
    }

    /// Sends the ring to the host until it empties, the channel goes away, or a
    /// send fails.
    ///
    /// The one place a log frame reaches the wire, so records arrive in ring
    /// order and the frame a failed send was carrying goes back to the head.
    private func drainPending() {
        while true {
            switch nextDrainStep(channel: client.liveChannel) {
            case .finished:
                return
            case .retry:
                continue
            case .reportDrops(let dropped):
                // `drainScheduled` still stands here, so this line's own record
                // rides the run reporting it rather than scheduling another.
                #log(
                    Self.logger, .warning,
                    "Dropped \(dropped, privacy: .public) buffered log record(s) while the host channel was behind"
                )
            case .send(let frame, let channel):
                do {
                    try channel.send(frame)
                    lock.withLock { sendFailureAnnounced = false }
                } catch {
                    if parkDrain(holding: frame, failure: error) { continue }
                    return
                }
            }
        }
    }

    /// Parks the drain with `frame` back at the head of the ring, where the next
    /// connect picks it up — head re-insertion is what keeps the host's view
    /// chronological across a failed send.
    ///
    /// - Returns: `true` when a wake arrived meanwhile and the drain has to go
    ///   round again: the channel may already be a new one, and the flag stays
    ///   set so the wake is not lost. The warning below is itself such a wake,
    ///   so an outage costs one more send on the refusing channel, which fails
    ///   without announcing and parks for good.
    private func parkDrain(holding frame: Frame, failure: any Error) -> Bool {
        let (startedDropping, held, announce): (Bool, Int, Bool) = lock.withLock {
            pendingLogs.insert(frame, at: 0)
            let trimmed = trimToLimitLocked()
            let firstOfTheOutage = !sendFailureAnnounced
            if firstOfTheOutage { sendFailureAnnounced = true }
            return (trimmed, pendingLogs.count, firstOfTheOutage)
        }
        if announce {
            #log(
                Self.logger, .warning,
                "Log channel send failed, holding \(held, privacy: .public) record(s) for the next connection: \(failure.localizedDescription, privacy: .public)"
            )
        }
        if startedDropping { reportDroppingStarted() }
        return lock.withLock {
            let woken = wakePending
            wakePending = false
            if !woken { drainScheduled = false }
            return woken
        }
    }

    // MARK: - Per-connection serve

    private func serveLogChannel(_ channel: VsockChannel) async {
        // Wakes the worker rather than sending here: a host that accepts the
        // connection and then stops reading parks the drain, not this loop.
        scheduleDrain()

        // The log channel is one-way; draining is how EOF and errors are seen.
        do {
            for try await frame in channel.incoming {
                guard frame.protocolVersion == 1 else {
                    #log(
                        Self.logger, .warning,
                        "Dropping inbound frame with unsupported protocol version \(frame.protocolVersion, privacy: .public)"
                    )
                    continue
                }
                #log(
                    Self.logger, .debug,
                    "Received inbound vsock frame (type: \(String(describing: frame.payload), privacy: .public))")
            }
            #log(Self.logger, .notice, "Vsock channel closed by host")
        } catch {
            #log(
                Self.logger, .warning, "Vsock channel ended with error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
