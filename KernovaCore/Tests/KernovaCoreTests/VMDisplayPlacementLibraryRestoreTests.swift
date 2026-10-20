import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Unit tests for
/// `VMDisplayPlacement.libraryRestore(wasKeyWindow:appWasActive:)` —
/// how a pop-in brings the library back so the popped-in display is visible.
///
/// The active-but-not-key case is the one that must do nothing: the user is
/// already in another Kernova window (the library's own placeholder button, for
/// instance), so re-showing the library would reorder windows under them.
@Suite("VMDisplayPlacement.libraryRestore", .caseScoped)
struct VMDisplayPlacementLibraryRestoreTests {
    @Test("Popping in from the key display window of an active app focuses the library")
    func keyAndActiveFocuses() {
        #expect(
            VMDisplayPlacement.libraryRestore(wasKeyWindow: true, appWasActive: true)
                == .focusLibrary)
    }

    @Test("Popping in while Kernova is not active shows the library in the background")
    func inactiveShowsInBackground() {
        #expect(
            VMDisplayPlacement.libraryRestore(wasKeyWindow: true, appWasActive: false)
                == .showInBackground)
        #expect(
            VMDisplayPlacement.libraryRestore(wasKeyWindow: false, appWasActive: false)
                == .showInBackground)
    }

    @Test("Popping in from another window of the active app restores nothing")
    func activeButNotKeyRestoresNothing() {
        #expect(
            VMDisplayPlacement.libraryRestore(wasKeyWindow: false, appWasActive: true)
                == VMDisplayPlacement.LibraryRestore.none)
    }
}
