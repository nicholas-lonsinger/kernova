import Foundation
import KernovaKit
import Darwin
import os

/// Outcome of a `VsockSocketProvider` failure: `.transient` retries the
/// connect loop, `.permanent` halts it for good.
enum VsockProviderError: Error, Sendable, Equatable {
    /// Retry-able — peer not ready, transient kernel resource pressure.
    case transient(String)
    /// Not retry-able — the kernel has no `AF_VSOCK` support.
    case permanent(String)
}

/// Opens a SOCK_STREAM fd for the given port and label.
typealias VsockSocketProvider =
    @Sendable (_ port: UInt32, _ label: String) -> Result<Int32, VsockProviderError>

/// Carries the result of a blocking `connect(2)` back to a waiter that may have
/// already given up, and settles which side owns the socket when the deadline and
/// the syscall land together.
///
/// Exactly one of `finish` and `abandon` sees the other as unfinished, so the fd
/// has exactly one owner and is never closed while the call is still in flight.
final class BlockingConnectHandoff: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: Int32?
    private var abandoned = false

    /// Records the syscall's `errno` (`0` on success).
    ///
    /// - Returns: `true` while the waiter is still there — it takes the socket;
    ///   `false` once the waiter has abandoned the attempt, leaving the caller
    ///   holding the socket.
    func finish(errno: Int32) -> Bool {
        lock.withLock {
            recorded = errno
            return !abandoned
        }
    }

    /// Gives up on a syscall that has outrun its deadline.
    ///
    /// - Returns: `true` when it had not finished — the worker now owns the
    ///   socket; `false` when it beat the deadline, leaving `outcome` readable.
    func abandon() -> Bool {
        lock.withLock {
            guard recorded == nil else { return false }
            abandoned = true
            return true
        }
    }

    /// The recorded `errno`, or `nil` while the syscall is still in flight.
    var outcome: Int32? { lock.withLock { recorded } }
}

/// Rations blocking `connect(2)` attempts per client label once earlier
/// attempts have parked in the kernel.
///
/// A parked connect never returns and never surfaces to the host — the queued
/// request appears at the listener only when the guest closes the fd
/// (docs/research/2026-08-02-macos12-vsock-blocking-connect-parks.md,
/// 2026-08-02-macos12-vsock-nonblocking-connect.md) — so the thread behind one
/// is stranded for the life of the process and no recovery drains it.
/// Unbounded, a host that never accepts would strand one thread per retry
/// forever. Only *parked* attempts are charged: an attempt whose syscall
/// returns inside its deadline costs nothing, however many run at once, so
/// concurrent healthy dials are never refused.
///
/// Past `maxParkedAttempts` parked attempts one attempt is admitted per
/// backoff interval — `backoffFloor`, doubling per additional parked attempt
/// up to `backoffCeiling` — so a persistent wedge strands threads at a rate
/// that decays to one per `backoffCeiling`. Any attempt that then completes
/// inside its deadline, connected or refused with an errno, proves the host's
/// vsock stack is answering and lifts the rationing outright: the parked
/// threads are sunk cost that traffic the host can serve must not pay for.
final class BlockingConnectGate: @unchecked Sendable {
    /// Parked attempts tolerated before admission rides the backoff.
    static let maxParkedAttempts = 3
    /// Wait before the first admission past the cap, doubled per parked
    /// attempt beyond it.
    static let backoffFloor: TimeInterval = 10
    static let backoffCeiling: TimeInterval = 600

    private struct LabelState {
        /// Attempts abandoned past their deadline whose syscall has not
        /// returned.
        var parked = 0
        /// When the most recent admission was granted.
        var lastAdmissionAt = EngineInstant(nanoseconds: 0)
        /// Whether the most recent attempt to complete did so inside its
        /// deadline — the evidence that the host is answering.
        var lastCompletedNormally = true
    }

    private let lock = NSLock()
    private var states: [String: LabelState] = [:]
    private let clock: any EngineClock

    /// Creates a gate reading time from `clock` — a manually advanced clock in
    /// tests, the platform clock in production.
    init(clock: any EngineClock = makePlatformEngineClock()) {
        self.clock = clock
    }

    /// Decides whether `label` may start a blocking connect now.
    ///
    /// - Returns: `true` unless the label is over its parked cap with nothing
    ///   completed since and its current backoff has not elapsed.
    func admit(_ label: String) -> Bool {
        lock.withLock {
            var state = states[label] ?? LabelState()
            if state.parked >= Self.maxParkedAttempts, !state.lastCompletedNormally {
                let over = state.parked - Self.maxParkedAttempts
                let backoff = min(
                    Self.backoffFloor * pow(2, Double(over)), Self.backoffCeiling)
                guard clock.seconds(since: state.lastAdmissionAt) >= backoff else { return false }
            }
            state.lastAdmissionAt = clock.now
            states[label] = state
            return true
        }
    }

    /// Charges `label` for an attempt whose deadline passed with the syscall
    /// still in the kernel.
    ///
    /// Called *before* `BlockingConnectHandoff.abandon()`, so that every
    /// `markParkReturned` — which only a worker that saw the abandoned flag
    /// can reach — is preceded by its own increment.
    func markParked(_ label: String) {
        lock.withLock {
            var state = states[label] ?? LabelState()
            state.parked += 1
            state.lastCompletedNormally = false
            states[label] = state
        }
    }

    /// Undoes a `markParked` whose syscall turned out to have beaten the
    /// deadline, leaving the attempt counted as completed.
    func revertPark(_ label: String) {
        lock.withLock {
            var state = states[label] ?? LabelState()
            state.parked = max(0, state.parked - 1)
            state.lastCompletedNormally = true
            states[label] = state
        }
    }

    /// Discharges a parked attempt whose syscall has finally returned.
    func markParkReturned(_ label: String) {
        lock.withLock {
            guard var state = states[label] else { return }
            state.parked = max(0, state.parked - 1)
            states[label] = state
        }
    }

    /// Records that an attempt completed inside its deadline, whatever its
    /// outcome — the host is answering, so rationing lifts.
    func markCompleted(_ label: String) {
        lock.withLock {
            var state = states[label] ?? LabelState()
            state.lastCompletedNormally = true
            states[label] = state
        }
    }

    #if DEBUG
    /// How many of `label`'s attempts are parked in the kernel.
    func parkedCountForTesting(_ label: String) -> Int {
        lock.withLock { states[label]?.parked ?? 0 }
    }
    #endif
}

private let blockingConnectGate = BlockingConnectGate()

/// Maintains a long-lived `socket(AF_VSOCK, SOCK_STREAM)` connection to the host
/// on one vsock port, reconnecting on disconnect or connect failure.
///
/// What to do once connected is the `serve` closure passed to `start(serve:)`;
/// when it returns, the client sleeps for `retryInterval` and reconnects.
/// Lifecycle logging uses raw `os.Logger`, never `KernovaLogger` — the agent
/// wires that sink through this very transport, so a write failure would
/// schedule another send through the broken channel.
final class VsockGuestClient: @unchecked Sendable {
    private enum LoopOutcome: Equatable {
        case retry
        /// Exit the loop; client is now permanently inert.
        case terminate
    }

    private static let logger = Logger(
        subsystem: "app.kernova.macosagent", category: "VsockGuestClient")

    /// Ceiling on how long a `recv`/`send` on a connected channel may block.
    ///
    /// The same bound a transfer's data connection uses, so one stall window
    /// governs every vsock socket the guest holds.
    private static let socketTimeoutSeconds = Int(ClipboardStreamTuning.dataSocketTimeout)

    /// Ceiling on one connect attempt.
    ///
    /// vsock is local-only with no SYN dance: connect is normally immediate
    /// success or immediate ECONNREFUSED, so 3 s is a generous ceiling that
    /// still stays under the 5 s `retryInterval`.
    static let connectTimeoutSeconds: Int = 3

    /// Classifies a `socket(AF_VSOCK)` errno as permanent or transient.
    ///
    /// `EAFNOSUPPORT` and `EPROTONOSUPPORT` mean the kernel has no `AF_VSOCK`
    /// support and will never succeed; everything else may clear up.
    static func classifySocketErrno(_ err: Int32, label: String) -> VsockProviderError {
        switch err {
        case EAFNOSUPPORT, EPROTONOSUPPORT:
            logger.error(
                "socket(AF_VSOCK) unsupported for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .permanent("socket(AF_VSOCK) unsupported for '\(label)': errno=\(err)")
        default:
            logger.warning(
                "socket(AF_VSOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .transient("socket(AF_VSOCK) failed for '\(label)': errno=\(err)")
        }
    }

    let port: UInt32
    let label: String

    private let clock: any EngineClock
    private let retryInterval: TimeInterval
    private let socketProvider: VsockSocketProvider

    private let lock = NSLock()
    private var currentChannel: VsockChannel?
    private var reconnectTask: Task<Void, Never>?
    private var stopped = false

    /// When `true`, the reconnect loop skips connect attempts and waits for
    /// `resume()`; reversible, unlike `stopped`.
    private var paused = false

    /// A `resume()` the loop has not acted on yet.
    ///
    /// Latched rather than edge-triggered: `resume()` routinely lands while the
    /// loop is mid-attempt rather than parked, and the wake must survive to the
    /// next park.
    private var wakeRequested = false

    /// The task holding the current between-attempts sleep; cancelling it is
    /// what wakes the loop early.
    private var retryWaiter: Task<Void, Never>?

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
                VsockGuestClient.openVsockToHost(port: port, label: label, clock: clock)
            }
    }

    // MARK: - Lifecycle

    /// Begins the connect/serve/reconnect loop.
    ///
    /// Idempotent. Once stopped — including by a permanent provider failure —
    /// the client cannot be restarted; create a new instance.
    func start(serve: @escaping @Sendable (VsockChannel) async -> Void) {
        lock.withLock {
            guard reconnectTask == nil, !stopped else { return }
            reconnectTask = Task.detached(priority: .utility) { [weak self] in
                await self?.runReconnectLoop(serve: serve)
            }
        }
    }

    /// Pauses the reconnect loop and tears down any active channel.
    ///
    /// Idempotent, and reversible with `resume()` — unlike `stop()`.
    func pause() {
        let ch: VsockChannel? = lock.withLock {
            paused = true
            let c = currentChannel
            currentChannel = nil
            return c
        }
        ch?.close()
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
        let waiter: Task<Void, Never>? = lock.withLock {
            paused = false
            wakeRequested = true
            return retryWaiter
        }
        waiter?.cancel()
    }

    /// Stops the loop and tears down any active channel; later `start` calls are
    /// no-ops.
    func stop() {
        let (task, ch): (Task<Void, Never>?, VsockChannel?) = lock.withLock {
            stopped = true
            let t = reconnectTask
            reconnectTask = nil
            let c = currentChannel
            currentChannel = nil
            return (t, c)
        }
        task?.cancel()
        ch?.close()
    }

    /// Currently-attached channel, for callers making synchronous best-effort
    /// sends without owning the loop.
    var liveChannel: VsockChannel? {
        lock.withLock { currentChannel }
    }

    // MARK: - Internal

    private func runReconnectLoop(serve: @Sendable @escaping (VsockChannel) async -> Void) async {
        while !Task.isCancelled {
            let isPaused: Bool = lock.withLock {
                // A wake latched before this attempt is satisfied by the attempt
                // itself, so it must not also skip the park that follows. A
                // `resume()` arriving mid-attempt is a fresh signal instead, and
                // the next `waitBeforeRetry()` consumes it.
                if !paused { wakeRequested = false }
                return paused
            }
            if !isPaused {
                let outcome = await connectAndServe(serve: serve)
                switch outcome {
                case .terminate:
                    lock.withLock { stopped = true }
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
        let parked: Bool = lock.withLock {
            if wakeRequested {
                wakeRequested = false
                return false
            }
            retryWaiter = waiter
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
        lock.withLock { retryWaiter = nil }
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
            Self.logger.error("Halting reconnect loop for '\(self.label, privacy: .public)' after permanent failure.")
            return .terminate
        }

        guard fd >= 0 else {
            Self.logger.fault(
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
        let aborted: Bool = lock.withLock {
            if stopped || paused { return true }
            currentChannel = channel
            return false
        }
        if aborted {
            channel.close()
            return .retry
        }

        Self.logger.notice(
            "Connected '\(self.label, privacy: .public)' to host vsock port \(self.port, privacy: .public)")

        await serve(channel)

        lock.withLock {
            if currentChannel === channel { currentChannel = nil }
        }
        return .retry
    }

    // MARK: - Socket helpers (static — no instance state read)

    /// Opens a raw `AF_VSOCK / SOCK_STREAM` socket and connects it to the host.
    ///
    /// Both paths bound the connect at `connectTimeoutSeconds`, by different
    /// means: macOS 26+ uses the non-blocking-plus-poll idiom, while every
    /// floor below runs a blocking `connect(2)` on a throwaway thread the loop
    /// can walk away from. Monterey's virtio-vsock never completes a
    /// non-blocking connect
    /// (docs/research/2026-08-02-macos12-vsock-nonblocking-connect.md), and
    /// macOS 13 and 14 complete it while leaving the socket state-blind — poll,
    /// kqueue, and `SO_RCVTIMEO`/`SO_SNDTIMEO` all misbehave on the fd
    /// (docs/research/2026-08-06-macos13-vsock-nonblocking-state-blind.md,
    /// docs/research/2026-08-06-macos14-vsock-state-blind.md) — so the split
    /// sits at the oldest OS the non-blocking idiom is proven on.
    static func openVsockToHost(
        port: UInt32, label: String, clock: any EngineClock
    ) -> Result<Int32, VsockProviderError> {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let err = errno
            return .failure(classifySocketErrno(err, label: label))
        }

        var addr = sockaddr_vm()
        // Darwin's `sockaddr` family carries a leading `sa_len`/`svm_len` byte the
        // networking stack may rely on; set it even though some paths infer it.
        addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_port = port
        addr.svm_cid = UInt32(VMADDR_CID_HOST)

        if #available(macOS 26.0, *) {
            guard connectNonBlocking(fd: fd, addr: addr, label: label, port: port, clock: clock)
            else {
                close(fd)
                return .failure(.transient("connect() to '\(label)' port \(port) did not complete"))
            }
        } else {
            switch connectBlocking(fd: fd, addr: addr, label: label, port: port) {
            case .connected:
                break
            case .failed(let err):
                close(fd)
                logger.warning(
                    "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: errno=\(err, privacy: .public)"
                )
                return .failure(.transient("connect() to '\(label)' port \(port) failed: errno=\(err)"))
            case .abandoned:
                // The worker owns `fd` and closes it when the kernel returns.
                return .failure(
                    .transient("connect() to '\(label)' port \(port) outran \(connectTimeoutSeconds)s"))
            case .busy:
                close(fd)
                logger.warning(
                    "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) held back: earlier attempts are parked with none completing since; the gate admits the next one after its backoff"
                )
                return .failure(
                    .transient("connect() to '\(label)' port \(port) is gated behind parked earlier attempts"))
            }
        }

        applySocketTimeouts(fd: fd, label: label)
        return .success(fd)
    }

    /// What a bounded blocking `connect(2)` did.
    enum BlockingConnectOutcome: Equatable {
        case connected
        case failed(errno: Int32)
        /// The deadline passed with the syscall still in the kernel. The worker
        /// thread owns `fd` and closes it when the call returns — the caller
        /// must not.
        case abandoned
        /// The gate refused the attempt; no socket was used.
        case busy
    }

    /// Connects `fd` with a blocking `connect(2)` through
    /// `boundedBlockingConnect`.
    private static func connectBlocking(
        fd: Int32, addr: sockaddr_vm, label: String, port: UInt32
    ) -> BlockingConnectOutcome {
        boundedBlockingConnect(fd: fd, label: label, port: port) {
            var addrCopy = addr
            let rc = withUnsafePointer(to: &addrCopy) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
                }
            }
            return rc == 0 ? 0 : errno
        }
    }

    /// Runs `connectCall` — a blocking `connect(2)` returning `0` or its
    /// `errno` — on a thread the caller can walk away from, bounded at
    /// `deadline` seconds.
    ///
    /// Darwin bounds `connect(2)` with no socket option — `SO_SNDTIMEO` covers
    /// only `send` — and a vsock connect does park indefinitely when the host
    /// stops accepting
    /// (docs/research/2026-08-02-macos12-vsock-blocking-connect-parks.md), which
    /// on the loop's own thread strands the client for the life of the process.
    /// Abandoning a thread rather than closing its socket keeps fd ownership
    /// unambiguous: nothing is closed while a syscall still holds it. `gate`
    /// and `deadline` are injectable for tests; production takes the process
    /// gate and `connectTimeoutSeconds`.
    static func boundedBlockingConnect(
        fd: Int32,
        label: String,
        port: UInt32,
        gate: BlockingConnectGate = blockingConnectGate,
        deadline: TimeInterval = TimeInterval(VsockGuestClient.connectTimeoutSeconds),
        connectCall: @escaping @Sendable () -> Int32
    ) -> BlockingConnectOutcome {
        guard gate.admit(label) else { return .busy }

        let handoff = BlockingConnectHandoff()
        let ready = DispatchSemaphore(value: 0)
        let worker = Thread {
            let waiterPresent = handoff.finish(errno: connectCall())
            if waiterPresent {
                gate.markCompleted(label)
                ready.signal()
            } else {
                gate.markParkReturned(label)
                close(fd)
            }
        }
        worker.name = "app.kernova.macosagent.vsock-connect"
        worker.start()

        if ready.wait(timeout: .now() + deadline) == .success,
            let err = handoff.outcome
        {
            return err == 0 ? .connected : .failed(errno: err)
        }
        gate.markParked(label)
        if handoff.abandon() {
            logger.warning(
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) still blocked after \(deadline, privacy: .public)s — abandoning it"
            )
            return .abandoned
        }
        gate.revertPark(label)
        // The syscall landed between the deadline expiring and the abandon: the
        // worker saw the waiter present and skipped its close, so the caller
        // owns `fd` on every arm below — the fallback must never say otherwise.
        guard let err = handoff.outcome else {
            logger.fault(
                "connect() handoff for '\(label, privacy: .public)' settled with no outcome recorded")
            assertionFailure("connect() handoff for '\(label)' settled with no outcome recorded")
            return .failed(errno: EINVAL)
        }
        return err == 0 ? .connected : .failed(errno: err)
    }

    /// Connects `fd` in non-blocking mode with the connect-plus-poll idiom.
    ///
    /// Darwin's `SO_RCVTIMEO`/`SO_SNDTIMEO` bound only `recv`/`send`, never
    /// `connect(2)`. Non-blocking mode covers the connect phase only; blocking
    /// mode is restored afterwards so those socket-level timeouts still apply.
    /// The caller owns `fd` on both paths and must `close()` it on a `false`
    /// return. The availability matches the policy split in `openVsockToHost`:
    /// this idiom is proven only on macOS 26+.
    @available(macOS 26.0, *)
    private static func connectNonBlocking(
        fd: Int32, addr: sockaddr_vm, label: String, port: UInt32, clock: any EngineClock
    ) -> Bool {
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0 else {
            let err = errno
            logger.error("fcntl(F_GETFL) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return false
        }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            let err = errno
            logger.error(
                "fcntl(F_SETFL, O_NONBLOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return false
        }

        var addrCopy = addr
        let rc = withUnsafePointer(to: &addrCopy) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        if rc != 0 {
            let connectErr = errno
            guard connectErr == EINPROGRESS else {
                logger.warning(
                    "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: errno=\(connectErr, privacy: .public)"
                )
                return false
            }
            guard awaitConnectCompletion(fd: fd, label: label, port: port, clock: clock) else {
                return false
            }
        }

        guard fcntl(fd, F_SETFL, originalFlags) >= 0 else {
            let err = errno
            logger.error(
                "fcntl(F_SETFL) restore failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return false
        }
        return true
    }

    /// Waits up to `connectTimeoutSeconds` for an in-flight non-blocking connect
    /// to complete on `fd`.
    ///
    /// The caller owns `fd` on both paths and must `close()` it on a `false`
    /// return — this helper never takes ownership.
    @available(macOS 26.0, *)
    static func awaitConnectCompletion(
        fd: Int32, label: String, port: UInt32, clock: any EngineClock
    ) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let start = clock.now

        var pollRc: Int32
        repeat {
            let remaining = Double(connectTimeoutSeconds) - clock.seconds(since: start)
            let remainingMs = Int32(max(0, remaining * 1000))
            pollRc = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, remainingMs) }
            let err = errno
            if pollRc < 0 && err != EINTR {
                logger.warning(
                    "poll() while connecting '\(label, privacy: .public)' failed: errno=\(err, privacy: .public)")
                return false
            }
        } while pollRc < 0

        if pollRc == 0 {
            logger.warning(
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) timed out after \(connectTimeoutSeconds, privacy: .public)s"
            )
            return false
        }

        // POLLHUP is not a verdict here: with SO_ERROR reading 0 the connect
        // itself completed, and a peer that hung up right after accepting — the
        // host does exactly that when its admission check refuses a channel —
        // surfaces as EOF on the first read and rides the normal reconnect
        // path. The SO_ERROR check below is the sole authority; only the
        // structural flags are fatal on sight. (Treating POLLHUP as fatal is
        // also how the state-blind pre-26 fds first presented —
        // docs/research/2026-08-06-macos13-vsock-nonblocking-state-blind.md —
        // before the whole idiom was routed away from those OSes.)
        let fatalRevents = Int16(POLLERR) | Int16(POLLNVAL)
        if pfd.revents & fatalRevents != 0 {
            var soError: Int32 = 0
            var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
            let errStr: String
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) == 0 && soError != 0 {
                errStr = "errno=\(soError)"
            } else {
                errStr = "revents=\(pfd.revents)"
            }
            logger.warning(
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: \(errStr, privacy: .public)"
            )
            return false
        }

        var soError: Int32 = 0
        var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) == 0 else {
            let err = errno
            logger.warning(
                "getsockopt(SO_ERROR) for '\(label, privacy: .public)' failed: errno=\(err, privacy: .public)")
            return false
        }
        guard soError == 0 else {
            logger.warning(
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed (deferred): errno=\(soError, privacy: .public)"
            )
            return false
        }
        return true
    }

    /// Sets `SO_RCVTIMEO` / `SO_SNDTIMEO` so later recv/send calls can't block
    /// longer than `socketTimeoutSeconds`.
    private static func applySocketTimeouts(fd: Int32, label: String) {
        var timeout = timeval(tv_sec: socketTimeoutSeconds, tv_usec: 0)
        let optionSize = socklen_t(MemoryLayout<timeval>.size)

        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, optionSize) != 0 {
            logger.warning(
                "setsockopt SO_RCVTIMEO failed for '\(label, privacy: .public)': errno=\(errno, privacy: .public)")
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, optionSize) != 0 {
            logger.warning(
                "setsockopt SO_SNDTIMEO failed for '\(label, privacy: .public)': errno=\(errno, privacy: .public)")
        }
    }
}
