import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// Unit tests for `VMDisplayPlacement.popOutAction(hasWindow:mode:)`
/// — what "Pop Out Display" does for a VM.
///
/// An open window always pops back in, whatever the mode says. Without one,
/// only the headless `.hidden` mode pops *in* (it has a detached display and no
/// window to close); every other mode pops out.
@Suite("VMDisplayPlacement.popOutAction", .caseScoped)
struct VMDisplayPlacementPopOutActionTests {
    @Test(
        "An open display window is closed, whatever mode it is in",
        arguments: [VMDisplayMode.inline, .popOut, .fullscreen, .hidden])
    func withWindowClosesIt(mode: VMDisplayMode) {
        #expect(
            VMDisplayPlacement.popOutAction(hasWindow: true, mode: mode)
                == .closeWindowForPopIn)
    }

    @Test("A headless VM with no window pops the display back in directly")
    func headlessPopsInWithoutAWindow() {
        #expect(
            VMDisplayPlacement.popOutAction(hasWindow: false, mode: .hidden)
                == .popInFromHeadless)
    }

    @Test(
        "Any other mode with no window pops the display out",
        arguments: [VMDisplayMode.inline, .popOut, .fullscreen])
    func noWindowPopsOut(mode: VMDisplayMode) {
        #expect(VMDisplayPlacement.popOutAction(hasWindow: false, mode: mode) == .popOut)
    }
}
