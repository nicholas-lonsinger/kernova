import Testing
import Virtualization
@testable import Kernova

@Suite("VirtualizationService Recovery Options")
@MainActor
struct VirtualizationServiceRecoveryOptionsTests {
    @Test("A macOS guest with recovery requested gets startUpFromMacOSRecovery options")
    func macOSRecoveryBuildsOptions() {
        let options = VirtualizationService.recoveryStartOptions(bootIntoRecovery: true, guestOS: .macOS)
        #expect(options != nil)
        #expect(options?.startUpFromMacOSRecovery == true)
    }

    @Test("A Linux guest never gets recovery options")
    func linuxGetsNoOptions() {
        #expect(VirtualizationService.recoveryStartOptions(bootIntoRecovery: true, guestOS: .linux) == nil)
    }

    @Test("A macOS guest without recovery requested gets no options (normal boot)")
    func macOSWithoutRecoveryGetsNoOptions() {
        #expect(VirtualizationService.recoveryStartOptions(bootIntoRecovery: false, guestOS: .macOS) == nil)
    }
}
