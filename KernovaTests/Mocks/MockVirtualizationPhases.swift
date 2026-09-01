import Foundation
@testable import Kernova

/// Phase bookkeeping both `VirtualizationProviding` mocks share, so a capture
/// mock cannot drift from production's own capture-mode source of truth.
@MainActor
enum MockVirtualizationPhases {
    /// The identity a phase this mock installs names — the live one when the
    /// instance already holds a session, and a fresh one otherwise, since a CI
    /// host can mint no real `VZVirtualMachine`.
    static func sessionIdentity(for instance: VMInstance) -> UUID {
        instance.liveSessionID ?? UUID()
    }

    /// The phase to move `instance` into for the capture itself, and the phase
    /// to rest it at afterward, derived from `instance.snapshotCaptureMode` —
    /// production's own source of truth — read before either phase is
    /// written, since a capture phase changes the answer.
    static func capturePhases(
        for instance: VMInstance
    ) throws -> (capturing: VMLifecyclePhase, resting: VMLifecyclePhase) {
        guard let mode = instance.snapshotCaptureMode else {
            throw VirtualizationError.invalidStateTransition(
                from: instance.status, action: "take a snapshot of")
        }
        switch mode {
        case .live:
            let id = sessionIdentity(for: instance)
            let resting: VMLifecyclePhase =
                instance.phase == .running(sessionID: id)
                ? .running(sessionID: id) : .livePaused(sessionID: id)
            return (.capturingLive(sessionID: id), resting)
        case .suspended:
            return (.capturingAtRest, .suspended)
        case .stopped:
            return (.capturingAtRest, .stopped)
        }
    }
}
