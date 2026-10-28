import Foundation
import KernovaKit
import KernovaLogging

/// The host's first steps on a vsock connection the guest opened, for every
/// listener: v1's ports and the agent hub's.
package enum AcceptedVsockSocket {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AcceptedVsockSocket")

    /// A close-on-exec duplicate of an accepted connection's `descriptor`, and
    /// the `errno` a failed `dup` left (`fd` is then negative).
    ///
    /// `VZVirtioSocketConnection` owns its descriptor and closes it once it is
    /// released, so whatever keeps the connection holds a duplicate: an
    /// independent descriptor on the same socket.
    package static func duplicate(_ descriptor: Int32) -> (fd: Int32, errno: Int32) {
        let fd = dup(descriptor)
        guard fd >= 0 else { return (fd, errno) }
        let flags = fcntl(fd, F_GETFD)
        if flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) != 0 {
            logger.log(
                .warning,
                "Could not mark an accepted vsock descriptor close-on-exec: errno=\(errno, privacy: .public)")
        }
        return (fd, 0)
    }

    /// Enlarges `fd`'s send buffer to unlock host→guest streaming throughput,
    /// logging what the kernel applied.
    ///
    /// Throughput is gated by the *writer's* send buffer, and an accepted fd
    /// is born at XNU's 8 KiB `net.local.stream.sendspace` default — the host
    /// writer then ping-pongs with the VM helper process every 8 KiB, capping
    /// host→guest at ~0.7 GiB/s. 1 MiB lifts that ~9×, with the knee at
    /// 256 KiB (`docs/research/2026-07-13-vsock-transport-throughput.md`). The
    /// guest→host writer lives in Apple's VM helper process, unreachable
    /// per-fd.
    package static func raiseSendBuffer(_ fd: Int32, port: UInt32) {
        var size = Int32(sendBufferBytes)
        guard setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            logger.log(
                .warning,
                "setsockopt(SO_SNDBUF) failed on vsock port \(port, privacy: .public): errno=\(errno, privacy: .public) — host→guest throughput stays at the 8 KiB-default transport ceiling"
            )
            return
        }
        var applied: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_SNDBUF, &applied, &length) == 0 else { return }
        if applied < Int32(sendBufferBytes) {
            logger.log(
                .warning,
                "SO_SNDBUF on vsock port \(port, privacy: .public) clamped to \(applied, privacy: .public) bytes (requested \(sendBufferBytes, privacy: .public)) — host→guest throughput may stay below the unlocked ceiling"
            )
        } else {
            logger.log(
                .debug,
                "SO_SNDBUF on vsock port \(port, privacy: .public) set to \(applied, privacy: .public) bytes")
        }
    }

    /// Host-side socket send-buffer size, well under `kern.ipc.maxsockbuf`
    /// (8 MiB) — see ``raiseSendBuffer(_:port:)`` for why it is raised at all.
    private static let sendBufferBytes = ClipboardStreamTuning.dataSendBufferBytes
}
