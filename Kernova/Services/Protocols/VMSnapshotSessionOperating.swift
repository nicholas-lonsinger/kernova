import Foundation

/// The VZ operations a save path or a restore drives on one live session — a
/// suspend, a snapshot capture, and the restore of a saved state alike.
///
/// `pauseIfRunning`/`resumeIfPaused` answer VZ's own `state`, which carries no
/// record of who paused the guest: a guest the user paused before asking for a
/// snapshot is as resumable as one the capture paused itself.
protocol VMSnapshotSessionOperating: Sendable {
    func pauseIfRunning() async throws
    func resumeIfPaused() async throws
    func saveMachineState(to url: URL) async throws
    func restoreMachineState(from url: URL) async throws
    func resume() async throws
    /// The `uuid` of every device on the USB controller, empty when the
    /// machine has none.
    func usbDeviceIDs() async -> Set<UUID>
}

extension VMSession: VMSnapshotSessionOperating {}
