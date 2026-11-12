import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Covers `VMDisplayPlacement.fullscreenScreen(lastDisplayID:screens:libraryScreen:displayID:)`
/// over screens named by their display ID.
@Suite("VMDisplayPlacement.fullscreenScreen", .caseScoped)
struct VMDisplayPlacementFullscreenScreenTests {
    private func screen(last: UInt32?, screens: [UInt32], library: UInt32?) -> UInt32? {
        VMDisplayPlacement.fullscreenScreen(
            lastDisplayID: last, screens: screens, libraryScreen: library, displayID: { $0 })
    }

    @Test("A disconnected last display falls back to the library window's screen")
    func disconnectedFallsBackToLibrary() {
        #expect(screen(last: 9, screens: [1, 2], library: 2) == 2)
        #expect(screen(last: nil, screens: [1, 2], library: 2) == 2)
    }
}
