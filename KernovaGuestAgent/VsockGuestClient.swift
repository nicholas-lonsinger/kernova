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

    /// Opens a SOCK_STREAM fd for the given port and label; returns nil on failure.
    typealias VsockSocketProvider = @Sendable (_ port: UInt32, _ label: String) -> Int32?

    private static let logger = Logger(subsystem: "com.kernova.agent", category: "VsockGuestClient")
    private static let socketTimeoutSeconds: Int = 30
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
    /// after the first are no-ops. Once stopped, the client cannot be
    /// restarted; create a new instance.
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
            await connectAndServe(serve: serve)
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: retryInterval)
        }
    }

    private func connectAndServe(serve: @Sendable @escaping (VsockChannel) async -> Void) async {
        guard let fd = socketProvider(port, label) else { return }
        guard fd >= 0 else {
            Self.logger.fault("socketProvider returned invalid fd \(fd, privacy: .public) for '\(self.label, privacy: .public)'")
            assertionFailure("socketProvider returned invalid fd \(fd) for '\(self.label)'")
            return
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
            return
        }

        Self.logger.notice("Connected '\(self.label, privacy: .public)' to host vsock port \(self.port, privacy: .public)")

        await serve(channel)

        lock.withLock {
            if currentChannel === channel { currentChannel = nil }
        }
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
    /// Returns the connected fd on success, nil on failure. Used as the
    /// default `socketProvider` in the production convenience init.
    private static func openVsockToHost(port: UInt32, label: String) -> Int32? {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.warning("socket(AF_VSOCK) failed for '\(label, privacy: .public)': errno=\(errno, privacy: .public)")
            return nil
        }

        // Snapshot the original flags so we can restore blocking mode after connect.
        let originalFlags = fcntl(fd, F_GETFL, 0)
        guard originalFlags >= 0 else {
            let err = errno
            close(fd)
            logger.warning("fcntl(F_GETFL) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return nil
        }
        guard fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK) >= 0 else {
            let err = errno
            close(fd)
            logger.warning("fcntl(F_SETFL, O_NONBLOCK) failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return nil
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
                return nil
            }
            guard awaitConnectCompletion(fd: fd, label: label, port: port) else {
                close(fd)
                return nil
            }
        }

        // Restore blocking mode so recv/send observe SO_RCVTIMEO/SO_SNDTIMEO timeouts.
        guard fcntl(fd, F_SETFL, originalFlags) >= 0 else {
            let err = errno
            close(fd)
            logger.warning("fcntl(F_SETFL) restore failed for '\(label, privacy: .public)': errno=\(err, privacy: .public)")
            return nil
        }

        applySocketTimeouts(fd: fd, label: label)
        return fd
    }

    /// Waits up to `connectTimeoutSeconds` for an in-flight non-blocking connect
    /// to complete on `fd`. Returns true iff the connect succeeded; false on
    /// timeout, poll error, or a deferred connect error reported via SO_ERROR.
    /// The caller is responsible for closing `fd` on false.
    private static func awaitConnectCompletion(fd: Int32, label: String, port: UInt32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(connectTimeoutSeconds * 1000)

        var pollRc: Int32
        repeat {
            pollRc = withUnsafeMutablePointer(to: &pfd) { poll($0, 1, timeoutMs) }
        } while pollRc < 0 && errno == EINTR

        if pollRc == 0 {
            logger.warning("connect() to '\(label, privacy: .public)' port \(port, privacy: .public) timed out after \(connectTimeoutSeconds, privacy: .public)s")
            return false
        }
        if pollRc < 0 {
            logger.warning("poll() while connecting '\(label, privacy: .public)' failed: errno=\(errno, privacy: .public)")
            return false
        }

        var soError: Int32 = 0
        var soErrorLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &soErrorLen) == 0 else {
            logger.warning("getsockopt(SO_ERROR) for '\(label, privacy: .public)' failed: errno=\(errno, privacy: .public)")
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
