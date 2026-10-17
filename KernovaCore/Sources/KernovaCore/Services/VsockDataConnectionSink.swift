import Foundation
import KernovaKit
import Synchronization

/// Takes ownership of one accepted data-connection descriptor, from whatever
/// thread the listener hands it over on.
protocol VsockDataConnectionAccepting: AnyObject, Sendable {
    nonisolated func acceptDataConnection(fd: Int32)
}

/// Routes one data port's accepted connections to whichever service currently
/// owns them, without touching the main actor.
///
/// Owned by `VMInstance`, one per data port across every service generation.
/// The owner points it at each service it creates on the main actor; the
/// listener's `onAcceptFd` forwards through it from the VM's queue.
final class VsockDataConnectionSink: Sendable {
    private let current = Mutex<(any VsockDataConnectionAccepting)?>(nil)

    /// Points the sink at `service`, or at nothing — the owning service was
    /// created, replaced, or stopped.
    func set(_ service: (any VsockDataConnectionAccepting)?) {
        current.withLock { $0 = service }
    }

    /// Forwards one accepted descriptor to the current service, taking
    /// ownership of `fd` on every path.
    ///
    /// With no service set, the connection beat the feature channel's own
    /// accept and has nothing to belong to; the peer redials with its next
    /// pull.
    func accept(fd: Int32) {
        guard let service = current.withLock({ $0 }) else {
            ClipboardDataConnection.end(fd: fd)
            return
        }
        service.acceptDataConnection(fd: fd)
    }
}
