import Testing
import Foundation
@testable import Kernova

@Suite("ConfigurationBuilder Tests")
struct ConfigurationBuilderTests {

    // MARK: - Helpers

    /// Creates a temp directory with a dummy disk image. Caller must `defer` removal of the returned URL.
    private func makeTempBundle(withDisk: Bool = false) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        if withDisk {
            try Data().write(to: VMBundleLayout(bundleURL: tempDir).diskImageURL)
        }
        return tempDir
    }

    /// Returns a Linux/EFI config with optional shared directories.
    private func makeLinuxConfig(
        sharedDirectories: [SharedDirectory]? = nil
    ) -> VMConfiguration {
        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.sharedDirectories = sharedDirectories
        return config
    }

    // MARK: - Boot Validation

    @Test("Builder throws for EFI boot without disk image")
    func efiBootWithoutDisk() throws {
        let bundleURL = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: makeLinuxConfig(), bundleURL: bundleURL)
        }
    }

    @Test("Builder throws for kernel boot without kernel path")
    func kernelBootWithoutPath() throws {
        let bundleURL = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    #if arch(arm64)
    @Test("Builder throws for macOS boot without hardware model")
    func macOSBootWithoutHardwareModel() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let config = VMConfiguration(name: "Test macOS", guestOS: .macOS, bootMode: .macOS)
        let builder = ConfigurationBuilder()
        #expect(throws: (any Error).self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }
    #endif

    // MARK: - Shared Directory Validation

    @Test("Builder throws for missing shared directory path")
    func builderThrowsForMissingSharedDirectoryPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: "/nonexistent/path/\(UUID().uuidString)")
        ])

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    @Test("Builder throws for shared path that is a file")
    func builderThrowsForSharedPathThatIsAFile() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a file (not a directory) to use as the shared path
        let filePath = bundleURL.appendingPathComponent("not-a-directory").path(percentEncoded: false)
        FileManager.default.createFile(atPath: filePath, contents: nil)

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: filePath)
        ])

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    @Test("Builder throws for non-writable read-write share")
    func builderThrowsForNonWritableReadWriteShare() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a read-only directory
        let shareDir = bundleURL.appendingPathComponent("readonly-share")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: shareDir.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shareDir.path(percentEncoded: false)) }

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: shareDir.path(percentEncoded: false), readOnly: false)
        ])

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    @Test("Builder throws for dangling symlink as shared directory")
    func builderThrowsForDanglingSymlinkSharedDirectory() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a symlink pointing to a nonexistent target
        let symlinkPath = bundleURL.appendingPathComponent("dangling-link").path(percentEncoded: false)
        let nonexistentTarget = bundleURL.appendingPathComponent("no-such-dir").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: nonexistentTarget)

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: symlinkPath)
        ])

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    @Test("Builder throws for symlink to file as shared directory")
    func builderThrowsForSymlinkToFileAsSharedDirectory() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a regular file, then symlink to it
        let filePath = bundleURL.appendingPathComponent("a-file").path(percentEncoded: false)
        FileManager.default.createFile(atPath: filePath, contents: nil)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-file").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: filePath)

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: symlinkPath)
        ])

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    @Test("Builder follows symlink to valid shared directory")
    func builderFollowsSymlinkToValidSharedDirectory() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a real directory and a symlink to it
        let realDir = bundleURL.appendingPathComponent("real-share")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-share").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realDir.path(percentEncoded: false))

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: symlinkPath, readOnly: true)
        ])

        let builder = ConfigurationBuilder()
        // Build may fail for other reasons (EFI setup), but must NOT fail
        // with a shared directory error — symlink should be resolved and accepted.
        do {
            _ = try builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            switch error {
            case .sharedDirectoryNotFound, .sharedDirectoryNotADirectory,
                 .sharedDirectoryNotReadable, .sharedDirectoryNotWritable:
                Issue.record("Unexpected shared directory error: \(error)")
            default:
                break  // Other ConfigurationBuilder errors (e.g., EFI setup) are expected
            }
        } catch {
            // VZ framework or other errors are expected
        }
    }

    // MARK: - Kernel / Initrd Path Validation

    @Test("Builder throws for nonexistent kernel path")
    func builderThrowsForNonexistentKernelPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = "/nonexistent/\(UUID().uuidString)/vmlinuz"

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    @Test("Builder throws for nonexistent initrd path")
    func builderThrowsForNonexistentInitrdPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a real kernel file so we get past that check
        let kernelPath = bundleURL.appendingPathComponent("vmlinuz").path(percentEncoded: false)
        FileManager.default.createFile(atPath: kernelPath, contents: Data([0]))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = kernelPath
        config.initrdPath = "/nonexistent/\(UUID().uuidString)/initrd.img"

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    // MARK: - ISO Path Validation

    @Test("Builder throws for nonexistent ISO path")
    func builderThrowsForNonexistentISOPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.isoPath = "/nonexistent/\(UUID().uuidString)/install.iso"

        let builder = ConfigurationBuilder()
        #expect(throws: ConfigurationBuilderError.self) {
            try builder.build(from: config, bundleURL: bundleURL)
        }
    }

    @Test("Builder accepts read-only share for non-writable directory")
    func builderAcceptsReadOnlyShareForNonWritableDirectory() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a read-only directory
        let shareDir = bundleURL.appendingPathComponent("readonly-share")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: shareDir.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shareDir.path(percentEncoded: false)) }

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: shareDir.path(percentEncoded: false), readOnly: true)
        ])

        let builder = ConfigurationBuilder()
        // Build may fail for other reasons (EFI setup), but must NOT fail
        // with a shared directory error — validation should pass.
        do {
            _ = try builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            switch error {
            case .sharedDirectoryNotFound, .sharedDirectoryNotADirectory,
                 .sharedDirectoryNotReadable, .sharedDirectoryNotWritable,
                 .kernelNotFound, .initrdNotFound, .isoImageNotFound:
                Issue.record("Unexpected validation error: \(error)")
            default:
                break  // Other ConfigurationBuilder errors (e.g., EFI setup) are expected
            }
        } catch {
            // VZ framework or other errors are expected — the test only
            // verifies that shared directory validation itself passes.
        }
    }
}
