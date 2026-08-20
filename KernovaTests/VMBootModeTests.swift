import Testing
import Foundation
@testable import Kernova

@Suite("VMBootMode Tests", .admissionGated)
struct VMBootModeTests {
    // MARK: - Display Name

    @Test("displayName returns expected string for each mode")
    func displayName() {
        #expect(VMBootMode.macOS.displayName == "macOS Boot Loader")
        #expect(VMBootMode.efi.displayName == "EFI Boot")
        #expect(VMBootMode.linuxKernel.displayName == "Linux Kernel")
    }

    // MARK: - Codable Round-Trip

    @Test(
        "Each mode encodes to its persisted spelling and decodes back",
        arguments: zip(
            [VMBootMode.macOS, .efi, .linuxKernel],
            ["macOS", "efi", "linuxKernel"]))
    func codableRoundTrip(mode: VMBootMode, persisted: String) throws {
        // The raw string is the on-disk shape in every bundle's config.json, so
        // it is asserted literally: a symmetric encode/decode round-trip stays
        // green through a case rename that no existing bundle can decode.
        let data = try JSONEncoder().encode(mode)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(persisted)\"")
        #expect(try JSONDecoder().decode(VMBootMode.self, from: data) == mode)
    }
}
