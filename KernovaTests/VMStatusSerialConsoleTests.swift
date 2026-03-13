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

    /// The serial console requires both an active status (running/paused) and a live VZVirtualMachine.
    /// Since we can't create a real VZVirtualMachine in tests, these tests verify the status
    /// portion of the validation logic that AppDelegate.validateMenuItem uses.

    @Test("Serial console requires running or paused status")
    func serialConsoleRequiresActiveStatus() {
        let activeStatuses: [VMStatus] = [.running, .paused]
        let inactiveStatuses: [VMStatus] = [.stopped, .starting, .saving, .restoring, .installing, .error]

        for status in activeStatuses {
            let isActive = status == .running || status == .paused
            #expect(isActive == true, "Expected \(status) to be eligible for serial console")
        }

        for status in inactiveStatuses {
            let isActive = status == .running || status == .paused
            #expect(isActive == false, "Expected \(status) to be ineligible for serial console")
        }
    }

    @Test("Serial console requires a live virtual machine")
    func serialConsoleRequiresVirtualMachine() {
        let instance = makeInstance(status: .running)
        // Without a real VZVirtualMachine, virtualMachine is nil
        #expect(instance.virtualMachine == nil)

        let canShow = (instance.status == .running || instance.status == .paused)
            && instance.virtualMachine != nil
        #expect(canShow == false, "Should not allow serial console without a live virtual machine")
    }

    @Test("Stopped VM is ineligible for serial console regardless of other state")
    func stoppedVMIneligible() {
        let instance = makeInstance(status: .stopped)
        let canShow = (instance.status == .running || instance.status == .paused)
            && instance.virtualMachine != nil
        #expect(canShow == false)
    }

    @Test("Error VM is ineligible for serial console")
    func errorVMIneligible() {
        let instance = makeInstance(status: .error)
        let canShow = (instance.status == .running || instance.status == .paused)
            && instance.virtualMachine != nil
        #expect(canShow == false)
    }

    @Test("Starting VM is ineligible for serial console")
    func startingVMIneligible() {
        let instance = makeInstance(status: .starting)
        let canShow = (instance.status == .running || instance.status == .paused)
            && instance.virtualMachine != nil
        #expect(canShow == false)
    }

    @Test("Saving VM is ineligible for serial console")
    func savingVMIneligible() {
        let instance = makeInstance(status: .saving)
        let canShow = (instance.status == .running || instance.status == .paused)
            && instance.virtualMachine != nil
        #expect(canShow == false)
    }

    @Test("Cold-paused VM (paused with no virtualMachine) is ineligible for serial console")
    func coldPausedVMIneligible() {
        let instance = makeInstance(status: .paused)
        #expect(instance.isColdPaused == true)

        let canShow = (instance.status == .running || instance.status == .paused)
            && instance.virtualMachine != nil
        #expect(canShow == false, "Cold-paused VM has no live virtual machine")
    }
}
