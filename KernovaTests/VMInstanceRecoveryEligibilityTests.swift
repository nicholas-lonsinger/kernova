import Testing
import Foundation
@testable import Kernova

@Suite("VMInstance Recovery Eligibility", .admissionGated)
@MainActor
struct VMInstanceRecoveryEligibilityTests {
    @Test("A stopped macOS guest is eligible for a recovery boot")
    func stoppedMacOSIsEligible() {
        #expect(VMInstanceFixture.make(guestOS: .macOS, phase: .stopped).canStartInRecovery)
    }

    @Test("A stopped Linux guest is not eligible — VZ has no EFI/Linux recovery option")
    func stoppedLinuxIsNotEligible() {
        #expect(!VMInstanceFixture.make(guestOS: .linux, phase: .stopped).canStartInRecovery)
    }

    @Test(
        "Non-stopped macOS guests are not eligible",
        arguments: [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
            .suspended, .starting(sessionID: nil), .initialBoot,
            .failed(message: "Boot failed."),
        ])
    func nonStoppedMacOSIsNotEligible(phase: VMLifecyclePhase) {
        #expect(!VMInstanceFixture.make(guestOS: .macOS, phase: phase).canStartInRecovery)
    }
}
