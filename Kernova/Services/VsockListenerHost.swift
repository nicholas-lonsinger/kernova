import Foundation
import KernovaKit
import os
import Virtualization

/// Hosts a single `VZVirtioSocketListener` on a given vsock port and hands
/// each accepted connection to a callback as a `VsockChannel`.
///
/// One instance handles one port; pair multiple instances with one
/// `VZVirtioSocketDevice` to run several services side-by-side (e.g. logging
/// and clipboard on different ports).
@MainActor
final class VsockListenerHost: NSObject, VZVirtioSocketListenerDelegate {
    typealias OnConnect = @MainActor (VsockChannel) -> Void

    private static let logger = Logger(subsystem: "app.kernova", category: "VsockListenerHost")

    let port: UInt32
    private let onConnect: OnConnect
    private let listener: VZVirtioSocketListener

    init(port: UInt32, onConnect: @escaping OnConnect) {
        self.port = port
        self.onConnect = onConnect
        self.listener = VZVirtioSocketListener()
        super.init()
        self.listener.delegate = self
    }

    /// Installs this listener on the supplied socket device.
    ///
    /// Connections to
    /// `port` from the guest will subsequently invoke `onConnect`.
    func attach(to socketDevice: VZVirtioSocketDevice) {
        socketDevice.setSocketListener(listener, forPort: port)
        Self.logger.info("Listening on vsock port \(self.port, privacy: .public)")
    }

    // MARK: - VZVirtioSocketListenerDelegate

    // RATIONALE: Virtualization framework delegates are nonisolated; matching
    // VMDelegateAdapter's pattern, we bridge back to MainActor with
    // `assumeIsolated` since the VZ delegate callbacks for a VM created on
    // the main queue are also delivered on the main queue.
    //
    // We resolve the fd (and capture errno on failure) in this nonisolated
    // method so we never carry the non-Sendable `VZVirtioSocketConnection`
    // across the actor boundary.
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

    private func acceptDuplicatedFd(_ fd: Int32, dupErrno: Int32) -> Bool {
        // RATIONALE: dup() above gives us a fully independent fd referencing
        // the same socket file description. The framework can release its
        // own copy without affecting ours — `VsockChannel`/`FileHandle`
        // owns and closes the duplicate.
        guard fd >= 0 else {
            Self.logger.error(
                "dup() failed for accepted vsock connection on port \(self.port, privacy: .public): errno=\(dupErrno, privacy: .public)"
            )
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
    ///
    /// `internal` (not `private`) purely as a test seam: the accept path's fd
    /// otherwise originates from a live `VZVirtioSocketConnection`, so a unit test
    /// has no way to observe the applied options without driving this against an
    /// injected `socketpair` fd.
    func configureAcceptedSocket(_ fd: Int32) {
        applySendBuffer(fd)
        applySendTimeout(fd)
    }

    /// Enlarges the socket send buffer to unlock host→guest streaming throughput.
    ///
    /// RATIONALE: a `VZVirtioSocketConnection`'s host-side fd is a plain AF_UNIX
    /// socket born at XNU's 8 KiB `net.local.stream.sendspace` default, and vsock
    /// throughput is gated by the *writer's* send buffer. At 8 KiB the host writer
    /// ping-pongs with the VM helper process every 8 KiB, capping the raw
    /// host→guest transport at ~0.7 GiB/s; raising `SO_SNDBUF` to 1 MiB lifts that
    /// ceiling ~9× (measured knee at 256 KiB), after which the app stack is the
    /// only host→guest limiter (#377). 64 KiB writes stay optimal, so the chunk
    /// and credit-window sizes are untouched. Host-only: the guest→host writer
    /// lives in Apple's `com.apple.Virtualization.VirtualMachine` helper process
    /// and is unreachable per-fd, so that direction stays capped ~750 MiB/s. The
    /// `setsockopt` return is checked and the applied value read back; a clamp
    /// below the requested size is logged at `.warning` (persisted) so a lever
    /// that silently failed to engage is diagnosable post-mortem.
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
    /// RATIONALE: the host previously built the channel from the duped fd with no
    /// send timeout, so a guest that stops draining could hang a `writeFramed`
    /// forever. The socket send buffer is 1 MiB (`applySendBuffer`, raised from
    /// XNU's 8 KiB `net.local.stream.sendspace` default) while the streaming credit
    /// window (`ClipboardStreamTuning`) ranges 1–2 MiB, so at the 2 MiB ceiling a
    /// `writeFramed` `write(2)` can still block. What actually keeps a blocked
    /// write from wedging the channel is `VsockChannel`'s split write/state lock
    /// (#457): a stalled peer's blocked write holds only the write lock, never the
    /// lock inbound decode needs, so acks and control frames keep flowing and the
    /// streaming engine's own no-ack (sender) / inbound-stall (receiver) deadlines
    /// can still fire and tear the channel down — which `shutdown(2)`s the fd
    /// first, unblocking the parked write. `SO_SNDTIMEO` is a belt-and-suspenders
    /// backstop on top of that; Apple does not document whether it is honoured on a
    /// vsock fd (it may be a no-op). The `setsockopt` return is checked and logged
    /// so an ineffective option is visible; if it proves ineffective in practice
    /// the streaming write path can move to a non-blocking fd + `poll(POLLOUT)`
    /// (vsock(4)'s canonical approach).
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

    /// Host-side socket send-buffer size.
    ///
    /// XNU births the `VZVirtioSocketConnection` fd at an 8 KiB
    /// `net.local.stream.sendspace` default; 1 MiB lifts the host→guest transport
    /// ceiling ~9× (knee measured at 256 KiB) and stays well under
    /// `kern.ipc.maxsockbuf` (8 MiB). See `applySendBuffer` (#377).
    private static let sendBufferBytes = 1 << 20
}
