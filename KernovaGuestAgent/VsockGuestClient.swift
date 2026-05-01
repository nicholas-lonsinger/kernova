import Foundation
import KernovaProtocol
import Darwin
import os

/// Maintains a long-lived `socket(AF_VSOCK, SOCK_STREAM)` connection from the
/// guest agent to the host on a single vsock port, with automatic reconnect on
/// disconnect or connect failure.
///
/// This class owns the connection lifecycle — connect attempt, retry on
/// failure, sleep between attempts. *What* to do once connected is delegated
/// to the `serve` closure passed to `start(serve:)`. When `serve` returns,
/// the client sleeps for `retryInterval` and reconnects.
///
/// Multiple guest services (log, clipboard, …) each instantiate their own
/// `VsockGuestClient` on their own port; the connection-lifecycle logic is
/// shared so each service only writes its own protocol-specific code.
///
/// RATIONALE: This file deliberately uses raw `os.Logger` rather than the
/// `KernovaLogger` wrapper most agent files use. Connection-lifecycle logs
/// (connect-attempt failures, EOF events) flow over the same vsock channel
/// that this class manages — routing them through `KernovaLogger` would risk
/// a feedback loop where a write failure logs an event that schedules
/// another send through the broken channel.
final class VsockGuestClient: @unchecked Sendable {

    /// Outcome of a `VsockSocketProvider` failure. `.transient` failures cause
    /// the reconnect loop to sleep and retry; `.permanent` failures cause the
    /// loop to exit and the client to enter its terminal "cannot be restarted"
    /// state.
    enum VsockProviderError: Error, Sendable, Equatable {
        /// Retry-able — peer not ready, transient kernel resource pressure, etc.
        case transient(String)
        /// Not retry-able — kernel doesn't support AF_VSOCK, sandbox prohibits
        /// the syscall, etc. Logging once at error level is sufficient.
        case permanent(String)
    }

    /// Opens a SOCK_STREAM fd for the given port and label; returns `.success`
    /// with the connected fd, or `.failure` with a `.transient` or `.permanent`
    /// error indicating whether the loop should retry or halt.
    typealias VsockSocketProvider =
        @Sendable (_ port: UInt32, _ label: String) -> Result<Int32, VsockProviderError>

    /// Outcome produced by `connectAndServe` to control the reconnect loop.
    private enum LoopOutcome: Equatable {
        /// Sleep `retryInterval`, then try again.
        case retry
        /// Exit the loop; client is now permanently inert.
        case terminate
    }

    private static let logger = Logger(subsystem: "com.kernova.agent", category: "VsockGuestClient")
    private static let socketTimeoutSeconds: Int = 30
    // RATIONALE: vsock is a local-only transport with no SYN dance, so connect
    // is normally immediate-success or immediate-ECONNREFUSED. 3s is a generous
    // ceiling that stays well under the 5s retryInterval.
    private static let connectTimeoutSeconds: Int = 3

    let port: UInt32
    let label: String

    private let retryInterval: Duration
    private let socketProvider: VsockSocketProvider

    private let lock = NSLock()
    private var currentChannel: VsockChannel?
    private var reconnectTask: Task<Void, Never>?
    private var stopped = false

    // MARK: - Init

    /// Creates a client for the given port. Pass a custom `socketProvider` and
    /// `retryInterval` in tests; production callers can use the defaults.
    init(
        port: UInt32,
        label: String,
        retryInterval: Duration = .seconds(5),
        socketProvider: VsockSocketProvider? = nil
    ) {
        self.port = port
        self.label = label
        self.retryInterval = retryInterval
        self.socketProvider = socketProvider ?? { port, label in
            VsockGuestClient.openVsockToHost(port: port, label: label)
        }
    }

    // MARK: - Lifecycle

    /// Begins the connect/serve/reconnect loop. Idempotent — repeated calls
    /// after the first are no-ops. Once stopped (or permanently terminated by a
    /// permanent provider failure), the client cannot be restarted; create a
    /// new instance.
    func start(serve: @escaping @Sendable (VsockChannel) async -> Void) {
        lock.withLock {
            guard reconnectTask == nil, !stopped else { return }
            reconnectTask = Task.detached(priority: .utility) { [weak self] in
                await self?.runReconnectLoop(serve: serve)
            }
        }
    }

    /// Stops the loop and tears down any active channel. Subsequent `start`
    /// calls are no-ops.
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

    /// Currently-attached channel, or nil. Useful for callers that need to
    /// peek for synchronous best-effort sends (e.g. log forwarding) without
    /// owning the loop.
    var liveChannel: VsockChannel? {
        lock.withLock { currentChannel }
    }

    // MARK: - Internal

    private func runReconnectLoop(serve: @Sendable @escaping (VsockChannel) async -> Void) async {
        while !Task.isCancelled {
            let outcome = await connectAndServe(serve: serve)
            if outcome == .terminate { break }
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: retryInterval)
        }
    }

    private func connectAndServe(
        serve: @Sendable @escaping (VsockChannel) async -> Void
    ) async -> LoopOutcome {
        let fd: Int32
        switch socketProvider(port, label) {
        case .success(let f):
            fd = f
        case .failure(.transient(let reason)):
            Self.logger.warning("\(reason, privacy: .public)")
            return .retry
        case .failure(.permanent(let reason)):
            Self.logger.error(
                "\(reason, privacy: .public). Halting reconnect loop for '\(self.label, privacy: .public)'."
            )
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

        let aborted: Bool = lock.withLock {
            if stopped { return true }
            currentChannel = channel
            return false
        }
        if aborted {
            channel.close()
            return .retry
        }

        Self.logger.notice("Connected '\(self.label, privacy: .public)' to host vsock port \(self.port, privacy: .public)")

        await serve(channel)

        lock.withLock {
            if currentChannel === channel { currentChannel = nil }
        }
        return .retry
    }

    // MARK: - Socket helpers (static — no instance state read)

    /// Opens a raw `AF_VSOCK / SOCK_STREAM` socket and connects to the host
    /// using the non-blocking-connect-with-poll idiom so `connect(2)` can't
    /// block the reconnect loop longer than `connectTimeoutSeconds`.
    ///
    /// `SO_RCVTIMEO`/`SO_SNDTIMEO` from Darwin do not bound `connect(2)`,
    /// only `recv`/`send`. Non-blocking mode is used exclusively for the
    /// connect phase; blocking mode is restored afterwards so subsequent
    /// `recv`/`send` calls continue to observe the socket-level timeouts.
    ///
    /// Returns `.success(fd)` on success, `.failure(.permanent(...))` when
    /// `AF_VSOCK` is unsupported, or `.failure(.transient(...))` for all other
    /// failures. Used as the default `socketProvider` in the production
    /// convenience init.
    private static func openVsockToHost(
        port: UInt32, label: String
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
            logger.warning("fcntl(F_GETFL) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .failure(.transient("fcntl(F_GETFL) failed for '\(label)': errno=\(err)"))
        }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            let err = errno
            close(fd)
            logger.warning("fcntl(F_SETFL, O_NONBLOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .failure(.transient("fcntl(F_SETFL, O_NONBLOCK) failed for '\(label)': errno=\(err)"))
        }

        var addr = sockaddr_vm()
        // Darwin's `sockaddr` family carries a leading `sa_len`/`svm_len`
        // byte that the networking stack may rely on; set it explicitly
        // even though some kernel paths infer it.
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
                logger.warning("connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: errno=\(connectErr, privacy: .public)")
                return .failure(.transient("connect() to '\(label)' port \(port) failed: errno=\(connectErr)"))
            }
            guard awaitConnectCompletion(fd: fd, label: label, port: port) else {
                close(fd)
                return .failure(.transient("connect() to '\(label)' port \(port) did not complete"))
            }
        }

        guard fcntl(fd, F_SETFL, originalFlags) >= 0 else {
            let err = errno
            close(fd)
            logger.warning("fcntl(F_SETFL) restore failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .failure(.transient("fcntl(F_SETFL) restore failed for '\(label)': errno=\(err)"))
        }

        applySocketTimeouts(fd: fd, label: label)
        return .success(fd)
    }

    /// Classifies a `socket(AF_VSOCK)` errno value into a `.permanent` or
    /// `.transient` provider error. `EAFNOSUPPORT` and `EPROTONOSUPPORT`
    /// indicate the kernel does not support AF_VSOCK at all and will never
    /// succeed; all other values (resource exhaustion, access control) may
    /// clear up and are classified as transient.
    private static func classifySocketErrno(_ err: Int32, label: String) -> VsockProviderError {
        switch err {
        case EAFNOSUPPORT, EPROTONOSUPPORT:
            logger.error("socket(AF_VSOCK) unsupported for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .permanent("socket(AF_VSOCK) unsupported for '\(label)': errno=\(err)")
        default:
            logger.warning("socket(AF_VSOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return .transient("socket(AF_VSOCK) failed for '\(label)': errno=\(err)")
        }
    }

    /// Waits up to `connectTimeoutSeconds` for an in-flight non-blocking connect
    /// to complete on `fd`. Returns true on success, false on timeout, poll
    /// error, or a deferred connect error. Caller owns `fd` on both paths and
    /// must `close()` it on false return — this helper does not assume ownership.
    private static func awaitConnectCompletion(fd: Int32, label: String, port: UInt32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let deadline = ContinuousClock.now + .seconds(connectTimeoutSeconds)

        var pollRc: Int32
        repeat {
            let remaining = deadline - ContinuousClock.now
            let remainingMs = Int32(max(0, Double(remaining.components.seconds) * 1000
                + Double(remaining.components.attoseconds) / 1e15))
            pollRc = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, remainingMs) }
            let err = errno
            if pollRc < 0 && err != EINTR {
                logger.warning("poll() while connecting '\(label, privacy: .public)' failed: errno=\(err, privacy: .public)")
                return false
            }
        } while pollRc < 0

        if pollRc == 0 {
            logger.warning("connect() to '\(label, privacy: .public)' port \(port, privacy: .public) timed out after \(connectTimeoutSeconds, privacy: .public)s")
            return false
        }

        // Check output-only error flags before trusting SO_ERROR. POLLHUP can
        // arrive with POLLOUT on a peer that hung up between EINPROGRESS and
        // completion; SO_ERROR may read 0 because the connect itself succeeded.
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
            logger.warning("connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed: \(errStr, privacy: .public)")
            return false
        }

        var soError: Int32 = 0
        var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) == 0 else {
            let err = errno
            logger.warning("getsockopt(SO_ERROR) for '\(label, privacy: .public)' failed: errno=\(err, privacy: .public)")
            return false
        }
        guard soError == 0 else {
            logger.warning("connect() to '\(label, privacy: .public)' port \(port, privacy: .public) failed (deferred): errno=\(soError, privacy: .public)")
            return false
        }
        return true
    }

    /// Sets `SO_RCVTIMEO` / `SO_SNDTIMEO` on the fresh socket so subsequent
    /// recv/send calls can't block longer than `socketTimeoutSeconds`.
    /// `setsockopt` failures are logged at warning and otherwise ignored —
    /// without timeouts the agent still works, just less robustly.
    private static func applySocketTimeouts(fd: Int32, label: String) {
        var timeout = timeval(tv_sec: socketTimeoutSeconds, tv_usec: 0)
        let optionSize = socklen_t(MemoryLayout<timeval>.size)

        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, optionSize) != 0 {
            logger.warning("setsockopt SO_RCVTIMEO failed for '\(label, privacy: .public)': errno=\(errno, privacy: .public)")
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, optionSize) != 0 {
            logger.warning("setsockopt SO_SNDTIMEO failed for '\(label, privacy: .public)': errno=\(errno, privacy: .public)")
        }
    }
}
