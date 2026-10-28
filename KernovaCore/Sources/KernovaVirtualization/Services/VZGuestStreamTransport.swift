import Foundation
import KernovaAgentHost
import KernovaAgentRuntime
import KernovaCore
import KernovaLogging
import KernovaPlatformPOSIX
import KernovaWire
import Virtualization

/// The agent hub's transport on one session's socket device: a listener on
/// `WireConstants.vsockPort`, beside v1's ports, offering every connection to
/// the hub's ``GuestStreamAcceptor``.
///
/// Binding and unbinding run on the session's queue, as every VZ call does.
final class VZGuestStreamTransport: GuestStreamTransport {
    private let session: VMSession

    init(session: VMSession) {
        self.session = session
    }

    func start(admitting acceptor: GuestStreamAcceptor) {
        let session = session
        session.queue.async {
            session.assumeIsolated { $0.bindAgentListener(AgentListenerHost(acceptor: acceptor)) }
        }
    }

    func stop() {
        let session = session
        session.queue.async {
            session.assumeIsolated { $0.detach(ports: [WireConstants.vsockPort]) }
        }
    }
}

/// The `VZVirtioSocketListener` delegate on the agent port, which the session
/// retains while it is bound.
///
/// Each accepted connection becomes a non-blocking `POSIXByteStream` over a
/// duplicate of its descriptor; the `VZVirtioSocketConnection` itself is not
/// kept, and closes its own descriptor when VZ releases it.
final class AgentListenerHost: NSObject, VsockPortListening, VZVirtioSocketListenerDelegate {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VZGuestStreamTransport")

    let port = WireConstants.vsockPort
    private let acceptor: GuestStreamAcceptor
    private let socketListener = VZVirtioSocketListener()

    init(acceptor: GuestStreamAcceptor) {
        self.acceptor = acceptor
        super.init()
        socketListener.delegate = self
    }

    func attach(to socketDevice: VZVirtioSocketDevice) {
        socketDevice.setSocketListener(socketListener, forPort: port)
        Self.logger.log(.notice, "Agent transport listening on vsock port \(self.port, privacy: .public)")
    }

    func detach(from socketDevice: VZVirtioSocketDevice) {
        socketDevice.removeSocketListener(forPort: port)
        Self.logger.log(.notice, "Agent transport stopped listening on vsock port \(self.port, privacy: .public)")
    }

    // On the VM's queue. The acceptor decides before the connection is
    // touched, so a refused one is never read (spec §9.7.1), and logs its
    // refusals.
    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let descriptor = connection.fileDescriptor
        let port = port
        return acceptor.offer { released in
            let duplicate = AcceptedVsockSocket.duplicate(descriptor)
            guard duplicate.fd >= 0 else {
                Self.logger.log(
                    .error,
                    "dup() failed for an agent connection on vsock port \(port, privacy: .public): errno=\(duplicate.errno, privacy: .public)"
                )
                return nil
            }
            AcceptedVsockSocket.raiseSendBuffer(duplicate.fd, port: port)
            do {
                return try POSIXByteStream(adopting: duplicate.fd, released: released)
            } catch {
                Self.logger.log(
                    .error,
                    "Could not adopt an agent connection on vsock port \(port, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                close(duplicate.fd)
                return nil
            }
        }
    }
}
