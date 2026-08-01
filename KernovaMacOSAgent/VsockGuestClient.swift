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
    if #available(macOS 13.0, *) {
        return VsockGuestClient(
            port: port, label: label, clock: ContinuousEngineClock(), retryInterval: retryInterval)
    }
    return VsockGuestClient(
        port: port, label: label, clock: MonotonicEngineClock(), retryInterval: retryInterval)
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

    /// Opens a raw `AF_VSOCK / SOCK_STREAM` socket and connects to the host with
    /// the non-blocking-connect-plus-poll idiom, so `connect(2)` cannot block the
    /// reconnect loop past `connectTimeoutSeconds`.
    ///
    /// Darwin's `SO_RCVTIMEO`/`SO_SNDTIMEO` bound only `recv`/`send`, never
    /// `connect(2)`. Non-blocking mode covers the connect phase only; blocking
    /// mode is restored afterwards so those socket-level timeouts still apply.
    private static func openVsockToHost(
        port: UInt32, label: String, clock: Clock
    ) -> Result<Int32, VsockProviderError> {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let err = errno
            return .failure(classifySocketErrno(err, label: label))
        }

        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0 else {
            let err = errno
            close(fd)
            logger.error("fcntl(F_GETFL) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .failure(.transient("fcntl(F_GETFL) failed for '\(label)': errno=\(err)"))
        }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            let err = errno
            close(fd)
            logger.error(
                "fcntl(F_SETFL, O_NONBLOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .failure(.transient("fcntl(F_SETFL, O_NONBLOCK) failed for '\(label)': errno=\(err)"))
        }

        var addr = sockaddr_vm()
        // Darwin's `sockaddr` family carries a leading `sa_len`/`svm_len` byte the
        // networking stack may rely on; set it even though some paths infer it.
        addr.svm_len = UInt8(MemoryLayout<sockaddr_vm>.size)
        addr.svm_family = sa_family_t(AF_VSOCK)
        addr.svm_port = port
        addr.svm_cid = UInt32(VMADDR_CID_HOST)

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_vm>.size))
            }
        }

        if rc != 0 {
            let connectErr = errno
            guard connectErr == EINPROGRESS else {
                close(fd)
                logger.warning(
                    "connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: errno=\(connectErr, privacy: .public)"
                )
                return .failure(.transient("connect() to '\(label)' port \(port) failed: errno=\(connectErr)"))
            }
            guard awaitConnectCompletion(fd: fd, label: label, port: port, clock: clock) else {
                close(fd)
                return .failure(.transient("connect() to '\(label)' port \(port) did not complete"))
            }
        }

        guard fcntl(fd, F_SETFL, originalFlags) >= 0 else {
            let err = errno
            close(fd)
            logger.error(
                "fcntl(F_SETFL) restore failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .failure(.transient("fcntl(F_SETFL) restore failed for '\(label)': errno=\(err)"))
        }

        applySocketTimeouts(fd: fd, label: label)
        return .success(fd)
    }

    /// Waits up to `connectTimeoutSeconds` for an in-flight non-blocking connect
    /// to complete on `fd`.
    ///
    /// The caller owns `fd` on both paths and must `close()` it on a `false`
    /// return — this helper never takes ownership.
    private static func awaitConnectCompletion(
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

        // Check the error flags before trusting SO_ERROR: POLLHUP can arrive with
        // POLLOUT when the peer hung up between EINPROGRESS and completion, and
        // SO_ERROR then reads 0 because the connect itself succeeded.
        let errorRevents = Int16(POLLHUP) | Int16(POLLERR) | Int16(POLLNVAL)
        if pfd.revents & errorRevents != 0 {
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
