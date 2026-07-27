import Foundation
import KernovaKit
import os
import Virtualization

/// Hosts a single `VZVirtioSocketListener` on a given vsock port and hands
/// each accepted connection to a callback as a `VsockChannel`.
///
/// One instance handles one port; pair several with one `VZVirtioSocketDevice`
/// to run multiple services side-by-side.
@MainActor
final class VsockListenerHost: NSObject, VZVirtioSocketListenerDelegate {
    typealias OnConnect = @MainActor (VsockChannel) -> Void

    /// Owner-supplied admission predicate, evaluated per accepted connection.
    ///
    /// Returning `false` refuses the connection at the VZ level — no channel is
    /// built and `onConnect` never fires. `nil` admits every connection.
    typealias ShouldAdmit = @MainActor () -> Bool

    private static let logger = Logger(subsystem: "app.kernova", category: "VsockListenerHost")

    let port: UInt32
    private let shouldAdmit: ShouldAdmit?
    private let onConnect: OnConnect

    private let listener: VZVirtioSocketListener

    init(port: UInt32, shouldAdmit: ShouldAdmit? = nil, onConnect: @escaping OnConnect) {
        self.port = port
        self.shouldAdmit = shouldAdmit
        self.onConnect = onConnect
        self.listener = VZVirtioSocketListener()
        super.init()
        self.listener.delegate = self
    }

    /// Installs this listener on the supplied socket device.
    func attach(to socketDevice: VZVirtioSocketDevice) {
        socketDevice.setSocketListener(listener, forPort: port)
        Self.logger.info("Listening on vsock port \(self.port, privacy: .public)")
    }

    // MARK: - VZVirtioSocketListenerDelegate

    // VZ delegate callbacks for a VM created on the main queue are delivered on
    // the main queue, so `assumeIsolated` bridges back. Resolve the fd (and
    // capture errno) here, in the nonisolated method, so the non-Sendable
    // `VZVirtioSocketConnection` never crosses the actor boundary.
    nonisolated func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let dupedFd = dup(connection.fileDescriptor)
        let dupErrno: Int32 = dupedFd < 0 ? errno : 0
        return MainActor.assumeIsolated {
            self.acceptDuplicatedFd(dupedFd, dupErrno: dupErrno)
        }
    }

    /// Resolves one accepted connection: admission check, socket configuration,
    /// channel construction, `onConnect`.
    ///
    /// Takes ownership of `fd` on every path — the built channel closes it, or
    /// a refusal closes it here.
    func acceptDuplicatedFd(_ fd: Int32, dupErrno: Int32) -> Bool {
        // The dup() above is a fully independent fd on the same socket file
        // description: the framework can release its own copy without affecting
        // ours, and `VsockChannel`/`FileHandle` owns and closes the duplicate.
        guard fd >= 0 else {
            Self.logger.error(
                "dup() failed for accepted vsock connection on port \(self.port, privacy: .public): errno=\(dupErrno, privacy: .public)"
            )
            return false
        }

        // Refusing here — before any channel exists — means the peer sees the
        // connection reset; a conformant guest agent's reconnect loop retries,
        // by which time the control handshake has normally landed.
        if let shouldAdmit, !shouldAdmit() {
            Self.logger.warning(
                "Refusing vsock connection on port \(self.port, privacy: .public) — admission check failed"
            )
            close(fd)
            return false
        }

        configureAcceptedSocket(fd)

        let channel = VsockChannel(fileDescriptor: fd)
        channel.start()
        Self.logger.notice("Accepted vsock connection on port \(self.port, privacy: .public)")
        onConnect(channel)
        return true
    }

    /// Applies the host-side socket options to a freshly accepted vsock fd.
    func configureAcceptedSocket(_ fd: Int32) {
        applySendBuffer(fd)
        applySendTimeout(fd)
    }

    /// Enlarges the socket send buffer to unlock host→guest streaming throughput.
    ///
    /// RATIONALE: throughput is gated by the *writer's* send buffer, and this fd
    /// is born at XNU's 8 KiB `net.local.stream.sendspace` default — the host
    /// writer then ping-pongs with the VM helper process every 8 KiB, capping
    /// host→guest at ~0.7 GiB/s. 1 MiB lifts that ~9×, with the knee at 256 KiB —
    /// measured 2026-07-13 on an M1 Max, see
    /// `docs/research/2026-07-13-vsock-transport-throughput.md`. Host-only: the
    /// guest→host writer lives in Apple's VM helper process, unreachable per-fd.
    private func applySendBuffer(_ fd: Int32) {
        var size = Int32(Self.sendBufferBytes)
        let rc = setsockopt(
            fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        if rc != 0 {
            Self.logger.warning(
                "setsockopt(SO_SNDBUF) failed on vsock port \(self.port, privacy: .public): errno=\(errno, privacy: .public) — host→guest throughput stays at the 8 KiB-default transport ceiling"
            )
            return
        }
        var applied: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &applied, &len) == 0 else { return }
        if applied < Int32(Self.sendBufferBytes) {
            Self.logger.warning(
                "SO_SNDBUF on vsock port \(self.port, privacy: .public) clamped to \(applied, privacy: .public) bytes (requested \(Self.sendBufferBytes, privacy: .public)) — host→guest throughput may stay below the unlocked ceiling"
            )
        } else {
            Self.logger.debug(
                "SO_SNDBUF on vsock port \(self.port, privacy: .public) set to \(applied, privacy: .public) bytes"
            )
        }
    }

    /// Bounds a host write to a stalled guest defensively.
    ///
    /// Apple does not document whether `SO_SNDTIMEO` is honoured on a vsock fd,
    /// so treat this as a backstop, not as the mechanism that unwedges a write
    /// to a stalled guest — that is `VsockChannel`'s split write/state lock,
    /// which keeps acks flowing so the streaming deadlines can tear the channel
    /// down and unblock the parked write.
    private func applySendTimeout(_ fd: Int32) {
        var timeout = timeval(tv_sec: Self.sendTimeoutSeconds, tv_usec: 0)
        let rc = setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if rc != 0 {
            Self.logger.warning(
                "setsockopt(SO_SNDTIMEO) failed on vsock port \(self.port, privacy: .public): errno=\(errno, privacy: .public) — relying on the streaming credit window for write bounding"
            )
        }
    }

    /// Defensive host-side send timeout, matching the guest's socket timeout.
    private static let sendTimeoutSeconds = 30

    /// Host-side socket send-buffer size, well under `kern.ipc.maxsockbuf`
    /// (8 MiB) — see `applySendBuffer` for why it is raised at all.
    private static let sendBufferBytes = 1 << 20
}
