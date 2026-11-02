import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers a popped-out display across the end of one session and the start of
/// the next: wherever the display window is, the VM's `displayMode` says so.
@Suite("VMDisplayPlacementController across sessions", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMDisplayPlacementSessionTests {
    private let preferences = makeTestPreferences()
    private let stage = WindowStage.offDesktop()

    /// Answers the placement controller as a Kernova the user is in.
    private final class ForegroundResidency: WindowResidencyHosting {
        var guiPosture: GUIPosture { .foreground }
        func prepareToPresentWindow() {}
        func syncActivationPolicy() {}
    }

    /// How the session the popped-out display shows ends and the next begins.
    enum NextSession: CaseIterable, Sendable {
        /// The Restart verb: the boot is the ended session's continuation.
        case restart
        /// A Stop, then a Start.
        case stopThenStart
    }

    @Test(
        "A popped-out display stays popped out into the next session",
        arguments: NextSession.allCases)
    func poppedOutDisplayCarriesIntoTheNextSession(next: NextSession) async throws {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let placement = VMDisplayPlacementController(viewModel: viewModel, stage: stage)
        let residency = ForegroundResidency()
        placement.residency = residency
        viewModel.onReadyDisplay = { placement.readyDisplay(for: $0, presence: $1) }
        let instance = viewModel.library.admitFixture(name: "Popped Out")
        await viewModel.start(instance)
        try #require(instance.status == .running)
        placement.togglePopOut(for: instance)
        try #require(placement.window(for: instance.instanceID) != nil)
        try #require(instance.displayMode == .popOut)
        let firstSession = instance.liveSessionID

        switch next {
        case .restart:
            await viewModel.restart(instance)
        case .stopThenStart:
            await viewModel.stop(instance)
            await viewModel.start(instance)
        }
        // The window's observation runs behind the first barrier, and a close
        // it requests finishes its deferred phase behind the second.
        await drainMainQueue()
        await drainMainQueue()

        #expect(instance.status == .running)
        #expect(instance.liveSessionID != firstSession)
        let window = try #require(placement.window(for: instance.instanceID))
        #expect(window.isVisible)
        #expect(instance.displayMode == .popOut)
        #expect(instance.hostState.displayPreference == .popOut)
    }
}
