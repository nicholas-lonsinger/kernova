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

    @Test("Builder throws when the default main disk file is missing")
    func efiBootWithoutDisk() throws {
        let bundleURL = try makeTempBundle()
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: makeLinuxConfig(), bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotFound = e
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
                .storageDiskNotFound, .storageDiskPathIsDirectory, .storageDiskNotWritable,
                .removableMediaNotFound, .removableMediaPathIsDirectory, .removableMediaNotWritable:
                Issue.record("Unexpected path validation error: \(error)")
            // Non-path-validation errors — tolerated if they occur:
            case .macOSGuestRequiresAppleSilicon,
                .invalidHardwareModel, .invalidMachineIdentifier,
                .missingKernelPath:
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

    // MARK: - Removable Media

    @Test("Builder throws for nonexistent removable media path")
    func builderThrowsForNonexistentRemovableMediaPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.removableMedia = [
            RemovableMediaItem(path: "/nonexistent/\(UUID().uuidString)/install.iso", readOnly: true)
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Removable media is attached to XHCI controller, not storageDevices")
    func removableMediaOnXHCIController() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let isoPath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: isoPath))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.removableMedia = [RemovableMediaItem(path: isoPath, readOnly: true)]

        let builder = ConfigurationBuilder()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
        let vz = result.configuration

        #expect(vz.storageDevices.count == 1)
        #expect(vz.storageDevices.first is VZVirtioBlockDeviceConfiguration)
        let xhci = try #require(vz.usbControllers.first)
        #expect(xhci.usbDevices.count == 1)
        #expect(xhci.usbDevices.first is VZUSBMassStorageDeviceConfiguration)
    }

    @Test("Removable media returns coldRemovableMedia infos with matching UUIDs")
    func removableMediaReturnsDeviceInfos() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let isoPath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: isoPath))

        let configuredUUID = UUID()
        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.removableMedia = [
            RemovableMediaItem(id: configuredUUID, path: isoPath, readOnly: true)
        ]

        let builder = ConfigurationBuilder()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)

        #expect(result.coldRemovableMedia.count == 1)
        let info = try #require(result.coldRemovableMedia.first)
        #expect(info.id == configuredUUID)
        #expect(info.path == isoPath)
        #expect(info.readOnly == true)

        let xhci = try #require(result.configuration.usbControllers.first)
        let usb = try #require(xhci.usbDevices.first as? VZUSBMassStorageDeviceConfiguration)
        #expect(usb.uuid == configuredUUID)
    }

    @Test("No removable media returns empty coldRemovableMedia")
    func noRemovableMediaReturnsEmpty() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        let builder = ConfigurationBuilder()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
        #expect(result.coldRemovableMedia.isEmpty)
    }

    @Test("Builder throws for non-writable removable media when readOnly is false")
    func builderThrowsForNonWritableRemovableMedia() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let isoPath = bundleURL.appendingPathComponent("readonly.iso").path(percentEncoded: false)
        FileManager.default.createFile(atPath: isoPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: isoPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: isoPath) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.removableMedia = [RemovableMediaItem(path: isoPath, readOnly: false)]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaNotWritable = e
            else { return false }
            return true
        }
    }

    // MARK: - Storage Disks

    @Test("Default storage disks list synthesizes the main disk at index 0")
    func defaultStorageDisksSynthesizesMainDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        let builder = ConfigurationBuilder()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)

        #expect(result.configuration.storageDevices.count == 1)
        #expect(result.configuration.storageDevices.first is VZVirtioBlockDeviceConfiguration)
    }

    @Test("Storage disks list orders devices on storageDevices by position")
    func storageDisksOrderingPreserved() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let isoPath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: isoPath))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(path: isoPath, readOnly: true, label: "Installer"),
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
        ]

        let builder = ConfigurationBuilder()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)

        // Position [0] is the ISO (USB mass storage), [1] is virtio main disk.
        #expect(result.configuration.storageDevices.count == 2)
        #expect(result.configuration.storageDevices.first is VZUSBMassStorageDeviceConfiguration)
        #expect(result.configuration.storageDevices.last is VZVirtioBlockDeviceConfiguration)

        // ISO does NOT live on XHCI — it's on storageDevices for boot.
        let xhci = try #require(result.configuration.usbControllers.first)
        #expect(xhci.usbDevices.isEmpty)
    }

    @Test("StorageDisk.defaultKind dispatches by file extension")
    func defaultKindByExtension() {
        #expect(StorageDisk.defaultKind(forPath: "/tmp/install.iso") == .usbMassStorage)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/Ubuntu.ISO") == .usbMassStorage)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/installer.dmg") == .usbMassStorage)
        #expect(StorageDisk.defaultKind(forPath: "Disk.asif") == .virtio)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/data.img") == .virtio)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/data.qcow2") == .virtio)
        #expect(StorageDisk.defaultKind(forPath: "/tmp/no-ext") == .virtio)
    }

    @Test("Builder throws for nonexistent external storage disk")
    func builderThrowsForNonexistentStorageDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
            StorageDisk(
                path: "/nonexistent/\(UUID().uuidString)/data.asif",
                readOnly: false,
                label: "Data",
                isInternal: false,
                kind: .virtio
            ),
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for directory as external storage disk")
    func builderThrowsForDirectoryAsStorageDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let dirPath = bundleURL.appendingPathComponent("disk-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
            StorageDisk(
                path: dirPath.path(percentEncoded: false),
                readOnly: false,
                label: "Data",
                isInternal: false,
                kind: .virtio
            ),
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for non-writable read-write external storage disk")
    func builderThrowsForNonWritableStorageDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let diskPath = bundleURL.appendingPathComponent("readonly-data.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: diskPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: diskPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskPath) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
            StorageDisk(path: diskPath, readOnly: false, label: "Data", isInternal: false, kind: .virtio),
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotWritable = e
            else { return false }
            return true
        }
    }

    @Test("Builder accepts read-only storage disk for non-writable file")
    func builderAcceptsReadOnlyStorageDisk() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let diskPath = bundleURL.appendingPathComponent("readonly-data.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: diskPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: diskPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskPath) }

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
            StorageDisk(path: diskPath, readOnly: true, label: "Data", isInternal: false, kind: .virtio),
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
                .storageDiskNotFound, .storageDiskPathIsDirectory, .storageDiskNotWritable,
                .removableMediaNotFound, .removableMediaPathIsDirectory, .removableMediaNotWritable:
                Issue.record("Unexpected path validation error: \(error)")
            case .macOSGuestRequiresAppleSilicon,
                .invalidHardwareModel, .invalidMachineIdentifier,
                .missingKernelPath:
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
                .storageDiskNotFound, .storageDiskPathIsDirectory, .storageDiskNotWritable,
                .removableMediaNotFound, .removableMediaPathIsDirectory, .removableMediaNotWritable:
                Issue.record("Unexpected path validation error: \(error)")
            // Non-path-validation errors — tolerated if they occur:
            case .macOSGuestRequiresAppleSilicon,
                .invalidHardwareModel, .invalidMachineIdentifier,
                .missingKernelPath:
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

    @Test("Builder throws for dangling symlink as removable media path")
    func builderThrowsForDanglingSymlinkRemovableMediaPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let symlinkPath = bundleURL.appendingPathComponent("dangling-iso").path(percentEncoded: false)
        let nonexistentTarget = bundleURL.appendingPathComponent("no-such-iso").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: nonexistentTarget)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.removableMedia = [RemovableMediaItem(path: symlinkPath, readOnly: true)]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaNotFound = e
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

    @Test("Builder throws for directory as removable media path")
    func builderThrowsForDirectoryAsRemovableMediaPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let dirPath = bundleURL.appendingPathComponent("iso-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.removableMedia = [
            RemovableMediaItem(path: dirPath.path(percentEncoded: false), readOnly: true)
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaPathIsDirectory = e
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

    @Test("Builder throws for symlink to directory as removable media path")
    func builderThrowsForSymlinkToDirectoryAsRemovableMediaPath() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let dirPath = bundleURL.appendingPathComponent("iso-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-iso-dir").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath, withDestinationPath: dirPath.path(percentEncoded: false))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.removableMedia = [RemovableMediaItem(path: symlinkPath, readOnly: true)]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaPathIsDirectory = e
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
                .storageDiskNotFound, .storageDiskPathIsDirectory, .storageDiskNotWritable,
                .removableMediaNotFound, .removableMediaPathIsDirectory, .removableMediaNotWritable:
                Issue.record("Unexpected path validation error: \(error)")
            // Non-path-validation errors — tolerated if they occur:
            case .macOSGuestRequiresAppleSilicon,
                .invalidHardwareModel, .invalidMachineIdentifier,
                .missingKernelPath:
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

    // MARK: - Audio

    /// Builds `config` and hands its audio-device stream summary to `assertions`.
    ///
    /// Uses `assemble(validate: false)` so the assertions run even on CI runners
    /// without virtualization (where `vzConfig.validate()` would throw); the
    /// audio device is built in `assemble` regardless of the `validate` flag.
    private func withAudioStreams(
        _ config: VMConfiguration,
        _ assertions: (_ hasInput: Bool, _ hasOutput: Bool, _ deviceCount: Int) -> Void
    ) throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let result = try ConfigurationBuilder().assemble(from: config, bundleURL: bundleURL, validate: false)
        let streams = result.configuration.audioDevices
            .compactMap { $0 as? VZVirtioSoundDeviceConfiguration }
            .flatMap(\.streams)
        assertions(
            streams.contains { $0 is VZVirtioSoundDeviceInputStreamConfiguration },
            streams.contains { $0 is VZVirtioSoundDeviceOutputStreamConfiguration },
            result.configuration.audioDevices.count
        )
    }

    @Test(
        "Audio streams match the input/output toggles; the device is omitted when both are off",
        arguments: [
            (input: true, output: true, hasInput: true, hasOutput: true, deviceCount: 1),
            (input: true, output: false, hasInput: true, hasOutput: false, deviceCount: 1),
            (input: false, output: true, hasInput: false, hasOutput: true, deviceCount: 1),
            (input: false, output: false, hasInput: false, hasOutput: false, deviceCount: 0),
        ]
    )
    func audioStreamsMatchToggles(
        _ c: (input: Bool, output: Bool, hasInput: Bool, hasOutput: Bool, deviceCount: Int)
    ) throws {
        var config = makeLinuxConfig()
        config.audioInputEnabled = c.input
        config.audioOutputEnabled = c.output
        try withAudioStreams(config) { hasInput, hasOutput, deviceCount in
            #expect(hasInput == c.hasInput)
            #expect(hasOutput == c.hasOutput)
            #expect(deviceCount == c.deviceCount)
        }
    }

    // MARK: - Path-Traversal Containment

    @Test("Internal storage disk path with .. escape is rejected as storageDiskNotFound")
    func internalStorageDiskRejectsPathTraversal() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Marking the entry `isInternal: true` opts into bundle-containment
        // validation. A `..` segment that resolves outside the bundle must
        // be rejected before the framework ever opens the file.
        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(
                path: "../escape/passwd",
                readOnly: true,
                label: "evil",
                isInternal: true,
                kind: .virtio
            )
        ]

        let builder = ConfigurationBuilder()
        #expect {
            try builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotFound = e
            else { return false }
            return true
        }
    }

    // MARK: - Synthetic Main-Disk Identity

    @Test("defaultMainDisk produces a stable UUID for the same bundle URL")
    func defaultMainDiskUUIDIsStableAcrossCalls() {
        let bundleURL = URL(fileURLWithPath: "/tmp/kernova-test-stable.kernova")
        let layout = VMBundleLayout(bundleURL: bundleURL)
        let first = ConfigurationBuilder.defaultMainDisk(layout: layout)
        let second = ConfigurationBuilder.defaultMainDisk(layout: layout)
        #expect(first.id == second.id)
    }

    @Test("defaultMainDisk produces distinct UUIDs for distinct bundle URLs")
    func defaultMainDiskUUIDsDifferAcrossBundles() {
        let aLayout = VMBundleLayout(
            bundleURL: URL(fileURLWithPath: "/tmp/kernova-test-a.kernova"))
        let bLayout = VMBundleLayout(
            bundleURL: URL(fileURLWithPath: "/tmp/kernova-test-b.kernova"))
        #expect(
            ConfigurationBuilder.defaultMainDisk(layout: aLayout).id
                != ConfigurationBuilder.defaultMainDisk(layout: bLayout).id)
    }

    // MARK: - Symlink Resolution for External Storage Disks

    @Test("External storage disk via symlink attaches to symlink target, not symlink path")
    func externalStorageDiskFollowsSymlink() throws {
        let bundleURL = try makeTempBundle(withDisk: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Real file in a scratch directory outside the bundle, plus a
        // symlink to it. The builder must hand VZ the resolved target
        // URL so the attachment doesn't depend on the symlink surviving.
        let scratchDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        // Need a 1 MB zeroed raw disk image — VZ rejects smaller / empty
        // files as "disk image format not recognized" inside the
        // `VZDiskImageStorageDeviceAttachment` constructor.
        let realPath = scratchDir.appendingPathComponent("real.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: realPath, contents: Data(count: 1_048_576))
        let symlinkPath = scratchDir.appendingPathComponent("symlink.asif").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realPath)

        // The bundle's own Disk.asif also needs to be sized for the same
        // reason; replace the zero-byte stub created by makeTempBundle.
        let mainDiskURL = VMBundleLayout(bundleURL: bundleURL).diskImageURL
        try? FileManager.default.removeItem(at: mainDiskURL)
        FileManager.default.createFile(
            atPath: mainDiskURL.path(percentEncoded: false), contents: Data(count: 1_048_576))

        var config = VMConfiguration(name: "Test Linux", guestOS: .linux, bootMode: .efi)
        config.storageDisks = [
            StorageDisk(
                path: "Disk.asif", readOnly: false, label: "Main Disk",
                isInternal: true, kind: .virtio),
            StorageDisk(
                path: symlinkPath, readOnly: true, label: "Via Symlink",
                isInternal: false, kind: .virtio),
        ]

        let builder = ConfigurationBuilder()
        // `assemble(validate: false)` skips VZ's "is this a real disk image?"
        // check, which would otherwise reject the tiny stub file.
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
        let storageDevices = result.configuration.storageDevices
        #expect(storageDevices.count == 2)
        let viaSymlink = try #require(storageDevices.last as? VZVirtioBlockDeviceConfiguration)
        let attachment = try #require(viaSymlink.attachment as? VZDiskImageStorageDeviceAttachment)

        let attachedPath = attachment.url.standardizedFileURL.path(percentEncoded: false)
        let realCanonical = URL(fileURLWithPath: realPath).standardizedFileURL.path(percentEncoded: false)
        #expect(
            attachedPath == realCanonical,
            "Attachment URL should be the symlink target. Got: \(attachedPath), expected: \(realCanonical)")
    }
}
