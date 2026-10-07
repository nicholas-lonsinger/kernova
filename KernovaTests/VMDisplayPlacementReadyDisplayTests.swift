import AppKit
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers `VMDisplayPlacementController.readying(preference:posture:presence:)`
/// and the `readyDisplay(for:presence:)` that runs it — whether a bring-up opens
/// a window for the VM coming up, and how that window goes on screen.
///
/// A bring-up is not a request to look at the guest, so both answers are taken
/// from the app's own posture, the VM's persisted placement, and whether anyone
/// asked for this VM in particular — never from which door asked.
@Suite("VMDisplayPlacementController readying", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMDisplayPlacementReadyDisplayTests {
    private let preferences = makeTestPreferences()
    private let autosave = WindowAutosaveScope.unsaved()

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
        let placement = VMDisplayPlacementController(viewModel: viewModel, autosaveScope: autosave)
        let residency = StubResidency(posture: posture)
        placement.residency = residency
        return (placement, residency)
    }

    // MARK: - The decision

    @Test("A detached VM readied from the foreground takes key, in its persisted style")
    func foregroundReadiesInFront() {
        #expect(
            VMDisplayPlacementController.readying(preference: .popOut, posture: .foreground, presence: .attended)
                == .front(fullscreen: false))
        #expect(
            VMDisplayPlacementController.readying(preference: .fullscreen, posture: .foreground, presence: .attended)
                == .front(fullscreen: true))
    }

    /// Never fullscreen from the background: entering it would move the user to
    /// a Space they did not ask for.
    @Test(
        "A detached VM readied from the background goes up behind",
        arguments: [VMDisplayPreference.popOut, .fullscreen])
    func backgroundReadiesBehind(preference: VMDisplayPreference) {
        #expect(
            VMDisplayPlacementController.readying(preference: preference, posture: .background, presence: .attended)
                == .behind)
    }

    /// Nobody asked for this VM in particular — a group action, a launch
    /// auto-start — so even in the foreground it neither takes key nor moves
    /// the user to a fullscreen Space.
    @Test(
        "A detached VM nobody asked for goes up behind, even from the foreground",
        arguments: [VMDisplayPreference.popOut, .fullscreen])
    func unattendedReadiesBehind(preference: VMDisplayPreference) {
        #expect(
            VMDisplayPlacementController.readying(
                preference: preference, posture: .foreground, presence: .unattended) == .behind)
        #expect(
            VMDisplayPlacementController.readying(
                preference: preference, posture: .background, presence: .unattended) == .behind)
        #expect(
            VMDisplayPlacementController.readying(preference: preference, posture: .absent, presence: .unattended)
                == nil)
    }

    /// A status-item-only app was asked not to have a GUI; a window here would
    /// hand it the Dock icon and menu bar it came up without.
    @Test(
        "A detached VM readies nothing while the app presents no GUI",
        arguments: [VMDisplayPreference.popOut, .fullscreen])
    func absentReadiesNothing(preference: VMDisplayPreference) {
        #expect(
            VMDisplayPlacementController.readying(preference: preference, posture: .absent, presence: .attended) == nil)
    }

    /// The inline display renders whichever VM the library has selected, and a
    /// bring-up does not change the user's selection.
    @Test(
        "An inline VM readies nothing, whatever the app is presenting",
        arguments: [GUIPosture.absent, .background, .foreground])
    func inlineReadiesNothing(posture: GUIPosture) {
        #expect(
            VMDisplayPlacementController.readying(preference: .inline, posture: posture, presence: .attended) == nil)
        #expect(
            VMDisplayPlacementController.readying(preference: .inline, posture: posture, presence: .unattended) == nil)
    }

    // MARK: - The wiring

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
        adoptAppWindow(window)
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
        let placement = VMDisplayPlacementController(viewModel: viewModel, autosaveScope: autosave)
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
        for instance in [popOut, fullscreen] {
            let window = try #require(placement.window(for: instance.instanceID))
            adoptAppWindow(window)
            #expect(window.isVisible)
            #expect(!window.isKeyWindow)
        }
        // Put up behind, the fullscreen VM runs in a pop-out window with its
        // preference kept — a front readying would have entered fullscreen.
        #expect(fullscreen.displayMode == .popOut)
        #expect(fullscreen.hostState.displayPreference == .fullscreen)
        #expect(residency.prepareCount == 2)
    }
}
