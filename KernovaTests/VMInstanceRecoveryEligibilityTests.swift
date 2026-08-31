import Testing
import Foundation
@testable import Kernova

@Suite("VMInstance Recovery Eligibility", .admissionGated)
@MainActor
struct VMInstanceRecoveryEligibilityTests {
    private func makeInstance(phase: VMLifecyclePhase, guestOS: VMGuestOS) -> VMInstance {
        let bootMode: VMBootMode = guestOS == .macOS ? .macOS : .efi
        let config = VMConfiguration(name: "Test VM", guestOS: guestOS, bootMode: bootMode)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, phase: phase)
    }

    @Test("A stopped macOS guest is eligible for a recovery boot")
    func stoppedMacOSIsEligible() {
        #expect(makeInstance(phase: .stopped, guestOS: .macOS).canStartInRecovery)
    }

    @Test("A stopped Linux guest is not eligible — VZ has no EFI/Linux recovery option")
    func stoppedLinuxIsNotEligible() {
        #expect(!makeInstance(phase: .stopped, guestOS: .linux).canStartInRecovery)
    }

    @Test(
        "Non-stopped macOS guests are not eligible",
        arguments: [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
            .suspended, .starting(sessionID: nil), .initialBoot,
            .failed(message: "Boot failed."),
        ])
    func nonStoppedMacOSIsNotEligible(phase: VMLifecyclePhase) {
        #expect(!makeInstance(phase: phase, guestOS: .macOS).canStartInRecovery)
    }
}
