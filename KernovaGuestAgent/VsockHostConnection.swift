import Foundation
import KernovaProtocol
import Darwin
import os

/// Maintains a long-lived vsock connection from the guest agent to the host
/// on `KernovaVsockPort.log` (49153) for log forwarding (and, eventually,
/// other guest-emitted traffic).
///
/// Behavior:
/// - Connects with `socket(AF_VSOCK, SOCK_STREAM, 0)` + `connect()` to
///   `(VMADDR_CID_HOST, 49153)`
/// - On connect, sends `Hello` and then drains the channel until EOF
/// - On disconnect or connect failure, waits `retryInterval` and retries
/// - `send(_:)` is safe from any thread — drops the frame if not currently
///   connected (logs are best-effort)
final class VsockHostConnection: @unchecked Sendable {

    // RATIONALE: This file deliberately uses raw `os.Logger` rather than the
    // `KernovaLogger` wrapper that every other agent file uses. Routing this
    // class's internal logs (connect-attempt failures, EOF events, flush-loop
    // outcomes) through `KernovaLogger` would forward them via this same
    // connection — risking a feedback loop where a write failure logs an
    // event that schedules another send through the broken channel. Keep all
    // VsockHostConnection diagnostics local to the guest's `os.Logger`.
    private static let logger = Logger(subsystem: "com.kernova.agent", category: "VsockHostConnection")

    /// Same port as `Kernova/Services/VsockPorts.swift::KernovaVsockPort.log`
    /// — duplicated here rather than imported so the two sides can drift
    /// independently if needed (e.g. a guest agent built against an older
    /// host). The port number is part of the wire contract.
    private static let port: UInt32 = 49153

    private static let retryInterval: Duration = .seconds(5)

    /// Worst-case bound on a single send/recv blocking call on the vsock
    /// fd. Local vsock connect/send/recv normally return in milliseconds;
    /// this is purely a safety net against a wedged host listener or a VM
    /// in a partial-pause state where the kernel side is alive but the
    /// user-space service isn't draining.
    private static let socketTimeoutSeconds: Int = 30

    /// Maximum number of `LogRecord` frames buffered while the channel is
    /// down. Older entries are dropped first.
    ///
    /// Sized for the bursty pre-connect window: agent boot can take 30s+
    /// from VM-start to first vsock connect on macOS, and Phase 4's
    /// clipboard work will push `.debug` traffic that could fill a smaller
    /// buffer well before Hello lands. 256 frames at ~200 bytes apiece is
    /// ~50 KiB of bounded memory, which is fine for this purpose.
    private static let logBufferLimit = 256

    private let lock = NSLock()
    private var channel: VsockChannel?
    private var reconnectTask: Task<Void, Never>?
    private var stopped = false

    /// `LogRecord` frames emitted before/between connections. Drained on
    /// each successful Hello send.
    private var pendingLogs: [Frame] = []

    init() {}

    /// Begins the connect/serve/reconnect loop. Idempotent.
    func start() {
        let shouldStart: Bool = lock.withLock {
            guard reconnectTask == nil, !stopped else { return false }
            reconnectTask = Task.detached(priority: .utility) { [weak self] in
                await self?.runReconnectLoop()
            }
            return true
        }
        _ = shouldStart
    }

    /// Stops the loop and tears down any active channel.
    func stop() {
        let (task, ch): (Task<Void, Never>?, VsockChannel?) = lock.withLock {
            stopped = true
            let t = reconnectTask
            reconnectTask = nil
            let c = channel
            channel = nil
            pendingLogs.removeAll(keepingCapacity: false)
            return (t, c)
        }

        task?.cancel()
        ch?.close()
    }

    /// Best-effort send. Returns `true` when the frame was handed to a live
    /// channel; `false` if there is no current connection or the underlying
    /// write failed. Errors do not propagate — a failing send tears the
    /// channel down so the reconnect loop picks up.
    @discardableResult
    func send(_ frame: Frame) -> Bool {
        let ch: VsockChannel? = lock.withLock { channel }
        guard let ch else { return false }

        do {
            try ch.send(frame)
            return true
        } catch {
            return false
        }
    }

    /// Builds and best-effort sends a `LogRecord` frame to the host. When
    /// no connection is currently active, the frame is buffered (up to
    /// `logBufferLimit` records, oldest dropped first) and flushed once
    /// the next Hello succeeds. Returns `true` when the frame was handed
    /// to a live channel synchronously.
    @discardableResult
    func forwardLog(
        level: Kernova_V1_LogRecord.Level,
        subsystem: String,
        category: String,
        message: String
    ) -> Bool {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.logRecord = Kernova_V1_LogRecord.with {
            $0.timestampMs = Int64(Date().timeIntervalSince1970 * 1000)
            $0.level = level
            $0.subsystem = subsystem
            $0.category = category
            $0.message = message
        }

        // Try to send live; otherwise enqueue for the next connection.
        let ch: VsockChannel? = lock.withLock {
            if let live = channel {
                return live
            }
            if !stopped {
                pendingLogs.append(frame)
                if pendingLogs.count > Self.logBufferLimit {
                    pendingLogs.removeFirst(pendingLogs.count - Self.logBufferLimit)
                }
            }
            return nil
        }

        guard let ch else { return false }
        do {
            try ch.send(frame)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Reconnect loop

    private func runReconnectLoop() async {
        while !Task.isCancelled {
            await connectAndServe()
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: Self.retryInterval)
        }
    }

    private func connectAndServe() async {
        guard let fd = openVsockToHost(port: Self.port) else {
            return
        }

        let channel = VsockChannel(fileDescriptor: fd)
        channel.start()

        let aborted: Bool = lock.withLock {
            if stopped { return true }
            self.channel = channel
            return false
        }
        if aborted {
            channel.close()
            return
        }

        sendHello(on: channel)
        Self.logger.notice("Connected to host vsock on port \(Self.port, privacy: .public)")

        flushPendingLogs(on: channel)

        // Drain the inbound stream so we observe EOF / errors. The log
        // channel is one-way today; any inbound message is logged and
        // discarded.
        do {
            for try await frame in channel.incoming {
                Self.logger.debug("Received inbound vsock frame (type: \(String(describing: frame.payload), privacy: .public))")
            }
            Self.logger.notice("Vsock channel closed by host")
        } catch {
            Self.logger.warning("Vsock channel ended with error: \(error.localizedDescription, privacy: .public)")
        }

        lock.withLock {
            if self.channel === channel {
                self.channel = nil
            }
        }
    }

    // MARK: - Socket helpers

    private func openVsockToHost(port: UInt32) -> Int32? {
        let fd = socket(AF_VSOCK, SOCK_STREAM, 0)
        guard fd >= 0 else {
            Self.logger.debug("socket(AF_VSOCK) failed: errno=\(errno, privacy: .public)")
            return nil
        }

        applySocketTimeouts(fd: fd)

        var addr = sockaddr_vm()
        // Darwin's `sockaddr` family carries a leading `sa_len`/`svm_len`
        // byte that the networking stack may rely on; setting it
        // explicitly is the documented-safe pattern even though some
        // kernel paths infer it.
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
            Self.logger.debug("connect() to host vsock port \(port, privacy: .public) failed: errno=\(err, privacy: .public)")
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
            Self.logger.debug("setsockopt SO_RCVTIMEO failed: errno=\(errno, privacy: .public)")
        }
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, optionSize) != 0 {
            Self.logger.debug("setsockopt SO_SNDTIMEO failed: errno=\(errno, privacy: .public)")
        }
    }

    // MARK: - Hello

    /// Drains `pendingLogs` onto a live channel. On a mid-flush send failure
    /// the channel is dead — but the unflushed remainder is re-enqueued at
    /// the head of `pendingLogs` (ordered before any newly-added frames so
    /// chronological order is preserved) so the next successful reconnect
    /// retries them. The buffer cap is re-applied after re-enqueue, so a
    /// chronic flush failure won't grow memory unbounded.
    private func flushPendingLogs(on channel: VsockChannel) {
        let drained: [Frame] = lock.withLock {
            let p = pendingLogs
            pendingLogs.removeAll(keepingCapacity: true)
            return p
        }
        guard !drained.isEmpty else { return }

        for (index, frame) in drained.enumerated() {
            do {
                try channel.send(frame)
            } catch {
                let unflushed = Array(drained[index...])
                lock.withLock {
                    pendingLogs.insert(contentsOf: unflushed, at: 0)
                    if pendingLogs.count > Self.logBufferLimit {
                        pendingLogs.removeFirst(pendingLogs.count - Self.logBufferLimit)
                    }
                }
                Self.logger.warning(
                    "Re-enqueued \(unflushed.count, privacy: .public) buffered log frame(s) after flush failure: \(error.localizedDescription, privacy: .public)"
                )
                return
            }
        }
        Self.logger.debug("Flushed \(drained.count, privacy: .public) buffered log frame(s)")
    }

    private func sendHello(on channel: VsockChannel) {
        var hello = Frame()
        hello.protocolVersion = 1
        hello.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = ["log.records.v1"]
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = ProcessInfo.processInfo.operatingSystemVersionString
                $0.agentVersion = Self.embeddedAgentVersion
            }
        }

        do {
            try channel.send(hello)
        } catch {
            Self.logger.warning("Failed to send Hello: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static let embeddedAgentVersion: String = {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return "unknown"
        }
        return version
    }()
}
