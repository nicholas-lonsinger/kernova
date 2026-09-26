import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The projections every surface reads off a phase, over every fixture phase.
///
/// Admission's own reading of a phase is ``VMAdmissionTests``'.
@Suite("VMLifecyclePhase Tests", .admissionGated)
@MainActor
struct VMLifecyclePhaseTests {
    private static let session = VMLifecyclePhaseFixtures.session

    // MARK: - Fixture completeness

    @Test("The settled fixtures name every settled case once, and the operations only operations")
    func fixtureListIsComplete() {
        let settledKinds = VMLifecyclePhaseFixtures.settled.map(\.kind)
        #expect(Set(settledKinds) == Set(VMLifecyclePhaseKind.allCases).subtracting([.operating]))
        #expect(settledKinds.count == Set(settledKinds).count)
        for phase in VMLifecyclePhaseFixtures.operations {
            #expect(phase.kind == .operating, "\(phase)")
        }
    }

    @Test("The operation fixtures cover every declared status, identity and display shape")
    func operationFixturesCoverEveryDeclarationShape() {
        let declarations = VMLifecyclePhaseFixtures.operations.compactMap { $0.operation?.kind.declaration }
        #expect(declarations.contains { $0.status == .base })
        #expect(declarations.contains { if case .shows = $0.status { true } else { false } })
        for identity: VMOperationDeclaration.Identity in [.always, .viaSession, .never] {
            #expect(declarations.contains { $0.holdsIdentity == identity }, "\(identity)")
        }
        for display: VMOperationDeclaration.Display in [.shown, .hidden, .base] {
            #expect(declarations.contains { $0.display == display }, "\(display)")
        }
    }

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
                status: .paused, presented: nil, sessionID: nil, hasLiveSession: false, holdsLiveIdentity: false,
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
            // Capturing live, and disks alone.
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

    @Test("The failure message is a payload of the failed phase and of nothing else")
    func errorMessageBelongsToFailedAlone() {
        #expect(VMLifecyclePhase.failed(message: "Disk went away").errorMessage == "Disk went away")
        for phase in VMLifecyclePhaseFixtures.all where phase.kind != .failed {
            #expect(phase.errorMessage == nil, "\(phase)")
        }
    }

    // MARK: - Invariants across projections

    @Test("A live session presented is one a VZVirtualMachine exists for")
    func liveSessionNamesASession() {
        for phase in VMLifecyclePhaseFixtures.all where phase.hasLiveSession {
            #expect(phase.sessionID != nil, "\(phase)")
            #expect(phase.holdsLiveIdentity, "\(phase)")
        }
    }

    @Test("Nothing at rest names a session or holds an identity")
    func atRestHoldsNothingLive() {
        for phase in VMLifecyclePhaseFixtures.all where phase.isAtRest {
            #expect(phase.sessionID == nil, "\(phase)")
            #expect(!phase.holdsLiveIdentity, "\(phase)")
            #expect(phase.operation == nil, "\(phase)")
        }
    }

    @Test("The two paused meanings are distinct and report the one status the wire has")
    func pausedMeaningsAreDistinct() {
        let livePaused = VMLifecyclePhase.livePaused(sessionID: Self.session)
        #expect(livePaused.isLivePaused)
        #expect(!VMLifecyclePhase.suspended.isLivePaused)
        #expect(VMLifecyclePhase.suspended.status == .paused)
        #expect(livePaused.status == .paused)
        // A hot resume presents the paused guest it started from until it ends.
        #expect(VMLifecyclePhase.operating(.resuming, from: livePaused).isLivePaused)
    }
}
