import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

/// Unit tests for `VMDisplayPlacementController.popOutAction(hasWindow:mode:)`
/// — what "Pop Out Display" does for a VM.
///
/// An open window always pops back in, whatever the mode says. Without one,
/// only the headless `.hidden` mode pops *in* (it has a detached display and no
/// window to close); every other mode pops out.
@Suite("VMDisplayPlacementController.popOutAction", .admissionGated)
struct VMDisplayPlacementPopOutActionTests {
    @Test(
        "An open display window is closed, whatever mode it is in",
        arguments: [VMDisplayMode.inline, .popOut, .fullscreen, .hidden])
    func withWindowClosesIt(mode: VMDisplayMode) {
        #expect(
            VMDisplayPlacementController.popOutAction(hasWindow: true, mode: mode)
                == .closeWindowForPopIn)
    }

    @Test("A headless VM with no window pops the display back in directly")
    func headlessPopsInWithoutAWindow() {
        #expect(
            VMDisplayPlacementController.popOutAction(hasWindow: false, mode: .hidden)
                == .popInFromHeadless)
    }

    @Test(
        "Any other mode with no window pops the display out",
        arguments: [VMDisplayMode.inline, .popOut, .fullscreen])
    func noWindowPopsOut(mode: VMDisplayMode) {
        #expect(VMDisplayPlacementController.popOutAction(hasWindow: false, mode: mode) == .popOut)
    }
}

/// What a placement transition persists.
@Suite("VMDisplayPlacementController placement persistence", .serialized, .admissionGated)
@MainActor
struct VMDisplayPlacementPersistenceTests {
    private let preferences = makeTestPreferences()

    /// The write goes through the `display.preference` key, which resolves the
    /// VM through the library — so the VM has to be in it.
    @Test("Popping a headless display back in persists Inline through the configuration verb")
    func popInFromHeadlessPersistsInlineThroughTheVerb() throws {
        let viewModel = makeSettingsViewModel(preferences: preferences)
        let storage = try #require(viewModel.storageService as? MockVMStorageService)
        let instance = viewModel.library.registerFixture(
            phase: .running(sessionID: UUID()), hostState: VMHostState(displayPreference: .popOut))
        instance.displayMode = .hidden
        let placement = VMDisplayPlacementController(
            viewModel: viewModel, autosaveScope: .unsaved())

        placement.togglePopOut(for: instance)

        #expect(instance.displayMode == .inline)
        #expect(instance.hostState.displayPreference == .inline)
        #expect(storage.hostStates[instance.bundleURL]?.displayPreference == .inline)
    }
}
