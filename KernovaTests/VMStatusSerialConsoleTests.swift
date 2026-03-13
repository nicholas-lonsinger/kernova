import Testing
import Foundation
@testable import Kernova

@Suite("VMStatus Serial Console Validation Tests")
@MainActor
struct VMStatusSerialConsoleTests {

    private func makeInstance(status: VMStatus = .stopped) -> VMInstance {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL, status: status)
    }

    // MARK: - Serial Console Eligibility

    @Test("Serial console requires a live virtual machine")
    func serialConsoleRequiresVirtualMachine() {
        let instance = makeInstance(status: .running)
        // Without a real VZVirtualMachine, virtualMachine is nil
        #expect(instance.virtualMachine == nil)
        #expect(instance.canShowSerialConsole == false,
                "Should not allow serial console without a live virtual machine")
    }

    @Test(
        "Inactive statuses are ineligible for serial console",
        arguments: [
            VMStatus.stopped, .starting, .saving, .restoring, .installing, .error,
        ]
    )
    func inactiveStatusIneligible(status: VMStatus) {
        let instance = makeInstance(status: status)
        #expect(instance.canShowSerialConsole == false,
                "Expected \(status) to be ineligible for serial console")
    }

    @Test("Cold-paused VM (paused with no virtualMachine) is ineligible for serial console")
    func coldPausedVMIneligible() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)
        #expect(instance.canShowSerialConsole == false,
                "Cold-paused VM has no live virtual machine")
    }
}
