import Foundation
import KernovaKit
import Darwin
import os

/// The clock-independent surface of `VsockGuestClient`, for holders that must
/// run below macOS 13 and so cannot store a concrete clock instantiation.
protocol VsockReconnecting: AnyObject, Sendable {
    /// Begins the connect/serve/reconnect loop (idempotent).
    func start(serve: @escaping @Sendable (VsockChannel) async -> Void)
    /// Pauses the reconnect loop and tears down any active channel.
    func pause()
    /// Resumes the reconnect loop after `pause()`.
    func resume()
    /// Stops the loop for good and tears down any active channel.
    func stop()
    /// Currently-attached channel, for synchronous best-effort sends.
    var liveChannel: VsockChannel? { get }
}

/// Builds a client on the platform-default clock — `ContinuousClock` on
/// macOS 13+, `CLOCK_MONOTONIC` below — erased for holders that run on 12.
func makeVsockGuestClient(
    port: UInt32, label: String, retryInterval: TimeInterval = 5
) -> any VsockReconnecting {
    func build<C: EngineClock>(_ clock: C) -> any VsockReconnecting {
        VsockGuestClient(port: port, label: label, clock: clock, retryInterval: retryInterval)
    }
    if #available(macOS 13.0, *) { return build(ContinuousEngineClock()) }
    return build(MonotonicEngineClock())
}

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

/// Classifies a `socket(AF_VSOCK)` errno as permanent or transient.
///
/// `EAFNOSUPPORT` and `EPROTONOSUPPORT` mean the kernel has no `AF_VSOCK`
/// support and will never succeed; everything else may clear up.
func classifySocketErrno(_ err: Int32, label: String) -> VsockProviderError {
    switch err {
    case EAFNOSUPPORT, EPROTONOSUPPORT:
        clientLogger.error(
            "socket(AF_VSOCK) unsupported for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
        return .permanent("socket(AF_VSOCK) unsupported for '\(label)': errno=\(err)")
    default:
        clientLogger.warning(
            "socket(AF_VSOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
        return .transient("socket(AF_VSOCK) failed for '\(label)': errno=\(err)")
    }
}

// File-scope stand-ins for `static let`s, which a generic type cannot hold.
private let clientLogger = Logger(subsystem: "app.kernova.macosagent", category: "VsockGuestClient")
private let socketTimeoutSeconds: Int = 30
// vsock is local-only with no SYN dance: connect is normally immediate
// success or immediate ECONNREFUSED, so 3 s is a generous ceiling that still
// stays under the 5 s retryInterval.
private let connectTimeoutSeconds: Int = 3

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

/// Bounds the in-flight blocking `connect(2)` attempts per client label.
///
/// An abandoned connect stays parked in the kernel indefinitely — one was
/// observed outlasting 12 minutes
/// (docs/research/2026-08-02-macos12-vsock-blocking-connect-parks.md) — while
/// the reconnect loop keeps retrying on its own schedule. Unbounded, a host
/// that never accepts would strand one thread per retry for the life of the
/// process; a single slot would let one doomed park suppress every later
/// attempt just as permanently. The cap admits fresh attempts alongside parked
/// ones, so a recovered host reconnects on the next retry while a wedged label
/// strands at most `maxInFlightPerLabel` threads. A slot frees the moment its
/// syscall returns, so recovery needs no separate sweep.
final class BlockingConnectGate: @unchecked Sendable {
    /// Most parked connects one label may hold before new attempts are refused.
    static let maxInFlightPerLabel = 3

    private let lock = NSLock()
    private var inFlight: [String: Int] = [:]

    /// Claims a slot for `label`, refusing it when the cap is already parked.
    ///
    /// - Returns: `true` when a slot was free and is now held.
    func claim(_ label: String) -> Bool {
        lock.withLock {
            let count = inFlight[label, default: 0]
            guard count < Self.maxInFlightPerLabel else { return false }
            inFlight[label] = count + 1
            return true
        }
    }

    func release(_ label: String) {
        lock.withLock {
            let count = inFlight[label, default: 0]
            inFlight[label] = count > 1 ? count - 1 : nil
        }
    }

    /// Whether `label` currently holds at least one slot — for tests.
    func isClaimed(_ label: String) -> Bool {
        lock.withLock { inFlight[label, default: 0] > 0 }
    }
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
final class VsockGuestClient<Clock: EngineClock>: VsockReconnecting, @unchecked Sendable {
    private enum LoopOutcome: Equatable {
        case retry
        /// Exit the loop; client is now permanently inert.
        case terminate
    }

    private static var logger: Logger { clientLogger }

    let port: UInt32
    let label: String

    private let clock: Clock
    private let retryInterval: TimeInterval
    private let socketProvider: VsockSocketProvider

    private let lock = NSLock()
    private var currentChannel: VsockChannel?
    private var reconnectTask: Task<Void, Never>?
    private var stopped = false

    /// When `true`, the reconnect loop skips connect attempts and waits for
    /// `resume()`; reversible, unlike `stopped`.
    private var paused = false

    // MARK: - Init

    init(
        port: UInt32,
        label: String,
        clock: Clock,
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

    /// Resumes the reconnect loop after `pause()`, reconnecting within
    /// `retryInterval`.
    func resume() {
        lock.withLock { paused = false }
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
            let isPaused = lock.withLock { paused }
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
            try? await clock.sleep(for: retryInterval)
        }
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
    private static func openVsockToHost(
        port: UInt32, label: String, clock: Clock
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
                    "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) refused: \(BlockingConnectGate.maxInFlightPerLabel, privacy: .public) earlier attempts are still parked"
                )
                return .failure(
                    .transient("connect() to '\(label)' port \(port) is still parked from earlier attempts"))
            }
        }

        applySocketTimeouts(fd: fd, label: label)
        return .success(fd)
    }

    /// What a bounded blocking `connect(2)` did.
    private enum BlockingConnectOutcome {
        case connected
        case failed(errno: Int32)
        /// The deadline passed with the syscall still in the kernel. The worker
        /// thread owns `fd` and closes it when the call returns — the caller
        /// must not.
        case abandoned
        /// The label's parked-connect cap is already reached; no socket was used.
        case busy
    }

    /// Connects `fd` with a blocking `connect(2)`, bounded at
    /// `connectTimeoutSeconds` by running the call on a thread the caller can
    /// walk away from.
    ///
    /// Darwin bounds `connect(2)` with no socket option — `SO_SNDTIMEO` covers
    /// only `send` — and a vsock connect does park indefinitely when the host
    /// stops accepting
    /// (docs/research/2026-08-02-macos12-vsock-blocking-connect-parks.md), which
    /// on the loop's own thread strands the client for the life of the process.
    /// Abandoning a thread rather than closing its socket keeps fd ownership
    /// unambiguous: nothing is closed while a syscall still holds it.
    private static func connectBlocking(
        fd: Int32, addr: sockaddr_vm, label: String, port: UInt32
    ) -> BlockingConnectOutcome {
        guard blockingConnectGate.claim(label) else { return .busy }

        let handoff = BlockingConnectHandoff()
        let ready = DispatchSemaphore(value: 0)
        let worker = Thread {
            var addrCopy = addr
            let rc = withUnsafePointer(to: &addrCopy) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
                }
            }
            let recorded = rc == 0 ? 0 : errno
            let waiterPresent = handoff.finish(errno: recorded)
            blockingConnectGate.release(label)
            if waiterPresent {
                ready.signal()
            } else {
                close(fd)
            }
        }
        worker.name = "app.kernova.macosagent.vsock-connect"
        worker.start()

        if ready.wait(timeout: .now() + .seconds(connectTimeoutSeconds)) == .success,
            let err = handoff.outcome
        {
            return err == 0 ? .connected : .failed(errno: err)
        }
        if handoff.abandon() {
            logger.warning(
                "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) still blocked after \(connectTimeoutSeconds, privacy: .public)s — abandoning it"
            )
            return .abandoned
        }
        // The syscall landed between the deadline expiring and the abandon.
        guard let err = handoff.outcome else { return .abandoned }
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
        fd: Int32, addr: sockaddr_vm, label: String, port: UInt32, clock: Clock
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
        fd: Int32, label: String, port: UInt32, clock: Clock
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
