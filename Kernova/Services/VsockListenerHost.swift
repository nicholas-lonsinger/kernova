import Foundation
import KernovaLogging
import Virtualization

/// Hosts one ``VsockListener`` as a `VZVirtioSocketListener`, handing each
/// accepted connection to it.
///
/// One instance handles one port; pair several with one `VZVirtioSocketDevice`
/// to run multiple services side-by-side.
///
/// `@unchecked Sendable`: every stored property is `let`, and the non-Sendable
/// `VZVirtioSocketListener` is touched only at `init` and `attach(to:)`.
final class VsockListenerHost: NSObject, VZVirtioSocketListenerDelegate, @unchecked Sendable {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VsockListenerHost")

    let listener: VsockListener

    private let socketListener: VZVirtioSocketListener

    var port: UInt32 { listener.port }

    init(_ listener: VsockListener) {
        self.listener = listener
        self.socketListener = VZVirtioSocketListener()
        super.init()
        self.socketListener.delegate = self
    }

    /// Installs this listener on the supplied socket device.
    func attach(to socketDevice: VZVirtioSocketDevice) {
        socketDevice.setSocketListener(socketListener, forPort: port)
        #log(Self.logger, .info, "Listening on vsock port \(self.port, privacy: .public)")
    }

    /// Removes this listener from the supplied socket device.
    ///
    /// VZ unbinds by port and offers no way to name the listener bound there,
    /// so this removes whatever occupies this host's port.
    func detach(from socketDevice: VZVirtioSocketDevice) {
        socketDevice.removeSocketListener(forPort: port)
        #log(Self.logger, .info, "Stopped listening on vsock port \(self.port, privacy: .public)")
    }

    // MARK: - VZVirtioSocketListenerDelegate

    // Resolve the fd (and capture errno) here, in the delegate method, so the
    // non-Sendable `VZVirtioSocketConnection` never leaves it.
    func listener(
        _ listener: VZVirtioSocketListener,
        shouldAcceptNewConnection connection: VZVirtioSocketConnection,
        from socketDevice: VZVirtioSocketDevice
    ) -> Bool {
        let dupedFd = dup(connection.fileDescriptor)
        let dupErrno: Int32 = dupedFd < 0 ? errno : 0
        return self.listener.acceptDuplicatedFd(dupedFd, dupErrno: dupErrno)
    }
}
