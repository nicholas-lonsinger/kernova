import Foundation
import Testing

@testable import KernovaCore
@testable import KernovaUI

/// What a placement transition persists.
@Suite("VMDisplayPlacementController placement persistence", .serialized, .caseScoped)
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
            viewModel: viewModel, stage: .offDesktop())

        placement.togglePopOut(for: instance)

        #expect(instance.displayMode == .inline)
        #expect(instance.hostState.displayPreference == .inline)
        #expect(storage.hostStates[instance.bundleURL]?.displayPreference == .inline)
    }
}
