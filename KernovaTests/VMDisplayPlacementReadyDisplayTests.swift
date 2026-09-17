import AppKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// Covers `VMDisplayPlacementController.readying(preference:posture:)` and the
/// `readyDisplay(for:)` that runs it — whether a bring-up opens a window for the
/// VM coming up, and how that window goes on screen.
///
/// A bring-up is not a request to look at the guest, so both answers are taken
/// from the app's own posture and the VM's persisted placement, never from who
/// asked for the start.
@Suite("VMDisplayPlacementController readying", .serialized, .admissionGated)
@MainActor
struct VMDisplayPlacementReadyDisplayTests {
    /// Isolated, pre-cleaned preferences for this suite's `VMLibraryViewModel`.
    private let preferences = makeEphemeralPreferences(
        suiteName: "test.kernova.displayplacementreadying")

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
        VMInstanceFixture.make(name: "Readied VM") { $0.displayPreference = preference }
    }

    private func makeController(posture: GUIPosture)
        -> (VMDisplayPlacementController, StubResidency)
    {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let placement = VMDisplayPlacementController(viewModel: viewModel)
        let residency = StubResidency(posture: posture)
        placement.residency = residency
        return (placement, residency)
    }

    // MARK: - The decision

    @Test("A detached VM readied from the foreground takes key, in its persisted style")
    func foregroundReadiesInFront() {
        #expect(
            VMDisplayPlacementController.readying(preference: .popOut, posture: .foreground)
                == .front(fullscreen: false))
        #expect(
            VMDisplayPlacementController.readying(preference: .fullscreen, posture: .foreground)
                == .front(fullscreen: true))
    }

    /// Never fullscreen from the background: entering it would move the user to
    /// a Space they did not ask for.
    @Test(
        "A detached VM readied from the background goes up behind",
        arguments: [VMDisplayPreference.popOut, .fullscreen])
    func backgroundReadiesBehind(preference: VMDisplayPreference) {
        #expect(
            VMDisplayPlacementController.readying(preference: preference, posture: .background)
                == .behind)
    }

    /// A status-item-only app was asked not to have a GUI; a window here would
    /// hand it the Dock icon and menu bar it came up without.
    @Test(
        "A detached VM readies nothing while the app presents no GUI",
        arguments: [VMDisplayPreference.popOut, .fullscreen])
    func absentReadiesNothing(preference: VMDisplayPreference) {
        #expect(
            VMDisplayPlacementController.readying(preference: preference, posture: .absent) == nil)
    }

    /// The inline display renders whichever VM the library has selected, and a
    /// bring-up does not change the user's selection.
    @Test(
        "An inline VM readies nothing, whatever the app is presenting",
        arguments: [GUIPosture.absent, .background, .foreground])
    func inlineReadiesNothing(posture: GUIPosture) {
        #expect(VMDisplayPlacementController.readying(preference: .inline, posture: posture) == nil)
    }

    // MARK: - The wiring

    @Test("A bring-up while the app presents no GUI opens no window")
    func absentOpensNoWindow() {
        let (placement, residency) = makeController(posture: .absent)
        defer { placement.closeAllForAppDismissal() }
        let instance = makeInstance(preference: .fullscreen)

        placement.readyDisplay(for: instance)

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
        defer { placement.closeAllForAppDismissal() }
        let instance = makeInstance(preference: .fullscreen)

        placement.readyDisplay(for: instance)

        let window = try #require(placement.window(for: instance.instanceID))
        #expect(window.isVisible)
        #expect(!window.isKeyWindow)
        #expect(!window.styleMask.contains(.fullScreen))
        #expect(instance.displayMode == .popOut)
        #expect(instance.configuration.displayPreference == .fullscreen)
        #expect(residency.prepareCount == 1)
    }
}
