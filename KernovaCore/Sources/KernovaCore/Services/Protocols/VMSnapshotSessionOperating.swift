import Foundation

/// The VZ operations a save path or a restore drives on one live session — a
/// suspend, a snapshot capture, and the restore of a saved state alike.
///
/// `pauseIfRunning`/`resumeIfPaused` answer VZ's own `state`, which carries no
/// record of who paused the guest: a guest the user paused before asking for a
/// snapshot is as resumable as one the capture paused itself.
///
/// What has the guest execute takes a ``VMGuestExecution``, so no path resumes
/// a guest whose session is not marked unsettled.
package protocol VMSnapshotSessionOperating: Sendable {
    func pauseIfRunning() async throws
    func resumeIfPaused(_ execution: borrowing VMGuestExecution) async throws
    /// Writes the guest's state into `url`. Only ``VMLiveStateCapture`` holds
    /// a ``VMLiveStateCapture/SaveGrant``, so every save is one of its entry
    /// points, which unplug every hot-pluggable USB device first.
    func saveMachineState(to url: URL, _ grant: VMLiveStateCapture.SaveGrant) async throws
    func restoreMachineState(from url: URL) async throws
    func resume(_ execution: borrowing VMGuestExecution) async throws
    /// The `uuid` of every device on the USB controller, in its order; none
    /// for a session with no USB controller.
    func usbDeviceIDs() async throws -> [UUID]
    /// Detaches the USB device carrying `uuid`, throwing
    /// ``VMSessionError/usbDeviceNotFound`` when the controller holds none.
    func detachUSBDevice(uuid: UUID) async throws
}
