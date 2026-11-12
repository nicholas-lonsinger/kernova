import AppKit
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// A display window that moves while the bring-up that readied it still holds
/// the VM — a fullscreen VM's window finishing its transition into fullscreen
/// before the guest is up.
@Suite("VMDisplayPlacementController during a bring-up", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMDisplayPlacementBringUpTests {
    private let preferences = makeTestPreferences()
    private let stage = WindowStage.offDesktop()

    /// Puts a readied window up behind, so no test runs AppKit's real
    /// fullscreen transition; the transition's end is delivered by hand.
    private final class BackgroundResidency: WindowResidencyHosting {
        var guiPosture: GUIPosture { .background }
        func prepareToPresentWindow() {}
        func syncActivationPolicy() {}
    }

    /// The window entering fullscreen while the VM starts records Fullscreen
    /// — a move from Pop Out, or the preference it already holds — with no
    /// refusal for the user to read, and the start goes on to run the VM.
    @Test(
        "A display entering fullscreen while its VM starts records it without an alert",
        arguments: [VMDisplayPreference.popOut, .fullscreen])
    func enteringFullscreenDuringStartRaisesNoAlert(preference: VMDisplayPreference) async throws {
        let virtualization = MockVirtualizationService()
        let gate = GatedStep()
        virtualization.startGate = gate
        let viewModel = makeLibraryViewModel(
            preferences: preferences, virtualizationService: virtualization)
        let presenter = MockVMLibraryPresenting()
        viewModel.presenter = presenter
        let placement = VMDisplayPlacementController(viewModel: viewModel, stage: stage, focus: RecordingSessionFocus())
        let residency = BackgroundResidency()
        placement.residency = residency
        viewModel.onReadyDisplay = { placement.readyDisplay(for: $0, presence: $1) }
        let instance = viewModel.library.registerFixture(
            name: "Starting", guestOS: .macOS,
            hostState: VMHostState(displayPreference: preference))

        let start = Task { await viewModel.start(instance) }
        try await gate.waitUntilEntered()
        try #require(instance.status == .starting)
        let window = try #require(placement.window(for: instance.instanceID))
        let controller = try #require(window.windowController as? VMDisplayWindowController)

        controller.windowDidEnterFullScreen(
            Notification(name: NSWindow.didEnterFullScreenNotification, object: window))

        #expect(presenter.errors.isEmpty)
        #expect(instance.displayMode == .fullscreen)
        #expect(instance.hostState.displayPreference == .fullscreen)
        gate.release()
        await start.value
        #expect(instance.status == .running)
        #expect(presenter.errors.isEmpty)
    }
}
