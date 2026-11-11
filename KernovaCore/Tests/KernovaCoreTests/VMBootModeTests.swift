import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCore

@Suite("VMBootMode Tests", .caseScoped)
struct VMBootModeTests {
    // MARK: - Display Name

    @Test("displayName returns expected string for each mode")
    func displayName() {
        #expect(VMBootMode.macOS.displayName == "macOS Boot Loader")
        #expect(VMBootMode.efi.displayName == "EFI Boot")
        #expect(VMBootMode.linuxKernel.displayName == "Linux Kernel")
    }
}
