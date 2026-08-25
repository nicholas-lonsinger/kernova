import Foundation

/// The VZ operations a snapshot capture drives on one live session.
///
/// `pauseIfRunning`/`resumeIfPaused` answer VZ's own `state`, which carries no
/// record of who paused the guest: a guest the user paused before asking for a
/// snapshot is as resumable as one the capture paused itself.
protocol VMSnapshotSessionOperating: Sendable {
    func pauseIfRunning() async throws
    func resumeIfPaused() async throws
    func saveMachineState(to url: URL) async throws
}

extension VMSession: VMSnapshotSessionOperating {}
