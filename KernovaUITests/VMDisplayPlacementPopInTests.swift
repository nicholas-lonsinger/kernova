import AppKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaUI

/// Covers how popping a display back in brings the library back, as
/// `VMDisplayPlacement.libraryRestore(wasKey:appWasActive:)` decides from
/// whether the display window was key as it closed.
@Suite("VMDisplayPlacementController pop-in", .serialized, .caseScoped, .scopedWindows)
@MainActor
struct VMDisplayPlacementPopInTests {
    private let preferences = makeTestPreferences()

    @Test(
        "Popping in from the key display window brings the library forward key; from another window it leaves it",
        arguments: [true, false])
    func popInRestoresTheLibraryByKey(displayWasKey: Bool) async throws {
        let viewModel = makeLibraryViewModel(preferences: preferences)
        let focus = RecordingSessionFocus(isActive: true)
        let registry = makeWindowRegistry(viewModel, focus: focus)
        let placement = registry.displayPlacement
        let instance = viewModel.library.admitFixture(name: "Popped Out", phase: .running(sessionID: UUID()))
        placement.togglePopOut(for: instance)
        try #require(placement.window(for: instance.instanceID) != nil)
        if !displayWasKey { registry.showSettings() }
        let requestsBefore = focus.requests

        placement.togglePopOut(for: instance)
        await drainMainQueue()

        if displayWasKey {
            let library = try #require(registry.libraryWindow)
            #expect(focus.requests == requestsBefore + [.present(library, .keyAndFront)])
        } else {
            #expect(registry.libraryWindow == nil)
            #expect(focus.requests == requestsBefore)
        }
    }
}
