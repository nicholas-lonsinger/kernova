import Testing
import Foundation
@testable import Kernova

@Suite("ConfigurationBuilder Tests")
struct ConfigurationBuilderTests {

    @Test("Builder throws for EFI boot without disk image")
    func efiBootWithoutDisk() throws {
        let config = VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .efi
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: tempDir)
        }
    }

    @Test("Builder throws for kernel boot without kernel path")
    func kernelBootWithoutPath() throws {
        let config = VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .linuxKernel
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: tempDir)
        }
    }

    #if arch(arm64)
    @Test("Builder throws for macOS boot without hardware model")
    func macOSBootWithoutHardwareModel() throws {
        let config = VMConfiguration(
            name: "Test macOS",
            guestOS: .macOS,
            bootMode: .macOS
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a dummy disk image so we get past disk validation
        let diskURL = VMBundleLayout(bundleURL: tempDir).diskImageURL
        try Data().write(to: diskURL)

        let builder = ConfigurationBuilder()
        #expect(throws: (any Error).self) {
            try builder.build(from: config, bundleURL: tempDir)
        }
    }
    #endif
}
