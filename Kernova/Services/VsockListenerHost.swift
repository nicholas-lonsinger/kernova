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

        applySendTimeout(fd)

        let channel = VsockChannel(fileDescriptor: fd)
        channel.start()
        Self.logger.notice("Accepted vsock connection on port \(self.port, privacy: .public)")
        onConnect(channel)
        return true
    }

    /// Bounds a host write to a stalled guest defensively.
    ///
    /// RATIONALE: the host previously built the channel from the duped fd with no
    /// send timeout, so a guest that stops draining could hang a `writeFramed`
    /// forever. Correcting an earlier version of this rationale: the streaming
    /// credit window (1–2 MiB, `ClipboardStreamTuning`) does **not** bound a
    /// `writeFramed` call to the socket send buffer (~512 KiB XNU default) — the
    /// window is deliberately larger than the buffer, so a `write(2)` can still
    /// block. What actually keeps a blocked write from wedging the channel is
    /// `VsockChannel`'s split write/state lock (#457): a stalled peer's blocked
    /// write holds only the write lock, never the lock inbound decode needs, so
    /// acks and control frames keep flowing and the streaming engine's own
    /// no-ack (sender) / inbound-stall (receiver) deadlines can still fire and
    /// tear the channel down — which `shutdown(2)`s the fd first, unblocking the
    /// parked write. `SO_SNDTIMEO` is a belt-and-suspenders backstop on top of
    /// that; Apple does not document whether it is honoured on a vsock fd (it
    /// may be a no-op). The `setsockopt` return is checked and logged so an
    /// ineffective option is visible; if it proves ineffective in practice the
    /// streaming write path can move to a non-blocking fd + `poll(POLLOUT)`
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
}
