import Testing

@testable import Kernova

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

    /// Nobody asked for this VM in particular — a group action, a launch
    /// auto-start — so even in the foreground it neither takes key nor moves
    /// the user to a fullscreen Space.
    @Test(
        "A detached VM nobody asked for goes up behind, even from the foreground",
        arguments: [VMDisplayPreference.popOut, .fullscreen])
    func unattendedReadiesBehind(preference: VMDisplayPreference) {
        #expect(
            VMDisplayPlacement.readying(
                preference: preference, posture: .foreground, presence: .unattended) == .behind)
        #expect(
            VMDisplayPlacement.readying(
                preference: preference, posture: .background, presence: .unattended) == .behind)
        #expect(
            VMDisplayPlacement.readying(preference: preference, posture: .absent, presence: .unattended)
                == nil)
    }

    /// The inline display renders whichever VM the library has selected, and a
    /// bring-up does not change the user's selection.
    @Test(
        "An inline VM readies nothing, whatever the app is presenting",
        arguments: [GUIPosture.absent, .background, .foreground])
    func inlineReadiesNothing(posture: GUIPosture) {
        #expect(
            VMDisplayPlacement.readying(preference: .inline, posture: posture, presence: .attended) == nil)
        #expect(
            VMDisplayPlacement.readying(preference: .inline, posture: posture, presence: .unattended) == nil)
    }
}
