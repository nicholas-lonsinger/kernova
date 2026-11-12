import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The projections every surface reads off a phase, over every fixture phase.
///
/// Admission's own reading of a phase is ``VMAdmissionTests``'.
@Suite("VMLifecyclePhase Tests", .caseScoped)
@MainActor
struct VMLifecyclePhaseTests {
    private static let session = VMLifecyclePhaseFixtures.session

    // MARK: - Projections

    private struct Row {
        let status: VMStatus
        /// The phase presented, or `nil` for the phase itself.
        let presented: VMLifecyclePhase?
        let sessionID: UUID?
        let hasLiveSession: Bool
        let holdsLiveIdentity: Bool
        let hasActiveDisplay: Bool
        let isAtRest: Bool
    }

    /// One row per ``VMLifecyclePhaseFixtures/all`` entry, in its order,
    /// written out independently of the projections.
    private static let expected: [Row] = {
        let s = session
        let running = VMLifecyclePhase.running(sessionID: s)
        let livePaused = VMLifecyclePhase.livePaused(sessionID: s)
        return [
            // Settled.
            Row(
                status: .stopped, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
                hasActiveDisplay: false, isAtRest: true),
            Row(
                status: .initialBoot, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
                hasActiveDisplay: false, isAtRest: true),
            Row(
                status: .error, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
                hasActiveDisplay: false, isAtRest: true),
            Row(
                status: .suspended, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
                hasActiveDisplay: true, isAtRest: true),
            Row(
                status: .running, presented: nil, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            Row(
                status: .paused, presented: nil, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            Row(
                status: .stopped, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
                hasActiveDisplay: false, isAtRest: false),
            // Starting, before and after it bound its session.
            Row(
                status: .starting, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: true,
                hasActiveDisplay: false, isAtRest: false),
            Row(
                status: .starting, presented: nil, sessionID: s, hasLiveSession: false, holdsLiveIdentity: true,
                hasActiveDisplay: false, isAtRest: false),
            // Restoring a saved state.
            Row(
                status: .restoring, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            // Setting up.
            Row(
                status: .installing, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: true,
                hasActiveDisplay: false, isAtRest: false),
            // Reverting a live VM.
            Row(
                status: .restoring, presented: nil, sessionID: s, hasLiveSession: false, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            // Pausing and resuming present where they started.
            Row(
                status: .running, presented: running, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            Row(
                status: .paused, presented: livePaused, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            // Saving.
            Row(
                status: .saving, presented: nil, sessionID: s, hasLiveSession: false, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            // Capturing live, and cold.
            Row(
                status: .snapshotting, presented: nil, sessionID: s, hasLiveSession: false, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            Row(
                status: .snapshotting, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            // Snapshot delete, USB attach, media reconcile, Force Stop.
            Row(
                status: .running, presented: running, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            Row(
                status: .running, presented: running, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            Row(
                status: .running, presented: running, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            Row(
                status: .running, presented: running, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            // Deleting a stopped VM, and creating a disk on one.
            Row(
                status: .stopped, presented: .stopped, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
                hasActiveDisplay: false, isAtRest: false),
            Row(
                status: .stopped, presented: .stopped, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
                hasActiveDisplay: false, isAtRest: false),
            // Creating a removable disk on a running VM.
            Row(
                status: .running, presented: running, sessionID: s, hasLiveSession: true, holdsLiveIdentity: true,
                hasActiveDisplay: true, isAtRest: false),
            // Deleting a snapshot of a stopped VM.
            Row(
                status: .stopped, presented: .stopped, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
                hasActiveDisplay: false, isAtRest: false),
        ]
    }()

    @Test("Every phase projects what the table states")
    func projections() {
        let phases = VMLifecyclePhaseFixtures.all
        #expect(phases.count == Self.expected.count)
        for (phase, row) in zip(phases, Self.expected) {
            #expect(phase.status == row.status, "status of \(phase)")
            #expect(phase.presented == (row.presented ?? phase), "presented of \(phase)")
            #expect(phase.sessionID == row.sessionID, "sessionID of \(phase)")
            #expect(phase.hasLiveSession == row.hasLiveSession, "hasLiveSession of \(phase)")
            #expect(phase.holdsLiveIdentity == row.holdsLiveIdentity, "holdsLiveIdentity of \(phase)")
            #expect(phase.hasActiveDisplay == row.hasActiveDisplay, "hasActiveDisplay of \(phase)")
            #expect(phase.isAtRest == row.isAtRest, "isAtRest of \(phase)")
        }
    }
}
