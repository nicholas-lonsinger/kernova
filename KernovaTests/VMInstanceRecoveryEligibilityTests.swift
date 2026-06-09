import Testing
import Foundation
@testable import Kernova

@Suite("VMInstance Recovery Eligibility")
@MainActor
struct VMInstanceRecoveryEligibilityTests {
    private func makeInstance(status: VMStatus, guestOS: VMGuestOS) -> VMInstance {
        let bootMode: VMBootMode = guestOS == .macOS ? .macOS : .efi
        let config = VMConfiguration(name: "Test VM", guestOS: guestOS, bootMode: bootMode)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    @Test("A stopped macOS guest is eligible for a recovery boot")
    func stoppedMacOSIsEligible() {
        #expect(makeInstance(status: .stopped, guestOS: .macOS).canStartInRecovery)
    }

    @Test("A stopped Linux guest is not eligible — VZ has no EFI/Linux recovery option")
    func stoppedLinuxIsNotEligible() {
        #expect(!makeInstance(status: .stopped, guestOS: .linux).canStartInRecovery)
    }

    @Test(
        "Non-stopped macOS guests are not eligible",
        arguments: [VMStatus.running, .paused, .starting, .initialBoot, .error])
    func nonStoppedMacOSIsNotEligible(status: VMStatus) {
        #expect(!makeInstance(status: status, guestOS: .macOS).canStartInRecovery)
    }
}
