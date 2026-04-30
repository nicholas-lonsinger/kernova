import Foundation
import KernovaProtocol
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

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VsockListenerHost")

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

    /// Installs this listener on the supplied socket device. Connections to
    /// `port` from the guest will subsequently invoke `onConnect`.
    func attach(to socketDevice: VZVirtioSocketDevice) {
        socketDevice.setSocketListener(listener, forPort: port)
        Self.logger.info("Listening on vsock port \(self.port, privacy: .public)")
    }

    /// Removes the listener from the socket device. Safe to call after the VM
    /// has stopped — the device may already have torn down its listener map.
    func detach(from socketDevice: VZVirtioSocketDevice) {
        socketDevice.removeSocketListener(forPort: port)
        Self.logger.debug("Detached vsock listener for port \(self.port, privacy: .public)")
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

        let channel = VsockChannel(fileDescriptor: fd)
        channel.start()
        Self.logger.notice("Accepted vsock connection on port \(self.port, privacy: .public)")
        onConnect(channel)
        return true
    }
}
