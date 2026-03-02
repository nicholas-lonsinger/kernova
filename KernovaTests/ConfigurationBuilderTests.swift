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

    // MARK: - Shared Directory Validation

    @Test("Builder throws for missing shared directory path")
    func builderThrowsForMissingSharedDirectoryPath() throws {
        var config = VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .efi
        )
        config.sharedDirectories = [
            SharedDirectory(path: "/nonexistent/path/\(UUID().uuidString)")
        ]

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a dummy disk image so we get past disk validation
        let diskURL = VMBundleLayout(bundleURL: tempDir).diskImageURL
        try Data().write(to: diskURL)

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: tempDir)
        }
    }

    @Test("Builder throws for shared path that is a file")
    func builderThrowsForSharedPathThatIsAFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a file (not a directory) to use as the shared path
        let filePath = tempDir.appendingPathComponent("not-a-directory").path
        FileManager.default.createFile(atPath: filePath, contents: nil)

        var config = VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .efi
        )
        config.sharedDirectories = [
            SharedDirectory(path: filePath)
        ]

        // Create a dummy disk image so we get past disk validation
        let diskURL = VMBundleLayout(bundleURL: tempDir).diskImageURL
        try Data().write(to: diskURL)

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: tempDir)
        }
    }

    @Test("Builder throws for non-writable read-write share")
    func builderThrowsForNonWritableReadWriteShare() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a read-only directory
        let shareDir = tempDir.appendingPathComponent("readonly-share")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: shareDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shareDir.path) }

        var config = VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .efi
        )
        config.sharedDirectories = [
            SharedDirectory(path: shareDir.path, readOnly: false)
        ]

        // Create a dummy disk image so we get past disk validation
        let diskURL = VMBundleLayout(bundleURL: tempDir).diskImageURL
        try Data().write(to: diskURL)

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: tempDir)
        }
    }

    @Test("Builder accepts read-only share for non-writable directory")
    func builderAcceptsReadOnlyShareForNonWritableDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a read-only directory
        let shareDir = tempDir.appendingPathComponent("readonly-share")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: shareDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shareDir.path) }

        var config = VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .efi
        )
        config.sharedDirectories = [
            SharedDirectory(path: shareDir.path, readOnly: true)
        ]

        // Create a dummy disk image so we get past disk validation
        let diskURL = VMBundleLayout(bundleURL: tempDir).diskImageURL
        try Data().write(to: diskURL)

        let builder = ConfigurationBuilder()
        // Build may fail for other reasons (EFI setup), but must NOT fail
        // with a shared directory error — validation should pass.
        do {
            _ = try builder.build(from: config, bundleURL: tempDir)
        } catch let error as ConfigurationBuilderError {
            switch error {
            case .sharedDirectoryNotFound, .sharedDirectoryNotADirectory,
                 .sharedDirectoryNotReadable, .sharedDirectoryNotWritable:
                Issue.record("Unexpected shared directory error: \(error)")
            default:
                break  // Other ConfigurationBuilder errors (e.g., EFI setup) are expected
            }
        } catch {
            // VZ framework or other errors are expected — the test only
            // verifies that shared directory validation itself passes.
        }
    }
}
