import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The window-title marker composed from `EphemeralModeCopy.titleName`.
@Suite("Ephemeral Mode Title Tests", .caseScoped)
@MainActor
struct EphemeralModeTitleTests {
    @Test("A live session appends the marker")
    func liveSessionAppendsMarker() {
        let title = EphemeralModeCopy.titleName("Debian", ephemeralSessionRunning: true)
        #expect(title == "Debian (Ephemeral)")
    }
}

/// What a `VMInstance` reports about its ephemeral baseline.
@Suite("Ephemeral Mode Instance Tests", .serialized, .caseScoped)
@MainActor
struct EphemeralModeInstanceTests {
    private let preferences = makeTestPreferences()

    private func makeInstance(
        phase: VMLifecyclePhase = .stopped, _ hostState: VMHostState = VMHostState()
    ) -> VMInstance {
        VMInstanceFixture.make(
            name: "Throwaway", phase: phase, preferences: preferences, hostState: hostState)
    }

    @Test("A VM with the mode off has no baseline")
    func noBaselineWhileOff() {
        let snapshot = VMSnapshot(name: "Clean", macAddress: nil)
        let instance = makeInstance(VMHostState(ephemeralBaselineSnapshotID: snapshot.id))
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot], currentID: snapshot.id))

        #expect(instance.ephemeralBaselineSnapshot == nil)
        #expect(!instance.isEphemeralBaseline(snapshot))
    }
}
