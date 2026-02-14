import Testing
import Foundation
@testable import Kernova

@Suite("VMBootMode Tests")
struct VMBootModeTests {

    // MARK: - Display Name

    @Test("displayName returns expected string for each mode")
    func displayName() {
        #expect(VMBootMode.macOS.displayName == "macOS Boot Loader")
        #expect(VMBootMode.efi.displayName == "EFI Boot")
        #expect(VMBootMode.linuxKernel.displayName == "Linux Kernel")
    }

    // MARK: - Valid Modes

    @Test("validModes for macOS returns only macOS boot mode")
    func validModesForMacOS() {
        let modes = VMBootMode.validModes(for: .macOS)
        #expect(modes == [.macOS])
    }

    @Test("validModes for Linux returns EFI and linuxKernel")
    func validModesForLinux() {
        let modes = VMBootMode.validModes(for: .linux)
        #expect(modes == [.efi, .linuxKernel])
    }

    // MARK: - Codable Round-Trip

    @Test("macOS boot mode round-trips through JSON")
    func codableRoundTripMacOS() throws {
        let original = VMBootMode.macOS
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VMBootMode.self, from: data)
        #expect(decoded == original)
    }

    @Test("EFI boot mode round-trips through JSON")
    func codableRoundTripEFI() throws {
        let original = VMBootMode.efi
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VMBootMode.self, from: data)
        #expect(decoded == original)
    }

    @Test("linuxKernel boot mode round-trips through JSON")
    func codableRoundTripLinuxKernel() throws {
        let original = VMBootMode.linuxKernel
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VMBootMode.self, from: data)
        #expect(decoded == original)
    }
}
