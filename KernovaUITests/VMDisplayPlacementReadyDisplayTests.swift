import AppKit
import KernovaCommandModel
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers `VMDisplayPlacementController.readyDisplay(for:presence:)` — the
/// window a bring-up opens, and how it goes on screen, as
/// `VMDisplayPlacement.readying(preference:posture:presence:)` decides.
@Suite("VMDisplayPlacementController readying", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMDisplayPlacementReadyDisplayTests {
    private let preferences = makeTestPreferences()
    private let stage = WindowStage.offDesktop()

    /// Answers the placement controller with a fixed posture, standing in for
    /// the residency controller that reads the live one.
    private final class StubResidency: WindowResidencyHosting {
        let guiPosture: GUIPosture
        private(set) var prepareCount = 0

        init(posture: GUIPosture) { guiPosture = posture }

        func prepareToPresentWindow() { prepareCount += 1 }
        func syncActivationPolicy() {}
    }

    /// The whole chain a sidebar Start All runs: the core readies each VM as
    /// unattended, and a Kernova the user is in puts the windows up without
    /// any of them taking key or a Space.
    @Test("A group start from the foreground puts each detached display up without taking key")
    func groupStartReadiesBehind() async throws {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let focus = RecordingSessionFocus()
        let placement = VMDisplayPlacementController(viewModel: viewModel, stage: stage, focus: focus)
        let residency = StubResidency(posture: .foreground)
        placement.residency = residency
        let popOut = viewModel.library.admitFixture(
            name: "Pop Out", hostState: VMHostState(displayPreference: .popOut))
        let fullscreen = viewModel.library.admitFixture(
            name: "Fullscreen", hostState: VMHostState(displayPreference: .fullscreen))
        let folder = try viewModel.library.createFolder(named: "Lab", members: [popOut.id, fullscreen.id])
        var presences: [VMBringUpPresence] = []
        viewModel.onReadyDisplay = {
            presences.append($1)
            placement.readyDisplay(for: $0, presence: $1)
        }

        await viewModel.performGroupAction(.start, on: VMGroupReference(.folder, named: folder.id.uuidString))

        #expect(popOut.status == .running && fullscreen.status == .running)
        #expect(presences == [.unattended, .unattended])
        // Each put up in front of Kernova's other windows alone, and none
        // asked into fullscreen.
        #expect(focus.requests.count == 2)
        for instance in [popOut, fullscreen] {
            let window = try #require(placement.window(for: instance.instanceID))
            #expect(focus.requests.contains(.present(window, .front)))
        }
        // Put up behind, the fullscreen VM runs in a pop-out window with its
        // preference kept — a front readying would have entered fullscreen.
        #expect(fullscreen.displayMode == .popOut)
        #expect(fullscreen.hostState.displayPreference == .fullscreen)
        #expect(residency.prepareCount == 2)
    }
}
