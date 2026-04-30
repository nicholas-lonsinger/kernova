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

    private static let logger = Logger(subsystem: "com.kernova.agent", category: "VsockGuestClient")
    private static let retryInterval: Duration = .seconds(5)
    private static let socketTimeoutSeconds: Int = 30

    let port: UInt32
    let label: String

    private let lock = NSLock()
    private var currentChannel: VsockChannel?
    private var reconnectTask: Task<Void, Never>?
    private var stopped = false

    init(port: UInt32, label: String) {
        self.port = port
        self.label = label
    }

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
            try? await Task.sleep(for: Self.retryInterval)
        }
    }

    private func connectAndServe(serve: @Sendable @escaping (VsockChannel) async -> Void) async {
        guard let fd = openVsockToHost() else { return }
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

    private func openVsockToHost() -> Int32? {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.logger.debug("socket(AF_VSOCK) failed for '\(self.label, privacy: .public)': errno=\(errno, privacy: .public)")
            return nil
        }

        applySocketTimeouts(fd: fd)

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
        guard rc == 0 else {
            let err = errno
            close(fd)
            Self.logger.debug("connect() to '\(self.label, privacy: .public)' port \(self.port, privacy: .public) failed: errno=\(err, privacy: .public)")
            return nil
        }
        return fd
    }

    /// Sets `SO_RCVTIMEO` / `SO_SNDTIMEO` on the fresh socket so subsequent
    /// recv/send calls can't block longer than `socketTimeoutSeconds`.
    /// `setsockopt` failures are logged at debug and otherwise ignored —
    /// without timeouts the agent still works, just less robustly.
    private func applySocketTimeouts(fd: Int32) {
        var timeout = timeval(tv_sec: Self.socketTimeoutSeconds, tv_usec: 0)
        let optionSize = socklen_t(MemoryLayout<timeval>.size)

        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, optionSize) != 0 {
            Self.logger.debug("setsockopt SO_RCVTIMEO failed for '\(self.label, privacy: .public)': errno=\(errno, privacy: .public)")
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, optionSize) != 0 {
            Self.logger.debug("setsockopt SO_SNDTIMEO failed for '\(self.label, privacy: .public)': errno=\(errno, privacy: .public)")
        }
    }
}
