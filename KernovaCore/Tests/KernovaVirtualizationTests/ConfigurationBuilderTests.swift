import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing
import Virtualization

@testable import KernovaCore
@testable import KernovaCoreTestSupport
@testable import KernovaVirtualization
@testable import KernovaVirtualizationTestSupport

@Suite("ConfigurationBuilder Tests", .caseScoped)
struct ConfigurationBuilderTests {
    private let scratch = TestScratchDirectory(prefix: "ConfigurationBuilderTests")

    init() throws {
        try FileManager.default.createDirectory(at: scratch.url, withIntermediateDirectories: true)
    }

    // MARK: - Helpers

    /// Fails the test when `error` is a path-validation refusal.
    ///
    /// For the happy-path tests, which tolerate any other builder error: VZ
    /// validation legitimately fails on a host without virtualization, and only
    /// the path handling is under test.
    private func expectNoPathValidationError(_ error: ConfigurationBuilderError) {
        switch error {
        case .sharedDirectoryNotFound, .sharedDirectoryNotADirectory,
            .sharedDirectoryNotReadable, .sharedDirectoryNotWritable,
            .kernelNotFound, .kernelPathIsDirectory,
            .initrdNotFound, .initrdPathIsDirectory,
            .storageDiskNotFound, .storageDiskPathIsDirectory, .storageDiskNotWritable,
            .removableMediaNotFound, .removableMediaPathIsDirectory, .removableMediaNotWritable:
            Issue.record("Unexpected path validation error: \(error)")
        case .efiVariableStoreMissing:
            Issue.record("The fixture bundle holds no EFI variable store")
        case .invalidHardwareModel, .invalidMachineIdentifier, .missingKernelPath,
            .storageDiskAttachFailed, .removableMediaAttachFailed,
            .networkNotEntitled:
            break
        }
    }

    /// Returns a Linux/EFI config set to bridged networking.
    private func makeBridgedConfig() -> VMConfiguration {
        VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            networkEnabled: true,
            networkMode: .bridged)
    }

    /// Returns a Linux/EFI config set to host-only networking.
    private func makeHostOnlyConfig() -> VMConfiguration {
        VMConfiguration(
            name: "Test Linux",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize,
            networkEnabled: true,
            networkMode: .hostOnly)
    }

    // MARK: - Boot Validation

    @Test("Builder throws when the default main disk file is missing")
    func efiBootWithoutDisk() async throws {
        let bundleURL = try scratch.makeEngineBundle()

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: VMConfiguration.testLinux(), bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotFound = e
            else { return false }
            return true
        }
    }

    @Test("An EFI build over a bundle with no variable store fails naming it, and ensuring the store fixes it")
    func efiBootWithoutVariableStore() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true, withEFIVariableStore: false)
        let builder = ConfigurationBuilder.testing()
        let storeURL = VMBundleLayout(bundleURL: bundleURL).efiVariableStoreURL

        #expect {
            try builder.assemble(from: VMConfiguration.testLinux(), bundleURL: bundleURL, validate: false)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError, case .efiVariableStoreMissing = e
            else { return false }
            return true
        }
        // The builder only reads the bundle.
        #expect(!FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))

        try VirtualizationPlatformFiles().ensureEFIVariableStore(bundleURL: bundleURL)

        #expect(FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)))
        _ = try builder.assemble(from: VMConfiguration.testLinux(), bundleURL: bundleURL, validate: false)
    }

    @Test("Builder throws for kernel boot without kernel path")
    func kernelBootWithoutPath() async throws {
        let bundleURL = try scratch.makeEngineBundle()

        let config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .missingKernelPath = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for macOS boot without hardware model")
    func macOSBootWithoutHardwareModel() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let config = VMConfiguration(
            name: "Test macOS", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        let builder = ConfigurationBuilder.testing()
        await #expect(throws: (any Error).self) {
            try await builder.build(from: config, bundleURL: bundleURL)
        }
    }

    // MARK: - Shared Directory Validation

    @Test("Builder throws for missing shared directory path")
    func builderThrowsForMissingSharedDirectoryPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let share = SharedDirectory(path: "/nonexistent/path/\(UUID().uuidString)")
        let config = VMConfiguration.testLinux(sharedDirectories: [share])

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            // The entry is named the way the Sharing pane names its row.
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotFound(let id, let path, let label) = e
            else { return false }
            return id == share.id && path == share.path && label == share.displayName
        }
    }

    @Test("Builder throws for shared path that is a file")
    func builderThrowsForSharedPathThatIsAFile() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a file (not a directory) to use as the shared path
        let filePath = bundleURL.appendingPathComponent("not-a-directory").path(percentEncoded: false)
        FileManager.default.createFile(atPath: filePath, contents: nil)

        let config = VMConfiguration.testLinux(sharedDirectories: [
            SharedDirectory(path: filePath)
        ])

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotADirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for non-writable read-write share")
    func builderThrowsForNonWritableReadWriteShare() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a read-only directory
        let shareDir = bundleURL.appendingPathComponent("readonly-share")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: shareDir.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: shareDir.path(percentEncoded: false))
        }

        let config = VMConfiguration.testLinux(sharedDirectories: [
            SharedDirectory(path: shareDir.path(percentEncoded: false), readOnly: false)
        ])

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotWritable(_, _, let label) = e
            else { return false }
            return label == "readonly-share"
        }
    }

    @Test("Builder throws for dangling symlink as shared directory")
    func builderThrowsForDanglingSymlinkSharedDirectory() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a symlink pointing to a nonexistent target
        let symlinkPath = bundleURL.appendingPathComponent("dangling-link").path(percentEncoded: false)
        let nonexistentTarget = bundleURL.appendingPathComponent("no-such-dir").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: nonexistentTarget)

        let config = VMConfiguration.testLinux(sharedDirectories: [
            SharedDirectory(path: symlinkPath)
        ])

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for symlink to file as shared directory")
    func builderThrowsForSymlinkToFileAsSharedDirectory() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a regular file, then symlink to it
        let filePath = bundleURL.appendingPathComponent("a-file").path(percentEncoded: false)
        FileManager.default.createFile(atPath: filePath, contents: nil)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-file").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: filePath)

        let config = VMConfiguration.testLinux(sharedDirectories: [
            SharedDirectory(path: symlinkPath)
        ])

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotADirectory = e
            else { return false }
            return true
        }
    }

    /// The swap re-validates a served entry at the folder the device serves,
    /// which is the symlink's target, while the error names the row the
    /// Sharing pane shows.
    @Test("A live swap's refusal of a served folder names the entry, not its resolved path")
    func liveSwapRefusalNamesTheEntry() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let target = bundleURL.appendingPathComponent("served-target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let targetPath = target.path(percentEncoded: false)
        let linkPath = bundleURL.appendingPathComponent("Projects").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
        var share = SharedDirectory(path: linkPath, readOnly: true)
        let serving = try MacOSDirectoryShare.make(for: [share])
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: targetPath)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetPath)
        }
        share.readOnly = false

        #expect {
            try MacOSDirectoryShare.make(for: [share], serving: serving)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .sharedDirectoryNotWritable(let id, _, let label) = e
            else { return false }
            return id == share.id && label == "Projects"
        }
    }

    @Test("Builder follows symlink to valid shared directory")
    func builderFollowsSymlinkToValidSharedDirectory() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a real directory and a symlink to it
        let realDir = bundleURL.appendingPathComponent("real-share")
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-share").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath, withDestinationPath: realDir.path(percentEncoded: false))

        let config = VMConfiguration.testLinux(sharedDirectories: [
            SharedDirectory(path: symlinkPath, readOnly: true)
        ])

        let builder = ConfigurationBuilder.testing()
        // Build may fail for other reasons (e.g., VZ framework validation), but must NOT fail
        // with a path validation error — symlink should be resolved and accepted.
        do {
            _ = try await builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            expectNoPathValidationError(error)
        } catch {
            // VZ framework or other errors are expected
        }
    }

    // MARK: - Kernel / Initrd Path Validation

    @Test("Builder throws for nonexistent kernel path")
    func builderThrowsForNonexistentKernelPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.kernelPath = "/nonexistent/\(UUID().uuidString)/vmlinuz"

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .kernelNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for nonexistent initrd path")
    func builderThrowsForNonexistentInitrdPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a real kernel file so we get past that check
        let kernelPath = bundleURL.appendingPathComponent("vmlinuz").path(percentEncoded: false)
        FileManager.default.createFile(atPath: kernelPath, contents: Data([0]))

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.kernelPath = kernelPath
        config.initrdPath = "/nonexistent/\(UUID().uuidString)/initrd.img"

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .initrdNotFound = e
            else { return false }
            return true
        }
    }

    // MARK: - Removable Media

    @Test("Builder throws for nonexistent removable media path")
    func builderThrowsForNonexistentRemovableMediaPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [
            RemovableMediaItem(path: "/nonexistent/\(UUID().uuidString)/install.iso", readOnly: true)
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Attach failure for removable media throws typed error with item identity")
    func removableMediaAttachFailureThrowsTypedError() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // 100 bytes is not a multiple of the 512-byte sector size, so
        // VZDiskImageStorageDeviceAttachment rejects the file even though it
        // exists and is readable — the same attach-time failure shape as a
        // sandbox-denied open of a stale path.
        let isoPath = bundleURL.appendingPathComponent("bad.iso").path(percentEncoded: false)
        try Data(count: 100).write(to: URL(fileURLWithPath: isoPath))

        let itemID = UUID()
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [
            RemovableMediaItem(id: itemID, path: isoPath, readOnly: true, label: "Bad ISO")
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaAttachFailed(let id, let path, let label, _) = e
            else { return false }
            return id == itemID && path == isoPath && label == "Bad ISO"
        }
    }

    @Test("Attach failure for external storage disk throws typed error with item identity")
    func storageDiskAttachFailureThrowsTypedError() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Unaligned size — see the removable-media counterpart above.
        let diskPath = bundleURL.appendingPathComponent("bad.img").path(percentEncoded: false)
        try Data(count: 100).write(to: URL(fileURLWithPath: diskPath))

        let diskID = UUID()
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: bundleURL)),
            StorageDisk(
                id: diskID, path: diskPath, readOnly: true, label: "Bad Disk",
                isInternal: false, kind: .virtio),
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskAttachFailed(let id, let path, let label, _) = e
            else { return false }
            return id == diskID && path == diskPath && label == "Bad Disk"
        }
    }

    @Test("Removable media is attached to XHCI controller, not storageDevices")
    func removableMediaOnXHCIController() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let isoPath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: isoPath))

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [RemovableMediaItem(path: isoPath, readOnly: true)]

        let builder = ConfigurationBuilder.testing()
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
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let isoPath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: isoPath))

        let configuredUUID = UUID()
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [
            RemovableMediaItem(id: configuredUUID, path: isoPath, readOnly: true)
        ]

        let builder = ConfigurationBuilder.testing()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)

        #expect(result.products.coldRemovableMedia.count == 1)
        let info = try #require(result.products.coldRemovableMedia.first)
        #expect(info.id == configuredUUID)
        #expect(info.path == isoPath)
        #expect(info.readOnly == true)

        let xhci = try #require(result.configuration.usbControllers.first)
        let usb = try #require(xhci.usbDevices.first as? VZUSBMassStorageDeviceConfiguration)
        #expect(usb.uuid == configuredUUID)
    }

    @Test("No removable media returns empty coldRemovableMedia")
    func noRemovableMediaReturnsEmpty() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let builder = ConfigurationBuilder.testing()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
        #expect(result.products.coldRemovableMedia.isEmpty)
    }

    @Test("Builder throws for non-writable removable media when readOnly is false")
    func builderThrowsForNonWritableRemovableMedia() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let isoPath = bundleURL.appendingPathComponent("readonly.iso").path(percentEncoded: false)
        FileManager.default.createFile(atPath: isoPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: isoPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: isoPath) }

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [RemovableMediaItem(path: isoPath, readOnly: false)]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
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
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let builder = ConfigurationBuilder.testing()
        let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)

        #expect(result.configuration.storageDevices.count == 1)
        #expect(result.configuration.storageDevices.first is VZVirtioBlockDeviceConfiguration)
    }

    @Test("Storage disks list orders devices on storageDevices by position")
    func storageDisksOrderingPreserved() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let isoPath = bundleURL.appendingPathComponent("install.iso").path(percentEncoded: false)
        try Data().write(to: URL(fileURLWithPath: isoPath))

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk(path: isoPath, readOnly: true, label: "Installer"),
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
        ]

        let builder = ConfigurationBuilder.testing()
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
    func builderThrowsForNonexistentStorageDisk() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
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

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotFound = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for directory as external storage disk")
    func builderThrowsForDirectoryAsStorageDisk() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let dirPath = bundleURL.appendingPathComponent("disk-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
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

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for non-writable read-write external storage disk")
    func builderThrowsForNonWritableStorageDisk() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let diskPath = bundleURL.appendingPathComponent("readonly-data.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: diskPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: diskPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskPath) }

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
            StorageDisk(path: diskPath, readOnly: false, label: "Data", isInternal: false, kind: .virtio),
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotWritable = e
            else { return false }
            return true
        }
    }

    @Test("Builder accepts read-only storage disk for non-writable file")
    func builderAcceptsReadOnlyStorageDisk() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let diskPath = bundleURL.appendingPathComponent("readonly-data.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: diskPath, contents: Data([0]))
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: diskPath)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: diskPath) }

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio),
            StorageDisk(path: diskPath, readOnly: true, label: "Data", isInternal: false, kind: .virtio),
        ]

        let builder = ConfigurationBuilder.testing()
        do {
            _ = try await builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            expectNoPathValidationError(error)
        } catch {
            // VZ framework or other errors are expected
        }
    }

    @Test("Builder accepts read-only share for non-writable directory")
    func builderAcceptsReadOnlyShareForNonWritableDirectory() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a read-only directory
        let shareDir = bundleURL.appendingPathComponent("readonly-share")
        try FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: shareDir.path(percentEncoded: false))
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: shareDir.path(percentEncoded: false))
        }

        let config = VMConfiguration.testLinux(sharedDirectories: [
            SharedDirectory(path: shareDir.path(percentEncoded: false), readOnly: true)
        ])

        let builder = ConfigurationBuilder.testing()
        // Build may fail for other reasons (e.g., VZ framework validation), but must NOT fail
        // with a path validation error — shared directory validation should pass.
        do {
            _ = try await builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            expectNoPathValidationError(error)
        } catch {
            // VZ framework or other errors are expected — the test only
            // verifies that shared directory validation itself passes.
        }
    }

    // MARK: - Dangling Symlink Tests (Kernel / Initrd / Disk Image)

    // MARK: - Directory-as-File Tests (Kernel / Initrd / Disk Image)

    @Test("Builder throws for directory as kernel path")
    func builderThrowsForDirectoryAsKernelPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let dirPath = bundleURL.appendingPathComponent("kernel-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.kernelPath = dirPath.path(percentEncoded: false)

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .kernelPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for directory as initrd path")
    func builderThrowsForDirectoryAsInitrdPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a real kernel file so we get past that check
        let kernelPath = bundleURL.appendingPathComponent("vmlinuz").path(percentEncoded: false)
        FileManager.default.createFile(atPath: kernelPath, contents: Data([0]))

        let dirPath = bundleURL.appendingPathComponent("initrd-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.kernelPath = kernelPath
        config.initrdPath = dirPath.path(percentEncoded: false)

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .initrdPathIsDirectory = e
            else { return false }
            return true
        }
    }

    @Test("Builder throws for directory as removable media path")
    func builderThrowsForDirectoryAsRemovableMediaPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let dirPath = bundleURL.appendingPathComponent("iso-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.removableMedia = [
            RemovableMediaItem(path: dirPath.path(percentEncoded: false), readOnly: true)
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .removableMediaPathIsDirectory = e
            else { return false }
            return true
        }
    }

    // MARK: - Symlink-to-Directory Tests (Kernel / Initrd / Disk Image)

    @Test("Builder throws for symlink to directory as kernel path")
    func builderThrowsForSymlinkToDirectoryAsKernelPath() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let dirPath = bundleURL.appendingPathComponent("kernel-dir")
        try FileManager.default.createDirectory(at: dirPath, withIntermediateDirectories: true)
        let symlinkPath = bundleURL.appendingPathComponent("link-to-kernel-dir").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkPath, withDestinationPath: dirPath.path(percentEncoded: false))

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.kernelPath = symlinkPath

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .kernelPathIsDirectory = e
            else { return false }
            return true
        }
    }

    // MARK: - Happy-Path Symlink Tests

    @Test("Builder follows symlink to valid kernel file")
    func builderFollowsSymlinkToValidKernelFile() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Create a real kernel file and a symlink to it
        let realKernel = bundleURL.appendingPathComponent("vmlinuz").path(percentEncoded: false)
        FileManager.default.createFile(atPath: realKernel, contents: Data([0]))
        let symlinkPath = bundleURL.appendingPathComponent("link-to-vmlinuz").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realKernel)

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .linuxKernel, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.kernelPath = symlinkPath

        let builder = ConfigurationBuilder.testing()
        // Build may fail for other reasons (e.g., VZ framework validation), but must NOT fail
        // with a path validation error — symlink to kernel file should be resolved and accepted.
        do {
            _ = try await builder.build(from: config, bundleURL: bundleURL)
        } catch let error as ConfigurationBuilderError {
            expectNoPathValidationError(error)
        } catch {
            // VZ framework or other errors are expected
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
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let result = try ConfigurationBuilder.testing().assemble(from: config, bundleURL: bundleURL, validate: false)
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
        var config = VMConfiguration.testLinux()
        config.audioInputEnabled = c.input
        config.audioOutputEnabled = c.output
        try withAudioStreams(config) { hasInput, hasOutput, deviceCount in
            #expect(hasInput == c.hasInput)
            #expect(hasOutput == c.hasOutput)
            #expect(deviceCount == c.deviceCount)
        }
    }

    // MARK: - Network

    /// Assembles `config` and returns its network devices.
    ///
    /// `assemble(validate: false)` for the same reason as the audio helper: the
    /// device is built regardless of the flag, and CI runners can't validate.
    private func networkDevices(for config: VMConfiguration) throws
        -> [VZNetworkDeviceConfiguration]
    {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        return try ConfigurationBuilder.testing()
            .assemble(from: config, bundleURL: bundleURL, validate: false)
            .configuration.networkDevices
    }

    @Test("Mode None configures no network device at all")
    func networkDisabledOmitsTheDevice() throws {
        var config = VMConfiguration.testLinux()
        config.networkEnabled = false
        // A bridged mode left behind by an earlier choice must not resurrect the
        // device: `networkEnabled == false` is the None mode.
        config.networkMode = .bridged
        #expect(try networkDevices(for: config).isEmpty)
    }

    @Test("NAT without the entitlement attaches one virtio device over NAT")
    func natModeAttachesNAT() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let networks = ScriptedVmnetNetworks()
        let builder = ConfigurationBuilder.testing(networks, entitlements: .unentitled)

        let devices = try builder.assemble(
            from: VMConfiguration.testLinux(), bundleURL: bundleURL, validate: false
        ).configuration.networkDevices
        #expect(devices.count == 1)
        let device = try #require(devices.first as? VZVirtioNetworkDeviceConfiguration)
        #expect(device.attachment is VZNATNetworkDeviceAttachment)
        #expect(networks.operations.createdKinds.isEmpty)
    }

    @Test("NAT with the entitlement attaches the app-managed NAT network")
    func entitledNATModeAttachesTheManagedNetwork() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let networks = ScriptedVmnetNetworks()
        let attachments = MockVmnetAttachments()
        let builder = ConfigurationBuilder.testing(networks, attachments: attachments, entitlements: .entitled)

        let devices = try builder.assemble(
            from: VMConfiguration.testLinux(), bundleURL: bundleURL, validate: false
        ).configuration.networkDevices
        #expect(devices.count == 1)
        #expect(devices[0].attachment.map(ObjectIdentifier.init) == attachments.madeIdentities.last)
        #expect(networks.operations.createdKinds == [.nat])
        #expect(networks.service.ipv4Subnet(for: .common(.nat)) != nil)
    }

    @Test("A NAT network that cannot be materialized builds the device detached")
    func entitledNATModeWithoutANetworkBuildsDetached() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let networks = ScriptedVmnetNetworks()
        networks.operations.setCreateNetworkError(TestFailure("vmnet refused"))
        let builder = ConfigurationBuilder.testing(networks, entitlements: .entitled)

        // The boot (and a restore from saved state, which rebuilds the same
        // configuration) must succeed; attachment recovery reattaches later.
        let devices = try builder.assemble(
            from: VMConfiguration.testLinux(), bundleURL: bundleURL, validate: false
        ).configuration.networkDevices
        #expect(devices.count == 1)
        #expect(devices[0].attachment == nil)
    }

    @Test("A configured MAC address reaches the network device")
    func macAddressReachesTheDevice() throws {
        var config = VMConfiguration.testLinux()
        config.macAddress = "aa:bb:cc:dd:ee:ff"
        let device = try #require(try networkDevices(for: config).first)
        #expect(device.macAddress.string == "aa:bb:cc:dd:ee:ff")
    }

    @Test("An unparsable MAC address leaves VZ's generated one in place")
    func invalidMACAddressIsIgnored() throws {
        var config = VMConfiguration.testLinux()
        config.macAddress = "not-a-mac"
        let device = try #require(try networkDevices(for: config).first)
        #expect(device.macAddress.string != "not-a-mac")
    }

    @Test("Bridged mode with no bridgeable host interface builds the device detached")
    func bridgedModeWithoutAnInterfaceBuildsDetached() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var builder = ConfigurationBuilder.testing(entitlements: .entitled)
        builder.bridgedInterfaces = MockBridgedInterfaceProvider()

        // The boot (and a restore from saved state, which rebuilds the same
        // configuration) must succeed; attachment recovery reattaches later.
        let devices = try builder.assemble(
            from: makeBridgedConfig(), bundleURL: bundleURL, validate: false
        ).configuration.networkDevices
        #expect(devices.count == 1)
        #expect(devices[0].attachment == nil)
    }

    @Test("Bridged mode in a build without the entitlement names the entitlement, not the interface")
    func bridgedModeWithoutTheEntitlementThrows() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var builder = ConfigurationBuilder.testing(entitlements: .unentitled)
        builder.bridgedInterfaces = MockBridgedInterfaceProvider()

        #expect {
            try builder.assemble(from: makeBridgedConfig(), bundleURL: bundleURL, validate: false)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .networkNotEntitled(.bridged) = e
            else { return false }
            return true
        }
    }

    @Test("Host Only mode attaches the app-managed network")
    func hostOnlyModeAttachesTheManagedNetwork() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let networks = ScriptedVmnetNetworks()
        let attachments = MockVmnetAttachments()
        let builder = ConfigurationBuilder.testing(networks, attachments: attachments, entitlements: .entitled)

        let devices = try builder.assemble(
            from: makeHostOnlyConfig(), bundleURL: bundleURL, validate: false
        ).configuration.networkDevices
        #expect(devices.count == 1)
        #expect(devices[0].attachment.map(ObjectIdentifier.init) == attachments.madeIdentities.last)
        #expect(networks.operations.createdKinds == [.hostOnly])
        #expect(networks.service.ipv4Subnet(for: .common(.hostOnly)) != nil)
    }

    @Test("Host Only mode in a build without the entitlement names the entitlement")
    func hostOnlyModeWithoutTheEntitlementThrows() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let networks = ScriptedVmnetNetworks()
        let builder = ConfigurationBuilder.testing(networks, entitlements: .unentitled)

        #expect {
            try builder.assemble(from: makeHostOnlyConfig(), bundleURL: bundleURL, validate: false)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .networkNotEntitled(.vmnet(let id)) = e, id == VmnetNetworkID.common(.hostOnly)
            else { return false }
            return true
        }
        // The entitlement is checked before the network is asked for.
        #expect(networks.operations.createdKinds.isEmpty)
    }

    @Test("An isolated VM attaches its own network of its mode, through a view opened for it")
    func isolatedModesAttachTheVMsOwnNetwork() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let networks = ScriptedVmnetNetworks()
        let attachments = MockVmnetAttachments()
        let builder = ConfigurationBuilder.testing(networks, attachments: attachments, entitlements: .entitled)

        var nat = VMConfiguration.testLinux()
        nat.networkMembership = .isolated
        var hostOnly = makeHostOnlyConfig()
        hostOnly.networkMembership = .isolated
        for (config, kind) in [(nat, VmnetNetworkKind.nat), (hostOnly, .hostOnly)] {
            let result = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
            #expect(
                result.configuration.networkDevices[0].attachment.map(ObjectIdentifier.init)
                    == attachments.madeIdentities.last)
            #expect(result.products.vmnetNetworks.owner == config.id)
            #expect(networks.service.ipv4Subnet(for: VmnetNetworkID(kind: kind, scope: .vm(config.id))) != nil)
        }

        #expect(networks.operations.createdKinds == [.nat, .hostOnly])
    }

    @Test("A built configuration keeps its vmnet network for as long as it lives")
    func aBuiltConfigurationKeepsItsVmnetNetwork() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let networks = ScriptedVmnetNetworks()
        let attachments = MockVmnetAttachments()
        let builder = ConfigurationBuilder.testing(networks, attachments: attachments, entitlements: .entitled)
        var config = VMConfiguration.testLinux()
        config.networkMembership = .isolated

        // The rest of the result, its session view among it, dies with the
        // closure, so the service lets go of the network.
        var configuration: VZVirtualMachineConfiguration? = try autoreleasepool {
            try builder.assemble(from: config, bundleURL: bundleURL, validate: false).configuration
        }
        #expect(configuration != nil)
        let own = try #require(attachments.madeNetworks.first)
        #expect(networks.service.ipv4Subnet(for: VmnetNetworkID(kind: .nat, scope: .vm(config.id))) == nil)
        #expect(networks.operations.releasedNetworks.isEmpty)

        autoreleasepool { configuration = nil }
        #expect(networks.operations.releasedNetworks == [own])
    }

    @Test("Build, recovery and the address observer all put an isolated VM on the network joinedNetwork names")
    @MainActor
    func everyPathFollowsJoinedNetwork() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        for (mode, kind) in [(VMNetworkMode.nat, VmnetNetworkKind.nat), (.hostOnly, .hostOnly)] {
            let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID())) {
                $0.networkEnabled = true
                $0.networkMode = mode
                $0.networkMembership = .isolated
                $0.macAddress = "aa:bb:cc:dd:ee:07"
            }
            let config = instance.configuration
            let id = VmnetNetworkID(kind: kind, scope: .vm(config.id))
            #expect(config.joinedNetwork == .vmnet(id))

            // The build asks the VM's own session view for its own network.
            let networks = ScriptedVmnetNetworks()
            networks.operations.setSubnet(.scripted("192.168.70.0"))
            let result = try ConfigurationBuilder.testing(networks, entitlements: .entitled)
                .assemble(from: config, bundleURL: bundleURL, validate: false)
            #expect(result.products.vmnetNetworks.owner == config.id)
            #expect(networks.operations.createdKinds == [kind])

            // Recovery, through the session's view, attaches the same network
            // without creating another.
            let device = MockNetworkDeviceControl(vmnetNetworks: result.products.vmnetNetworks)
            let coordinator = NetworkAttachmentCoordinator(
                vmName: config.name, device: device, interfaces: MockBridgedInterfaceProvider(),
                linkObserver: MockNetworkLinkObserver(), vmnetNetworks: result.products.vmnetNetworks,
                entitlements: .entitled, isEligible: { true }, choice: { config.networkChoice },
                onPendingChange: { _ in })
            coordinator.activate()
            #expect(device.appliedPlans == [.vmnet(.own(kind))])
            #expect(networks.operations.createdKinds == [kind])
            coordinator.stop()

            // The observer reads that network's subnet and nothing else.
            let observer = GuestAddressObserver(
                reader: ScriptedARPTable([
                    .scripted("192.168.70.5", mac: "aa:bb:cc:dd:ee:07", expiry: ARPEntry.freshExpiry),
                    .scripted("192.168.64.5", mac: "aa:bb:cc:dd:ee:07", expiry: ARPEntry.freshExpiry),
                ]),
                vmnetNetworks: networks.service, entitlements: .entitled)
            let roster = StubVMInstanceRoster()
            roster.instances = [instance]
            observer.roster = roster
            await observer.readForTesting()
            #expect(observer.address(for: instance) == .observed("192.168.70.5"))
            // The session's view holds the VM's own network; the read above
            // needs it alive.
            withExtendedLifetime(result) {}
        }
    }

    @Test("An isolated VM whose own network cannot be materialized builds detached, never on the common one")
    func isolatedModeWithoutItsNetworkBuildsDetached() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let networks = ScriptedVmnetNetworks()
        networks.operations.setCreateNetworkError(TestFailure("network limit reached"))
        let builder = ConfigurationBuilder.testing(networks, entitlements: .entitled)
        var config = VMConfiguration.testLinux()
        config.networkMembership = .isolated

        let devices = try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
            .configuration.networkDevices
        #expect(devices[0].attachment == nil)
        #expect(networks.operations.createdKinds == [.nat])
        #expect(networks.service.ipv4Subnet(for: .common(.nat)) == nil)
    }

    @Test("An isolated NAT VM in a build without the entitlement is refused, not put on system NAT")
    func isolatedNATWithoutTheEntitlementThrows() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let builder = ConfigurationBuilder.testing(entitlements: .unentitled)
        var config = VMConfiguration.testLinux()
        config.networkMembership = .isolated

        #expect {
            try builder.assemble(from: config, bundleURL: bundleURL, validate: false)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .networkNotEntitled(let network) = e, network.isOwn
            else { return false }
            return true
        }
    }

    @Test("A Host Only network that cannot be materialized builds the device detached")
    func hostOnlyModeWithoutANetworkBuildsDetached() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let networks = ScriptedVmnetNetworks()
        networks.operations.setCreateNetworkError(TestFailure("vmnet refused"))
        let builder = ConfigurationBuilder.testing(networks, entitlements: .entitled)

        // The boot (and a restore from saved state, which rebuilds the same
        // configuration) must succeed; attachment recovery reattaches later.
        let devices = try builder.assemble(
            from: makeHostOnlyConfig(), bundleURL: bundleURL, validate: false
        ).configuration.networkDevices
        #expect(devices.count == 1)
        #expect(devices[0].attachment == nil)
    }

    // MARK: - Input Devices

    @Test("A guest known to run macOS 13+ gets only the Mac input devices")
    func macOSInputDevicesMacPairForModernGuest() {
        // Called directly rather than through `assemble`: the rest of
        // `configureMacOSBoot` needs a real `VZMacHardwareModel`, which only a
        // restore image can mint.
        let vz = VZVirtualMachineConfiguration()
        var config = VMConfiguration(
            name: "Test macOS", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        config.lastSeenGuestOSVersion = "13.5"
        ConfigurationBuilder.testing().configureMacOSDevices(vz, config: config)

        #expect(vz.pointingDevices.count == 1)
        #expect(vz.pointingDevices.first is VZMacTrackpadConfiguration)
        #expect(vz.keyboards.count == 1)
        #expect(vz.keyboards.first is VZMacKeyboardConfiguration)
    }

    @Test("A guest known to predate macOS 13 gets only the USB input devices")
    func macOSInputDevicesUSBPairForOldGuest() {
        let vz = VZVirtualMachineConfiguration()
        var config = VMConfiguration(
            name: "Test macOS", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        config.installedImage = .macOSRestoreImage(version: "12.0.1", build: "21A559")
        ConfigurationBuilder.testing().configureMacOSDevices(vz, config: config)

        #expect(vz.pointingDevices.count == 1)
        #expect(vz.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
        #expect(vz.keyboards.count == 1)
        #expect(vz.keyboards.first is VZUSBKeyboardConfiguration)
    }

    @Test("macOS display device carries the configured size and pixel density")
    func macOSDisplayMatchesConfiguration() throws {
        let vz = VZVirtualMachineConfiguration()
        var config = VMConfiguration(
            name: "Test macOS", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        config.displayWidth = 2560
        config.displayHeight = 1600
        config.displayPPI = 220
        ConfigurationBuilder.testing().configureMacOSDevices(vz, config: config)

        let graphics = try #require(vz.graphicsDevices.first as? VZMacGraphicsDeviceConfiguration)
        let display = try #require(graphics.displays.first)
        #expect(display.widthInPixels == 2560)
        #expect(display.heightInPixels == 1600)
        #expect(display.pixelsPerInch == 220)
    }

    @Test("EFI scanout carries the configured display size")
    func efiScanoutMatchesConfiguration() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        var config = VMConfiguration.testLinux()
        config.displayWidth = 1680
        config.displayHeight = 1050
        let result = try ConfigurationBuilder.testing().assemble(
            from: config, bundleURL: bundleURL, validate: false)

        let graphics = try #require(
            result.configuration.graphicsDevices.first as? VZVirtioGraphicsDeviceConfiguration)
        let scanout = try #require(graphics.scanouts.first)
        #expect(scanout.widthInPixels == 1680)
        #expect(scanout.heightInPixels == 1050)
    }

    @Test("EFI guests get only the USB pointing/keyboard devices")
    func efiInputDevicesAreUSBOnly() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let result = try ConfigurationBuilder.testing().assemble(
            from: VMConfiguration.testLinux(), bundleURL: bundleURL, validate: false)
        let vz = result.configuration

        // The Mac devices are Mac-platform only, so a generic-platform guest
        // must never see them.
        #expect(vz.pointingDevices.count == 1)
        #expect(vz.pointingDevices.first is VZUSBScreenCoordinatePointingDeviceConfiguration)
        #expect(vz.keyboards.count == 1)
        #expect(vz.keyboards.first is VZUSBKeyboardConfiguration)
    }

    // MARK: - Socket Device

    @Test("A Linux guest gets exactly one virtio socket device", arguments: [VMBootMode.efi, .linuxKernel])
    func linuxGuestGetsOneSocketDevice(bootMode: VMBootMode) throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        var config = VMConfiguration.testLinux()
        config.bootMode = bootMode
        if bootMode == .linuxKernel {
            let kernel = bundleURL.appendingPathComponent("vmlinuz")
            try Data([0]).write(to: kernel)
            config.kernelPath = kernel.path(percentEncoded: false)
        }

        let devices = try ConfigurationBuilder.testing()
            .assemble(from: config, bundleURL: bundleURL, validate: false)
            .configuration.socketDevices

        #expect(devices.count == 1)
        #expect(devices.first is VZVirtioSocketDeviceConfiguration)
    }

    @Test(
        "A build gives exactly the recorded shape's socket device",
        arguments: [(VMDeviceShape.current, 1), (VMDeviceShape(virtioSocketDevice: false), 0)]
    )
    func socketDeviceFollowsTheRecordedShape(shape: VMDeviceShape, socketDevices: Int) throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        var config = VMConfiguration.testLinux()
        config.deviceShape = shape

        let devices = try ConfigurationBuilder.testing()
            .assemble(from: config, bundleURL: bundleURL, validate: false)
            .configuration.socketDevices

        #expect(devices.count == socketDevices)
    }

    // MARK: - Path-Traversal Containment

    @Test("Internal storage disk path with .. escape is rejected as storageDiskNotFound")
    func internalStorageDiskRejectsPathTraversal() async throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Marking the entry `isInternal: true` opts into bundle-containment
        // validation. A `..` segment that resolves outside the bundle must
        // be rejected before the framework ever opens the file.
        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk(
                path: "../escape/passwd",
                readOnly: true,
                label: "evil",
                isInternal: true,
                kind: .virtio
            )
        ]

        let builder = ConfigurationBuilder.testing()
        await #expect {
            try await builder.build(from: config, bundleURL: bundleURL)
        } throws: { error in
            guard let e = error as? ConfigurationBuilderError,
                case .storageDiskNotFound = e
            else { return false }
            return true
        }
    }

    // MARK: - Symlink Resolution for External Storage Disks

    @Test("External storage disk via symlink attaches to symlink target, not symlink path")
    func externalStorageDiskFollowsSymlink() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        // Real file in a scratch directory outside the bundle, plus a
        // symlink to it. The builder must hand VZ the resolved target
        // URL so the attachment doesn't depend on the symlink surviving.
        let scratchDir = scratch.url.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)

        // Need a 1 MB zeroed raw disk image — VZ rejects smaller / empty
        // files as "disk image format not recognized" inside the
        // `VZDiskImageStorageDeviceAttachment` constructor.
        let realPath = scratchDir.appendingPathComponent("real.asif").path(percentEncoded: false)
        FileManager.default.createFile(atPath: realPath, contents: Data(count: 1_048_576))
        let symlinkPath = scratchDir.appendingPathComponent("symlink.asif").path(percentEncoded: false)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath, withDestinationPath: realPath)

        // The bundle's own Disk.asif also needs to be sized for the same
        // reason; replace the zero-byte stub created by makeEngineBundle.
        let mainDiskURL = VMBundleLayout(bundleURL: bundleURL).diskImageURL
        try? FileManager.default.removeItem(at: mainDiskURL)
        FileManager.default.createFile(
            atPath: mainDiskURL.path(percentEncoded: false), contents: Data(count: 1_048_576))

        var config = VMConfiguration(
            name: "Test Linux", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        config.storageDisks = [
            StorageDisk(
                path: "Disk.asif", readOnly: false, label: "Main Disk",
                isInternal: true, kind: .virtio),
            StorageDisk(
                path: symlinkPath, readOnly: true, label: "Via Symlink",
                isInternal: false, kind: .virtio),
        ]

        let builder = ConfigurationBuilder.testing()
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

    // MARK: - Guest Agent Disk

    /// A macOS-guest config carrying `installedVersion` as its install record.
    ///
    /// `bootMode: .efi` rather than `.macOS`: the delivery decision reads
    /// `guestOS`, while the Mac boot path needs hardware-model data that only a
    /// real restore image can produce.
    private func makeAgentDiskConfig(installedVersion: String?) -> VMConfiguration {
        var config = VMConfiguration(
            name: "Test macOS", guestOS: .macOS, bootMode: .efi, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        if let installedVersion {
            config.installedImage = .macOSRestoreImage(version: installedVersion, build: "21A559")
        }
        return config
    }

    /// Writes a stand-in for the bundled installer image.
    private func makeAgentDiskImage() throws -> URL {
        let url = scratch.url.appendingPathComponent("\(UUID().uuidString).dmg")
        try Data(count: 1_048_576).write(to: url)
        return url
    }

    @Test("A guest below the USB floor gets the agent disk on virtio, attached last")
    func subFloorGuestGetsVirtioAgentDisk() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let agentURL = try makeAgentDiskImage()

        let builder = ConfigurationBuilder.testing(guestAgentInstaller: agentURL)
        let result = try builder.assemble(
            from: makeAgentDiskConfig(installedVersion: "12.0.1"), bundleURL: bundleURL,
            validate: false)
        let vz = result.configuration

        #expect(vz.storageDevices.count == 2)
        let agentDevice = try #require(vz.storageDevices.last as? VZVirtioBlockDeviceConfiguration)
        let attachment = try #require(agentDevice.attachment as? VZDiskImageStorageDeviceAttachment)
        #expect(attachment.isReadOnly)
        #expect(
            attachment.url.standardizedFileURL.path(percentEncoded: false)
                == agentURL.standardizedFileURL.path(percentEncoded: false))
        // The whole point of the virtio path: nothing lands on the USB bus.
        #expect(vz.usbControllers.first?.usbDevices.isEmpty == true)
    }

    @Test(
        "A guest at or above the USB floor gets no agent disk",
        arguments: ["12.3", "12.3.1", "13.0", "26.0"])
    func atFloorGuestGetsNoAgentDisk(installedVersion: String) throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)
        let agentURL = try makeAgentDiskImage()

        let builder = ConfigurationBuilder.testing(guestAgentInstaller: agentURL)
        let result = try builder.assemble(
            from: makeAgentDiskConfig(installedVersion: installedVersion), bundleURL: bundleURL,
            validate: false)
        #expect(result.configuration.storageDevices.count == 1)
    }

    @Test("A missing installer image leaves the VM bootable")
    func missingAgentDiskStillBuilds() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let missing = scratch.url.appendingPathComponent("\(UUID().uuidString).dmg")
        let builder = ConfigurationBuilder.testing(guestAgentInstaller: missing)
        let result = try builder.assemble(
            from: makeAgentDiskConfig(installedVersion: "12.0.1"), bundleURL: bundleURL,
            validate: false)
        #expect(result.configuration.storageDevices.count == 1)
    }

    @Test("A build carrying no installer image leaves the VM bootable")
    func absentAgentDiskStillBuilds() throws {
        let bundleURL = try scratch.makeEngineBundle(withDisk: true)

        let builder = ConfigurationBuilder.testing()
        let result = try builder.assemble(
            from: makeAgentDiskConfig(installedVersion: "12.0.1"), bundleURL: bundleURL,
            validate: false)
        #expect(result.configuration.storageDevices.count == 1)
    }

    @Test("The agent disk's identity is fixed by the bundle and distinct from the main disk's")
    func agentDiskIDIsStableAndDistinct() throws {
        let bundleURL = try scratch.makeEngineBundle()
        let otherBundleURL = try scratch.makeEngineBundle()

        let disk = ConfigurationBuilder.guestAgentDisk(installerPath: "/tmp/a.dmg", bundleURL: bundleURL)
        let again = ConfigurationBuilder.guestAgentDisk(installerPath: "/tmp/a.dmg", bundleURL: bundleURL)
        let other = ConfigurationBuilder.guestAgentDisk(
            installerPath: "/tmp/a.dmg", bundleURL: otherBundleURL)
        let mainDisk = StorageDisk.mainDisk(layout: VMBundleLayout(bundleURL: bundleURL))

        #expect(disk.id == again.id)
        #expect(disk.id != other.id)
        #expect(disk.id != mainDisk.id)
        // `.dmg` would otherwise default to the USB bus this delivery avoids.
        #expect(disk.kind == .virtio)
        #expect(disk.readOnly)
        #expect(!disk.isInternal)
    }

    @Test("isMainBundleDisk matches the bundle-relative path, not the disk id")
    func isMainBundleDiskMatchesByPath() throws {
        let bundleURL = try scratch.makeEngineBundle()
        let layout = VMBundleLayout(bundleURL: bundleURL)

        // A clone regenerates every disk id, so a fresh id at the canonical
        // path is still the bundle disk.
        let freshID = StorageDisk(
            id: UUID(), path: layout.diskImageURL.lastPathComponent, readOnly: false,
            label: "Main Disk", isInternal: true, kind: .virtio)
        #expect(ConfigurationBuilder.isMainBundleDisk(freshID, layout: layout))

        let additional = StorageDisk(path: "AdditionalDisks/x.asif", label: "Extra", isInternal: true)
        #expect(!ConfigurationBuilder.isMainBundleDisk(additional, layout: layout))

        let externalAtSameName = StorageDisk(
            path: layout.diskImageURL.path(percentEncoded: false), label: "External",
            isInternal: false)
        #expect(!ConfigurationBuilder.isMainBundleDisk(externalAtSameName, layout: layout))
    }
}
