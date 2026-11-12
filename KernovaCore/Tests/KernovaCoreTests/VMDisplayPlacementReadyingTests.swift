import KernovaTestSupport
import Testing

@testable import KernovaCore

/// Covers `VMDisplayPlacement.readying(preference:posture:presence:)` — whether
/// a bring-up opens a window for the VM coming up, and how that window goes on
/// screen.
///
/// A bring-up is not a request to look at the guest, so both answers are taken
/// from the app's own posture, the VM's persisted placement, and whether anyone
/// asked for this VM in particular — never from which door asked.
@Suite("VMDisplayPlacement.readying", .caseScoped)
struct VMDisplayPlacementReadyingTests {
    @Test("A detached VM readied from the foreground takes key, in its persisted style")
    func foregroundReadiesInFront() {
        #expect(
            VMDisplayPlacement.readying(preference: .popOut, posture: .foreground, presence: .attended)
                == .front(fullscreen: false))
        #expect(
            VMDisplayPlacement.readying(preference: .fullscreen, posture: .foreground, presence: .attended)
                == .front(fullscreen: true))
    }
}
