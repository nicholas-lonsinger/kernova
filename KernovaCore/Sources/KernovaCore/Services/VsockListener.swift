import Foundation
import KernovaKit
import KernovaLogging

/// A listener owner's verdict on one accepted connection.
///
/// The two refusals differ only in what they say about the peer, which is what
/// picks the log level: a channel that arrived before the handshake gating it
/// is the guest agent's own reconnect racing that handshake, while one refused
/// after it is a peer that should not have connected.
enum VsockAdmission: Equatable, Sendable {
    case admit
    /// The handshake this port is gated on has not completed yet.
    case notReady(reason: String)
    /// The handshake completed and it does not entitle this peer to this port.
    case denied(reason: String)
}

/// One vsock port's listener as its owner specifies it: the port, who it
/// admits, and what an accepted connection is handed over as.
///
/// A control port's connections arrive as a framed `VsockChannel`; a data port's
/// arrive as the raw descriptor, because one transfer's connection carries its
/// own header, payload and trailer rather than a stream of frames.
///
/// The accept path runs entirely on whatever queue the platform delivers the
/// connection on: the admission check and a data port's hand-off are
/// synchronous there, and only a framed port's `onConnect` hops to the main
/// actor.
package struct VsockListener: Sendable {
    typealias OnConnect = @MainActor (VsockChannel) -> Void

    /// Takes ownership of one accepted descriptor, unwrapped, synchronously on
    /// the accepting thread.
    typealias OnAcceptFd = @Sendable (Int32) -> Void

    /// What an accepted connection is handed over as.
    private enum Handoff: Sendable {
        case channel(OnConnect)
        case rawDescriptor(OnAcceptFd)
    }

    /// Owner-supplied admission predicate, evaluated per accepted connection on
    /// the accepting thread.
    ///
    /// Anything but `.admit` refuses the connection — no channel is built and
    /// `onConnect` never fires. `nil` admits every connection.
    typealias ShouldAdmit = @Sendable () -> VsockAdmission

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VsockListener")

    package let port: UInt32
    private let shouldAdmit: ShouldAdmit?
    private let handoff: Handoff

    /// Serves a port whose connections are framed channels.
    init(port: UInt32, shouldAdmit: ShouldAdmit? = nil, onConnect: @escaping OnConnect) {
        self.port = port
        self.shouldAdmit = shouldAdmit
        self.handoff = .channel(onConnect)
    }

    /// Serves a data port, whose connections are handed over as raw
    /// descriptors.
    ///
    /// `onAcceptFd` takes ownership of the descriptor: the endpoint applies the
    /// data connection's own socket options and reads its header off the main
    /// actor.
    init(port: UInt32, shouldAdmit: ShouldAdmit? = nil, onAcceptFd: @escaping OnAcceptFd) {
        self.port = port
        self.shouldAdmit = shouldAdmit
        self.handoff = .rawDescriptor(onAcceptFd)
    }

    /// Resolves one accepted connection on the accepting thread: admission
    /// check, socket configuration, channel construction or raw hand-off.
    ///
    /// `fd` is a `dup()` of the accepted connection's descriptor — a fully
    /// independent fd on the same socket file description, so the framework
    /// can release its own copy without affecting this one — and `dupErrno`
    /// the `errno` a failed `dup()` left.
    ///
    /// Takes ownership of `fd` on every path — the built channel closes it, a
    /// data port's `onAcceptFd` takes it over, or a refusal closes it here.
    /// Nothing on this path reads main-actor state or waits on a main-queue
    /// hop: a framed port's `onConnect` is queued and not awaited, and a data
    /// port's `onAcceptFd` runs synchronously right here.
    package func acceptDuplicatedFd(_ fd: Int32, dupErrno: Int32) -> Bool {
        guard fd >= 0 else {
            Self.logger.log(
                .error,
                "dup() failed for accepted vsock connection on port \(self.port, privacy: .public): errno=\(dupErrno, privacy: .public)"
            )
            return false
        }

        // Refusing here — before any channel exists — means the peer sees the
        // connection reset; a conformant guest agent's reconnect loop retries,
        // and the policy update that follows the handshake wakes it to do so at
        // once (`VsockGuestClient.resume()`).
        switch shouldAdmit?() ?? .admit {
        case .admit:
            break
        case .notReady(let reason):
            Self.logger.log(
                .info,
                "Refusing vsock connection on port \(self.port, privacy: .public) — \(reason, privacy: .public)"
            )
            close(fd)
            return false
        case .denied(let reason):
            Self.logger.log(
                .warning,
                "Refusing vsock connection on port \(self.port, privacy: .public) — \(reason, privacy: .public)"
            )
            close(fd)
            return false
        }

        switch handoff {
        case .channel(let onConnect):
            configureAcceptedSocket(fd)
            let channel = VsockChannel(fileDescriptor: fd)
            channel.start()
            Self.logger.log(
                .notice,
                "Accepted vsock connection on port \(self.port, privacy: .public)")
            // Only the hand-off hops: the channel is already draining, and the
            // async bridge keeps FIFO order with the reporter emissions queued
            // the same way.
            MainActorBridge.async { onConnect(channel) }
        case .rawDescriptor(let onAcceptFd):
            // No `configureAcceptedSocket` here: a data connection's options are
            // the endpoint's, applied where the first read on the descriptor
            // happens rather than in two places that must stay in step.
            Self.logger.log(
                .debug,
                "Accepted vsock data connection on port \(self.port, privacy: .public)")
            onAcceptFd(fd)
        }
        return true
    }

    /// Applies the host-side socket options to a freshly accepted vsock fd.
    func configureAcceptedSocket(_ fd: Int32) {
        applySendBuffer(fd)
        applySendTimeout(fd)
    }

    /// Enlarges the socket send buffer to unlock host→guest streaming throughput.
    ///
    /// Throughput is gated by the *writer's* send buffer, and this fd is born at
    /// XNU's 8 KiB `net.local.stream.sendspace` default — the host writer then
    /// ping-pongs with the VM helper process every 8 KiB, capping host→guest at
    /// ~0.7 GiB/s. 1 MiB lifts that ~9×, with the knee at 256 KiB
    /// (`docs/research/2026-07-13-vsock-transport-throughput.md`). The guest→host
    /// writer lives in Apple's VM helper process, unreachable per-fd.
    private func applySendBuffer(_ fd: Int32) {
        var size = Int32(Self.sendBufferBytes)
        let rc = setsockopt(
            fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        if rc != 0 {
            Self.logger.log(
                .warning,
                "setsockopt(SO_SNDBUF) failed on vsock port \(self.port, privacy: .public): errno=\(errno, privacy: .public) — host→guest throughput stays at the 8 KiB-default transport ceiling"
            )
            return
        }
        var applied: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &applied, &len) == 0 else { return }
        if applied < Int32(Self.sendBufferBytes) {
            Self.logger.log(
                .warning,
                "SO_SNDBUF on vsock port \(self.port, privacy: .public) clamped to \(applied, privacy: .public) bytes (requested \(Self.sendBufferBytes, privacy: .public)) — host→guest throughput may stay below the unlocked ceiling"
            )
        } else {
            Self.logger.log(
                .debug,
                "SO_SNDBUF on vsock port \(self.port, privacy: .public) set to \(applied, privacy: .public) bytes"
            )
        }
    }

    /// Bounds a host write to a stalled guest defensively.
    ///
    /// Apple does not document whether `SO_SNDTIMEO` is honoured on a vsock fd,
    /// so treat this as a backstop, not as the mechanism that unwedges a write
    /// to a stalled guest — that is `VsockChannel`'s split write/state lock,
    /// which keeps the channel readable so a teardown can unblock the parked
    /// write.
    private func applySendTimeout(_ fd: Int32) {
        var timeout = timeval(tv_sec: Self.sendTimeoutSeconds, tv_usec: 0)
        let rc = setsockopt(
            fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        if rc != 0 {
            Self.logger.log(
                .warning,
                "setsockopt(SO_SNDTIMEO) failed on vsock port \(self.port, privacy: .public): errno=\(errno, privacy: .public) — a write to a stalled guest is bounded only by the channel's own teardown"
            )
        }
    }

    /// Defensive host-side send timeout, matching the guest's socket timeout.
    private static let sendTimeoutSeconds = Int(ClipboardStreamTuning.dataSocketTimeout)

    /// Host-side socket send-buffer size, well under `kern.ipc.maxsockbuf`
    /// (8 MiB) — see `applySendBuffer` for why it is raised at all.
    private static let sendBufferBytes = ClipboardStreamTuning.dataSendBufferBytes
}

/// The queue-side install of a VM's vsock listeners, as the main actor drives
/// it.
package protocol VsockListenerInstalling: Sendable {
    func attach(_ listeners: [VsockListener]) async
    func detach(ports: [UInt32]) async
}
