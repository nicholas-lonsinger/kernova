import Testing
import Foundation
import KernovaTestSupport
@testable import Kernova

@Suite("Recovery boot admission", .admissionGated)
@MainActor
struct VMInstanceRecoveryEligibilityTests {
    private func admitsRecovery(_ instance: VMInstance) -> Bool {
        instance.activity.admits(.start(recovery: true))
    }

    @Test("A stopped macOS guest is eligible for a recovery boot")
    func stoppedMacOSIsEligible() {
        #expect(admitsRecovery(VMInstanceFixture.make(guestOS: .macOS, phase: .stopped)))
    }

    @Test("A stopped Linux guest is not eligible — VZ has no EFI/Linux recovery option")
    func stoppedLinuxIsNotEligible() {
        #expect(!admitsRecovery(VMInstanceFixture.make(guestOS: .linux, phase: .stopped)))
    }

    @Test(
        "Non-stopped macOS guests are not eligible",
        arguments: [
            PhaseFixture.settled(.running(sessionID: UUID())), .settled(.livePaused(sessionID: UUID())),
            .settled(.suspended), .operating(.bringUp(.starting(recovery: false)), from: .stopped),
            .settled(.initialBoot), .settled(.failed(message: "Boot failed.")),
        ])
    func nonStoppedMacOSIsNotEligible(phase: PhaseFixture) {
        #expect(!admitsRecovery(VMInstanceFixture.make(guestOS: .macOS, phase: phase.phase)))
    }
}
