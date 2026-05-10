import Testing
import Foundation
import Virtualization
@testable import Kernova

@Suite("ConfigurationBuilder Tests")
struct ConfigurationBuilderTests {
    // MARK: - Helpers

    /// Creates a temp directory with a dummy disk image.
    ///
    /// Caller must `defer` removal of the returned URL.
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
        #expect {
            try builder.build(from: makeLinuxConfig(), bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .diskImageNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for kernel boot without kernel path")
    func kernelBootWithoutPath() throws {
        let bundleURL = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .missingKernelPath = e
            else { return false }
            return true
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
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotFound = e
            else { return false }
            return true
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
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotADirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for non-writable read-write share")
    func builderThrowsForNonWritableReadWriteShare() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a read-only directory
        let shareDir = bundleURL.appendingPathComponent("readonly-share")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: shareDir.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: shareDir.path(percentEncoded: false))
        }

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: shareDir.path(percentEncoded: false), readOnly: false)
        ])

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotWritable = e
            else { return false }
            return true
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
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotFound = e
            else { return false }
            return true
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
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotADirectory = e
            else { return false }
            return true
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
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath, withDestinationPath: realDir.path(percentEncoded: false))

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: symlinkPath, readOnly: true)
        ])

        let builder = ConfigurationBuilder()
        // Build may fail for other reasons (e.g., VZ framework validation), but must NOT fail
        // with a path validation error — symlink should be resolved and accepted.
        do {
            _ = try builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            switch error {
            // Path validation errors — these MUST NOT occur:
            case .sharedDirectoryNotFound, .sharedDirectoryNotADirectory,
                .sharedDirectoryNotReadable, .sharedDirectoryNotWritable,
                .kernelNotFound, .kernelPathIsDirectory,
                .initrdNotFound, .initrdPathIsDirectory,
                .discImageNotFound, .discImagePathIsDirectory, .discImageNotWritable,
                .additionalDiskNotFound, .additionalDiskPathIsDirectory, .additionalDiskNotWritable:
                Issue.record("Unexpected path validation error: \(error)")
            // Non-path-validation errors — tolerated if they occur:
            case .macOSGuestRequiresAppleSilicon,
                .invalidHardwareModel, .invalidMachineIdentifier,
                .missingKernelPath, .diskImageNotFound:
                break
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
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .kernelNotFound = e
            else { return false }
            return true
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
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .initrdNotFound = e
            else { return false }
            return true
        }
    }

    // MARK: - Disc Image Path Validation

    @Test("Builder throws for nonexistent disc image path")
    func builderThrowsForNonexistentDiscImagePath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = "/nonexistent/\(UUID().uuidString)/install.iso"

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .discImageNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Non-boot disc image is attached to XHCI controller, not storageDevices")
    func nonBootDiscImageOnXHCIController() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let discImagePath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: discImagePath))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = discImagePath
        config.discImageReadOnly = true
        config.bootFromDiscImage = false

        let builder = ConfigurationBuilder()
        let result = try builder.build(from: config, bundleURL: bundleURL)
        let vz = result.configuration

        // storageDevices contains only the main disk — disc is NOT here
        #expect(vz.storageDevices.count == 1)
        #expect(vz.storageDevices.first is VZVirtioBlockDeviceConfiguration)

        // XHCI controller carries the disc image as a USB device
        #expect(vz.usbControllers.count == 1)
        let xhci = try #require(vz.usbControllers.first)
        #expect(xhci.usbDevices.count == 1)
        #expect(xhci.usbDevices.first is VZUSBMassStorageDeviceConfiguration)
    }

    @Test("Non-boot disc image returns coldDiscImageDeviceInfo with matching UUID")
    func nonBootDiscImageReturnsDeviceInfo() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let discImagePath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: discImagePath))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = discImagePath
        config.discImageReadOnly = true
        config.bootFromDiscImage = false

        let builder = ConfigurationBuilder()
        let result = try builder.build(from: config, bundleURL: bundleURL)

        let info = try #require(result.coldDiscImageDeviceInfo)
        #expect(info.path == discImagePath)
        #expect(info.readOnly == true)

        // The UUID on the returned info matches the UUID on the
        // VZUSBMassStorageDeviceConfiguration sitting in usbControllers[0]
        let xhci = try #require(result.configuration.usbControllers.first)
        let usb = try #require(xhci.usbDevices.first as? VZUSBMassStorageDeviceConfiguration)
        #expect(usb.uuid == info.id)
    }

    @Test("Boot-from-disc disc returns nil coldDiscImageDeviceInfo")
    func bootDiscReturnsNilDeviceInfo() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let discImagePath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: discImagePath))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = discImagePath
        config.discImageReadOnly = true
        config.bootFromDiscImage = true

        let builder = ConfigurationBuilder()
        let result = try builder.build(from: config, bundleURL: bundleURL)

        // Boot-from-disc lives on storageDevices, not on the XHCI controller,
        // so it's NOT hot-detachable and we don't track it as a live device.
        #expect(result.coldDiscImageDeviceInfo == nil)
    }

    @Test("config.discImageDeviceUUID is honored for non-boot disc")
    func configDiscImageDeviceUUIDIsHonored() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let discImagePath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: discImagePath))

        let configuredUUID = UUID()
        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = discImagePath
        config.discImageReadOnly = true
        config.bootFromDiscImage = false
        config.discImageDeviceUUID = configuredUUID

        let builder = ConfigurationBuilder()
        let result = try builder.build(from: config, bundleURL: bundleURL)

        let info = try #require(result.coldDiscImageDeviceInfo)
        #expect(info.id == configuredUUID)

        let xhci = try #require(result.configuration.usbControllers.first)
        let usb = try #require(xhci.usbDevices.first as? VZUSBMassStorageDeviceConfiguration)
        #expect(usb.uuid == configuredUUID)
    }

    @Test("Builder falls back to fresh UUID when config.discImageDeviceUUID is nil")
    func configDiscImageDeviceUUIDFallback() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let discImagePath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: discImagePath))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = discImagePath
        config.discImageReadOnly = true
        config.discImageDeviceUUID = nil    // legacy / unmigrated config

        let builder = ConfigurationBuilder()
        let result = try builder.build(from: config, bundleURL: bundleURL)

        let info = try #require(result.coldDiscImageDeviceInfo)
        // The fallback UUID is freshly generated; we can't assert a value,
        // but it must match the one set on the configuration object.
        let xhci = try #require(result.configuration.usbControllers.first)
        let usb = try #require(xhci.usbDevices.first as? VZUSBMassStorageDeviceConfiguration)
        #expect(usb.uuid == info.id)
    }

    @Test("No disc image returns nil coldDiscImageDeviceInfo")
    func noDiscReturnsNilDeviceInfo() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        let builder = ConfigurationBuilder()
        let result = try builder.build(from: config, bundleURL: bundleURL)

        #expect(result.coldDiscImageDeviceInfo == nil)
    }

    @Test("Boot-from-disc disc image stays on storageDevices at index 0")
    func bootDiscImageStaysOnStorageDevices() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let discImagePath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: discImagePath))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = discImagePath
        config.discImageReadOnly = true
        config.bootFromDiscImage = true

        let builder = ConfigurationBuilder()
        let result = try builder.build(from: config, bundleURL: bundleURL)
        let vz = result.configuration

        // storageDevices: disc at 0, main disk at 1
        #expect(vz.storageDevices.count == 2)
        #expect(vz.storageDevices.first is VZUSBMassStorageDeviceConfiguration)
        #expect(vz.storageDevices.last is VZVirtioBlockDeviceConfiguration)

        // XHCI controller is empty — the disc lives on storageDevices for boot
        let xhci = try #require(vz.usbControllers.first)
        #expect(xhci.usbDevices.isEmpty)
    }

    @Test("Builder throws for non-writable disc image when readOnly is false")
    func builderThrowsForNonWritableDiscImage() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a read-only file to use as disc image
        let discImagePath = bundleURL.appendingPathComponent("readonly.iso").path(percentEncoded: false)
        FileManager.default.createFile(atPath: discImagePath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: discImagePath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: discImagePath) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = discImagePath
        config.discImageReadOnly = false

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .discImageNotWritable = e
            else { return false }
            return true
        }
    }

    // MARK: - Additional Disk Validation

    @Test("Builder throws for nonexistent additional disk path")
    func builderThrowsForNonexistentAdditionalDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.additionalDisks = [
            AdditionalDisk(path: "/nonexistent/\(UUID().uuidString)/data.asif", label: "Data")
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .additionalDiskNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for directory as additional disk path")
    func builderThrowsForDirectoryAsAdditionalDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let dirPath = bundleURL.appendingPathComponent("disk-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.additionalDisks = [
            AdditionalDisk(path: dirPath.path(percentEncoded: false), label: "Data")
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .additionalDiskPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for non-writable read-write additional disk")
    func builderThrowsForNonWritableAdditionalDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let diskPath = bundleURL.appendingPathComponent("readonly-data.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: diskPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: diskPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskPath) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.additionalDisks = [
            AdditionalDisk(path: diskPath, readOnly: false, label: "Data")
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .additionalDiskNotWritable = e
            else { return false }
            return true
        }
    }

    @Test("Builder accepts read-only additional disk for non-writable file")
    func builderAcceptsReadOnlyAdditionalDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let diskPath = bundleURL.appendingPathComponent("readonly-data.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: diskPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: diskPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskPath) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.additionalDisks = [
            AdditionalDisk(path: diskPath, readOnly: true, label: "Data")
        ]

        let builder = ConfigurationBuilder()
        do {
            _ = try builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            switch error {
            case .sharedDirectoryNotFound, .sharedDirectoryNotADirectory,
                .sharedDirectoryNotReadable, .sharedDirectoryNotWritable,
                .kernelNotFound, .kernelPathIsDirectory,
                .initrdNotFound, .initrdPathIsDirectory,
                .discImageNotFound, .discImagePathIsDirectory, .discImageNotWritable,
                .additionalDiskNotFound, .additionalDiskPathIsDirectory, .additionalDiskNotWritable:
                Issue.record("Unexpected path validation error: \(error)")
            case .macOSGuestRequiresAppleSilicon,
                .invalidHardwareModel, .invalidMachineIdentifier,
                .missingKernelPath, .diskImageNotFound:
                break
            }
        } catch {
            // VZ framework or other errors are expected
        }
    }

    @Test("Builder accepts read-only share for non-writable directory")
    func builderAcceptsReadOnlyShareForNonWritableDirectory() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a read-only directory
        let shareDir = bundleURL.appendingPathComponent("readonly-share")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: shareDir.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: shareDir.path(percentEncoded: false))
        }

        let config = makeLinuxConfig(sharedDirectories: [
            SharedDirectory(path: shareDir.path(percentEncoded: false), readOnly: true)
        ])

        let builder = ConfigurationBuilder()
        // Build may fail for other reasons (e.g., VZ framework validation), but must NOT fail
        // with a path validation error — shared directory validation should pass.
        do {
            _ = try builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            switch error {
            // Path validation errors — these MUST NOT occur:
            case .sharedDirectoryNotFound, .sharedDirectoryNotADirectory,
                .sharedDirectoryNotReadable, .sharedDirectoryNotWritable,
                .kernelNotFound, .kernelPathIsDirectory,
                .initrdNotFound, .initrdPathIsDirectory,
                .discImageNotFound, .discImagePathIsDirectory, .discImageNotWritable,
                .additionalDiskNotFound, .additionalDiskPathIsDirectory, .additionalDiskNotWritable:
                Issue.record("Unexpected path validation error: \(error)")
            // Non-path-validation errors — tolerated if they occur:
            case .macOSGuestRequiresAppleSilicon,
                .invalidHardwareModel, .invalidMachineIdentifier,
                .missingKernelPath, .diskImageNotFound:
                break
            }
        } catch {
            // VZ framework or other errors are expected — the test only
            // verifies that shared directory validation itself passes.
        }
    }

    // MARK: - Dangling Symlink Tests (Kernel / Initrd / Disc Image)

    @Test("Builder throws for dangling symlink as kernel path")
    func builderThrowsForDanglingSymlinkKernelPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let symlinkPath = bundleURL.appendingPathComponent("dangling-kernel").path(percentEncoded: false)
        let nonexistentTarget = bundleURL.appendingPathComponent("no-such-vmlinuz").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: nonexistentTarget)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = symlinkPath

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .kernelNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for dangling symlink as initrd path")
    func builderThrowsForDanglingSymlinkInitrdPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a real kernel file so we get past that check
        let kernelPath = bundleURL.appendingPathComponent("vmlinuz").path(percentEncoded: false)
        FileManager.default.createFile(atPath: kernelPath, contents: Data([0]))

        let symlinkPath = bundleURL.appendingPathComponent("dangling-initrd").path(percentEncoded: false)
        let nonexistentTarget = bundleURL.appendingPathComponent("no-such-initrd").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: nonexistentTarget)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = kernelPath
        config.initrdPath = symlinkPath

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .initrdNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for dangling symlink as disc image path")
    func builderThrowsForDanglingSymlinkDiscImagePath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let symlinkPath = bundleURL.appendingPathComponent("dangling-iso").path(percentEncoded: false)
        let nonexistentTarget = bundleURL.appendingPathComponent("no-such-iso").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: nonexistentTarget)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = symlinkPath

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .discImageNotFound = e
            else { return false }
            return true
        }
    }

    // MARK: - Directory-as-File Tests (Kernel / Initrd / Disc Image)

    @Test("Builder throws for directory as kernel path")
    func builderThrowsForDirectoryAsKernelPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let dirPath = bundleURL.appendingPathComponent("kernel-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = dirPath.path(percentEncoded: false)

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .kernelPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for directory as initrd path")
    func builderThrowsForDirectoryAsInitrdPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a real kernel file so we get past that check
        let kernelPath = bundleURL.appendingPathComponent("vmlinuz").path(percentEncoded: false)
        FileManager.default.createFile(atPath: kernelPath, contents: Data([0]))

        let dirPath = bundleURL.appendingPathComponent("initrd-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = kernelPath
        config.initrdPath = dirPath.path(percentEncoded: false)

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .initrdPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for directory as disc image path")
    func builderThrowsForDirectoryAsDiscImagePath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let dirPath = bundleURL.appendingPathComponent("iso-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = dirPath.path(percentEncoded: false)

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .discImagePathIsDirectory = e
            else { return false }
            return true
        }
    }

    // MARK: - Symlink-to-Directory Tests (Kernel / Initrd / Disc Image)

    @Test("Builder throws for symlink to directory as kernel path")
    func builderThrowsForSymlinkToDirectoryAsKernelPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let dirPath = bundleURL.appendingPathComponent("kernel-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-kernel-dir").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath, withDestinationPath: dirPath.path(percentEncoded: false))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = symlinkPath

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .kernelPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for symlink to directory as initrd path")
    func builderThrowsForSymlinkToDirectoryAsInitrdPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a real kernel file so we get past that check
        let kernelPath = bundleURL.appendingPathComponent("vmlinuz").path(percentEncoded: false)
        FileManager.default.createFile(atPath: kernelPath, contents: Data([0]))

        let dirPath = bundleURL.appendingPathComponent("initrd-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-initrd-dir").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath, withDestinationPath: dirPath.path(percentEncoded: false))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = kernelPath
        config.initrdPath = symlinkPath

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .initrdPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for symlink to directory as disc image path")
    func builderThrowsForSymlinkToDirectoryAsDiscImagePath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let dirPath = bundleURL.appendingPathComponent("iso-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-iso-dir").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath, withDestinationPath: dirPath.path(percentEncoded: false))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.discImagePath = symlinkPath

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .discImagePathIsDirectory = e
            else { return false }
            return true
        }
    }

    // MARK: - Happy-Path Symlink Tests

    @Test("Builder follows symlink to valid kernel file")
    func builderFollowsSymlinkToValidKernelFile() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Create a real kernel file and a symlink to it
        let realKernel = bundleURL.appendingPathComponent("vmlinuz").path(percentEncoded: false)
        FileManager.default.createFile(atPath: realKernel, contents: Data([0]))
        let symlinkPath = bundleURL.appendingPathComponent("link-to-vmlinuz").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realKernel)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel)
        config.kernelPath = symlinkPath

        let builder = ConfigurationBuilder()
        // Build may fail for other reasons (e.g., VZ framework validation), but must NOT fail
        // with a path validation error — symlink to kernel file should be resolved and accepted.
        do {
            _ = try builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            switch error {
            // Path validation errors — these MUST NOT occur:
            case .sharedDirectoryNotFound, .sharedDirectoryNotADirectory,
                .sharedDirectoryNotReadable, .sharedDirectoryNotWritable,
                .kernelNotFound, .kernelPathIsDirectory,
                .initrdNotFound, .initrdPathIsDirectory,
                .discImageNotFound, .discImagePathIsDirectory, .discImageNotWritable,
                .additionalDiskNotFound, .additionalDiskPathIsDirectory, .additionalDiskNotWritable:
                Issue.record("Unexpected path validation error: \(error)")
            // Non-path-validation errors — tolerated if they occur:
            case .macOSGuestRequiresAppleSilicon,
                .invalidHardwareModel, .invalidMachineIdentifier,
                .missingKernelPath, .diskImageNotFound:
                break
            }
        } catch {
            // VZ framework or other errors are expected
        }
    }

    // MARK: - Clipboard Sharing

    @Test("BuildResult includes clipboard pipes when clipboard sharing is enabled")
    func clipboardPipesWhenEnabled() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = makeLinuxConfig()
        config.clipboardSharingEnabled = true

        let builder = ConfigurationBuilder()
        do {
            let result = try builder.build(from: config, bundleURL: bundleURL)
            #expect(result.clipboardInputPipe != nil)
            #expect(result.clipboardOutputPipe != nil)
        } catch {
            let isVZError = (error as NSError).domain == "VZErrorDomain"
            if isVZError {
                withKnownIssue("VZ validation unavailable — assertions skipped") {
                    Issue.record("\(error)")
                }
            } else {
                Issue.record("Unexpected non-VZ error: \(error)")
            }
        }
    }

    @Test("BuildResult has nil clipboard pipes when clipboard sharing is disabled")
    func clipboardPipesWhenDisabled() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = makeLinuxConfig()
        config.clipboardSharingEnabled = false

        let builder = ConfigurationBuilder()
        do {
            let result = try builder.build(from: config, bundleURL: bundleURL)
            #expect(result.clipboardInputPipe == nil)
            #expect(result.clipboardOutputPipe == nil)
        } catch {
            let isVZError = (error as NSError).domain == "VZErrorDomain"
            if isVZError {
                withKnownIssue("VZ validation unavailable — assertions skipped") {
                    Issue.record("\(error)")
                }
            } else {
                Issue.record("Unexpected non-VZ error: \(error)")
            }
        }
    }

    // MARK: - Microphone

    @Test("Audio device includes input stream when microphone is enabled")
    func audioInputStreamWhenMicEnabled() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = makeLinuxConfig()
        config.microphoneEnabled = true

        let builder = ConfigurationBuilder()
        do {
            let result = try builder.build(from: config, bundleURL: bundleURL)
            let audioDevice = try #require(result.configuration.audioDevices.first as? VZVirtioSoundDeviceConfiguration)
            let hasInput = audioDevice.streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration }
            let hasOutput = audioDevice.streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration }
            #expect(hasInput)
            #expect(hasOutput)
        } catch {
            let isVZError = (error as NSError).domain == "VZErrorDomain"
            if isVZError {
                withKnownIssue("VZ validation unavailable — assertions skipped") {
                    Issue.record("\(error)")
                }
            } else {
                Issue.record("Unexpected non-VZ error: \(error)")
            }
        }
    }

    @Test("Audio device has output-only streams when microphone is disabled")
    func audioOutputOnlyWhenMicDisabled() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = makeLinuxConfig()
        config.microphoneEnabled = false

        let builder = ConfigurationBuilder()
        do {
            let result = try builder.build(from: config, bundleURL: bundleURL)
            let audioDevice = try #require(result.configuration.audioDevices.first as? VZVirtioSoundDeviceConfiguration)
            let hasInput = audioDevice.streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration }
            let hasOutput = audioDevice.streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration }
            #expect(!hasInput)
            #expect(hasOutput)
        } catch {
            let isVZError = (error as NSError).domain == "VZErrorDomain"
            if isVZError {
                withKnownIssue("VZ validation unavailable — assertions skipped") {
                    Issue.record("\(error)")
                }
            } else {
                Issue.record("Unexpected non-VZ error: \(error)")
            }
        }
    }
}
