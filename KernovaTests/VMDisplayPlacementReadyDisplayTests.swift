import AppKit
import KernovaKit
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// Covers `VMDisplayPlacementController.readyDisplay(for:presence:)` — the
/// window a bring-up opens, and how it goes on screen, as
/// `VMDisplayPlacement.readying(preference:posture:presence:)` decides
/// (`VMDisplayPlacementReadyingTests`).
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

    private func makeInstance(preference: VMDisplayPreference) -> VMInstance {
        VMInstanceFixture.make(
            name: "Readied VM", hostState: VMHostState(displayPreference: preference))
    }

    private func makeController(posture: GUIPosture)
        -> (VMDisplayPlacementController, StubResidency)
    {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let placement = VMDisplayPlacementController(viewModel: viewModel, stage: stage)
        let residency = StubResidency(posture: posture)
        placement.residency = residency
        return (placement, residency)
    }

    @Test("A bring-up while the app presents no GUI opens no window")
    func absentOpensNoWindow() {
        let (placement, residency) = makeController(posture: .absent)
        let instance = makeInstance(preference: .fullscreen)

        placement.readyDisplay(for: instance, presence: .attended)

        #expect(placement.window(for: instance.instanceID) == nil)
        #expect(residency.prepareCount == 0)
    }

    /// The whole point of readying from the background: the window is up and
    /// drawing, and the app the user is in keeps key and the screen. A
    /// fullscreen VM lands in a pop-out window, with its persisted preference
    /// left alone for the reopen that follows.
    @Test("A bring-up from the background puts the window up without taking key")
    func backgroundOpensAnUnkeyWindow() throws {
        let (placement, residency) = makeController(posture: .background)
        let instance = makeInstance(preference: .fullscreen)

        placement.readyDisplay(for: instance, presence: .attended)

        let window = try #require(placement.window(for: instance.instanceID))
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
        #expect(!window.styleMask.contains(.fullScreen))
        #expect(instance.displayMode == .popOut)
        #expect(instance.hostState.displayPreference == .fullscreen)
        #expect(residency.prepareCount == 1)
    }

    /// The whole chain a sidebar Start All runs: the core readies each VM as
    /// unattended, and a Kernova the user is in puts the windows up without
    /// any of them taking key or a Space.
    @Test("A group start from the foreground puts each detached display up without taking key")
    func groupStartReadiesBehind() async throws {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let placement = VMDisplayPlacementController(viewModel: viewModel, stage: stage)
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
        // That a window readied behind takes no key is read in
        // backgroundOpensAnUnkeyWindow, with no await before it. Past the await
        // above, AppKit's one key window is whatever the suites running
        // alongside left it (CI run 38955117057).
        for instance in [popOut, fullscreen] {
            let window = try #require(placement.window(for: instance.instanceID))
            #expect(window.isVisible)
        }
        // Put up behind, the fullscreen VM runs in a pop-out window with its
        // preference kept — a front readying would have entered fullscreen.
        #expect(fullscreen.displayMode == .popOut)
        #expect(fullscreen.hostState.displayPreference == .fullscreen)
        #expect(residency.prepareCount == 2)
    }
}
