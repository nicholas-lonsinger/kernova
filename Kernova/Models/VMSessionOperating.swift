import Foundation

// MARK: - Session Events

/// A lifecycle event VZ delivered on a session's queue.
enum VMSessionEvent: Sendable {
    case guestDidStop
    case didStopWithError(any Error)
    case networkAttachmentDisconnected(any Error)
    /// A passthrough accessory's host device went away. VZ has already detached
    /// it, so the receiver only drops its own record of the attachment.
    case usbPassthroughDeviceDidDisconnect(UUID)
}

/// The sink a session delivers its events into.
///
/// Called on the session's queue with the session's `id`, so the receiver can
/// hop to the main actor and drop events from a session it no longer holds.
struct VMSessionEvents: Sendable {
    let handle: @Sendable (UUID, VMSessionEvent) -> Void
}

// MARK: - Session Errors

/// Failures a session's device operations report; the calling service maps
/// them onto its user-facing error type.
enum VMSessionError: Error {
    case usbControllerUnavailable
    case usbDeviceNotFound
}

// MARK: - Session

/// One VM's live session, as the code that holds it drives it — every
/// operation whose arguments are Kernova values.
///
/// The engine makes each session and hands it to ``VMActivity`` to hold; an
/// operation whose arguments are Virtualization objects is the engine's own,
/// on the concrete session.
protocol VMSessionOperating: AnyObject, VMSnapshotSessionOperating, VsockListenerInstalling {
    /// Session identity, carried by every delivered event so the owner can
    /// drop events from a session it has already replaced.
    var id: UUID { get }

    // Configuration facts snapshotted at creation, so main-actor guards on
    // device presence stay synchronous.
    var hasVirtioSocketDevice: Bool { get }
    var hasNetworkDevice: Bool { get }
    var hasUSBController: Bool { get }

    /// Forcefully terminates the VM.
    func stop() async throws

    /// Requests a graceful ACPI shutdown.
    func requestStop() async throws

    func pause() async throws

    /// Unbinds every vsock listener this session still has bound, ordered
    /// fire-and-forget on the session's queue.
    func detachRemainingListeners()

    /// Sets the share the VM's macOS automount device carries to `share`, then
    /// runs `installed` on the session's queue, once the device no longer
    /// carries what it did before.
    func applyDirectoryShare(_ share: MacOSDirectoryShare, installed: @escaping @Sendable () -> Void)
}
