import Foundation
import KernovaKit
import Darwin
import KernovaLogging
import KernovaPlatformDarwin
import KernovaSynchronization

/// Opens a SOCK_STREAM fd for the given port and label.
typealias VsockSocketProvider =
    @Sendable (_ port: UInt32, _ label: String) -> Result<Int32, VsockConnectFailure>

/// Maintains a long-lived `socket(AF_VSOCK, SOCK_STREAM)` connection to the host
/// on one vsock port, reconnecting on disconnect or connect failure.
///
/// What to do once connected is the `serve` closure passed to `start(serve:)`;
/// when it returns, the client sleeps for `retryInterval` and reconnects.
final class VsockGuestClient: Sendable {
    private enum LoopOutcome: Equatable {
        case retry
        /// Exit the loop; client is now permanently inert.
        case terminate
    }

    private static let logger = KernovaLogger(
        subsystem: "app.kernova.macosagent", category: "VsockGuestClient")

    /// Ceiling on how long a `recv`/`send` on a connected channel may block.
    ///
    /// The same bound a transfer's data connection uses, so one stall window
    /// governs every vsock socket the guest holds.
    private static let socketTimeoutSeconds = Int(ClipboardStreamTuning.dataSocketTimeout)

    let port: UInt32
    let label: String

    private let clock: any EngineClock
    private let retryInterval: TimeInterval
    private let socketProvider: VsockSocketProvider

    private let state = Locked(State())

    private struct State: Sendable {
        var currentChannel: VsockChannel?
        var reconnectTask: Task<Void, Never>?
        var stopped = false

        /// When `true`, the reconnect loop skips connect attempts and waits for
        /// `resume()`; reversible, unlike `stopped`.
        var paused = false

        /// A `resume()` the loop has not acted on yet.
        ///
        /// Latched rather than edge-triggered: `resume()` routinely lands while
        /// the loop is mid-attempt rather than parked, and the wake must survive
        /// to the next park.
        var wakeRequested = false

        /// The task holding the current between-attempts sleep; cancelling it
        /// is what wakes the loop early.
        var retryWaiter: Task<Void, Never>?

        /// Detaches the current channel, for the caller to close outside the
        /// lock.
        mutating func takeChannel() -> VsockChannel? {
            defer { currentChannel = nil }
            return currentChannel
        }
    }

    // MARK: - Init

    init(
        port: UInt32,
        label: String,
        clock: any EngineClock = makePlatformEngineClock(),
        retryInterval: TimeInterval = 5,
        socketProvider: VsockSocketProvider? = nil
    ) {
        self.port = port
        self.label = label
        self.clock = clock
        self.retryInterval = retryInterval
        self.socketProvider =
            socketProvider ?? { port, label in
                VsockGuestClient.openVsockToHost(port: port, label: label)
            }
    }

    // MARK: - Lifecycle

    /// Begins the connect/serve/reconnect loop.
    ///
    /// Idempotent. Once stopped — including by a permanent provider failure —
    /// the client cannot be restarted; create a new instance.
    func start(serve: @escaping @Sendable (VsockChannel) async -> Void) {
        state.withLock { state in
            guard state.reconnectTask == nil, !state.stopped else { return }
            state.reconnectTask = Task.detached(priority: .utility) { [weak self] in
                await self?.runReconnectLoop(serve: serve)
            }
        }
    }

    /// Pauses the reconnect loop and tears down any active channel.
    ///
    /// Idempotent, and reversible with `resume()` — unlike `stop()`.
    func pause() {
        let channel = state.withLock { state in
            state.paused = true
            return state.takeChannel()
        }
        channel?.close()
    }

    /// Resumes the reconnect loop after `pause()` and has it connect now rather
    /// than at the end of the interval it is sleeping through.
    ///
    /// Idempotent, and meaningful on a client that was never paused: there it
    /// means "reconnect at the next opportunity". The agent calls it for every
    /// host policy update that says enabled, including one that changes
    /// nothing, because that update is also the host's word that its control
    /// handshake has landed — the thing the host's feature-channel admission
    /// gate refuses connections ahead of.
    func resume() {
        let waiter = state.withLock { state in
            state.paused = false
            state.wakeRequested = true
            return state.retryWaiter
        }
        waiter?.cancel()
    }

    /// Stops the loop and tears down any active channel; later `start` calls are
    /// no-ops.
    ///
    /// The cancelled loop task is still winding down when this returns — the
    /// `serve` closure may be mid-run inside it.
    func stop() {
        let (task, channel) = state.withLock { state in
            state.stopped = true
            defer { state.reconnectTask = nil }
            return (state.reconnectTask, state.takeChannel())
        }
        task?.cancel()
        channel?.close()
    }

    #if DEBUG
    /// Test seam.
    var liveChannelForTesting: VsockChannel? {
        state.withLock { $0.currentChannel }
    }
    #endif

    // MARK: - Internal

    private func runReconnectLoop(serve: @Sendable @escaping (VsockChannel) async -> Void) async {
        while !Task.isCancelled {
            let isPaused = state.withLock { state in
                // A wake latched before this attempt is satisfied by the attempt
                // itself, so it must not also skip the park that follows. A
                // `resume()` arriving mid-attempt is a fresh signal instead, and
                // the next `waitBeforeRetry()` consumes it.
                if !state.paused { state.wakeRequested = false }
                return state.paused
            }
            if !isPaused {
                let outcome = await connectAndServe(serve: serve)
                switch outcome {
                case .terminate:
                    state.withLock { $0.stopped = true }
                    return
                case .retry:
                    break
                }
            }
            guard !Task.isCancelled else { break }
            await waitBeforeRetry()
        }
    }

    /// Suspends between connect attempts until `retryInterval` elapses,
    /// `resume()` wakes the loop, or the loop task is cancelled.
    ///
    /// The sleep runs in its own task so `resume()` can cancel it without
    /// cancelling the loop, and one lock hold both consumes a pending wake and
    /// publishes the sleeper, so a `resume()` racing this call either finds the
    /// sleeper to cancel or leaves the flag that skips the park.
    private func waitBeforeRetry() async {
        let waiter = Task<Void, Never> { [clock, retryInterval] in
            try? await clock.sleep(for: retryInterval)
        }
        let parked = state.withLock { state in
            if state.wakeRequested {
                state.wakeRequested = false
                return false
            }
            state.retryWaiter = waiter
            return true
        }
        guard parked else {
            waiter.cancel()
            return
        }
        await withTaskCancellationHandler {
            await waiter.value
        } onCancel: {
            waiter.cancel()
        }
        state.withLock { $0.retryWaiter = nil }
    }

    private func connectAndServe(
        serve: @Sendable @escaping (VsockChannel) async -> Void
    ) async -> LoopOutcome {
        let fd: Int32
        switch socketProvider(port, label) {
        case .success(let f):
            fd = f
        case .failure(.transient):
            // Already logged with errno context by the provider.
            return .retry
        case .failure(.permanent):
            Self.logger.log(
                .error,
                "Halting reconnect loop for '\(self.label, privacy: .public)' after permanent failure.")
            return .terminate
        }

        guard fd >= 0 else {
            Self.logger.log(
                .fault,
                "socketProvider returned invalid fd \(fd, privacy: .public) for '\(self.label, privacy: .public)'"
            )
            assertionFailure("socketProvider returned invalid fd \(fd) for '\(self.label)'")
            return .retry
        }

        let channel = VsockChannel(fileDescriptor: fd)
        channel.start()

        // Re-check `paused` under the same lock that publishes `currentChannel`:
        // a `pause()` landing while `socketProvider` was mid-flight would
        // otherwise be overwritten here and `serve` would run against policy.
        let aborted = state.withLock { state in
            if state.stopped || state.paused { return true }
            state.currentChannel = channel
            return false
        }
        if aborted {
            channel.close()
            return .retry
        }

        Self.logger.log(
            .notice,
            "Connected '\(self.label, privacy: .public)' to host vsock port \(self.port, privacy: .public)")

        await serve(channel)

        state.withLock { state in
            if state.currentChannel === channel { state.currentChannel = nil }
        }
        return .retry
    }

    // MARK: - Socket helpers (static — no instance state read)

    /// Connects to the host's `port` through `DarwinVsockConnect`, which bounds the connect on every macOS
    /// the agent supports, then bounds the channel's blocking reads and writes.
    static func openVsockToHost(port: UInt32, label: String) -> Result<Int32, VsockConnectFailure> {
        DarwinVsockConnect.connect(port: port, label: label).map { fd in
            applySocketTimeouts(fd: fd, label: label)
            return fd
        }
    }

    /// Sets `SO_RCVTIMEO` / `SO_SNDTIMEO` so later recv/send calls can't block
    /// longer than `socketTimeoutSeconds`.
    private static func applySocketTimeouts(fd: Int32, label: String) {
        var timeout = timeval(tv_sec: socketTimeoutSeconds, tv_usec: 0)
        let optionSize = socklen_t(MemoryLayout<timeval>.size)

        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, optionSize) != 0 {
            logger.log(
                .warning,
                "setsockopt SO_RCVTIMEO failed for '\(label, privacy: .public)': errno=\(errno, privacy: .public)")
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, optionSize) != 0 {
            logger.log(
                .warning,
                "setsockopt SO_SNDTIMEO failed for '\(label, privacy: .public)': errno=\(errno, privacy: .public)")
        }
    }
}
