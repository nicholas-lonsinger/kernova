import Foundation
import Testing

@testable import Kernova

@Suite("VMPreviewModel Tests")
struct VMPreviewModelTests {
    // MARK: - Fixtures

    /// Creates a throwaway `.kernova` bundle directory containing `config.json`.
    ///
    /// Callers remove it via the returned URL in a `defer`.
    private func makeBundle(_ configuration: VMConfiguration) throws -> URL {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(configuration.id.uuidString).kernova", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let data = try VMConfiguration.makeJSONEncoder().encode(configuration)
        try data.write(to: VMBundleLayout(bundleURL: bundleURL).configURL)
        return bundleURL
    }

    private func field(_ label: String, in model: VMPreviewModel) -> VMPreviewModel.Field? {
        model.fields.first { $0.label == label }
    }

    // MARK: - Identity and fields

    @Test("macOS guest maps name, icon, subtitle, and core fields")
    func macOSGuestCoreFields() throws {
        let config = VMConfiguration(
            name: "Tahoe Dev", guestOS: .macOS, bootMode: .macOS,
            cpuCount: 6, memorySizeInGB: 12,
            displayWidth: 2560, displayHeight: 1600, displayPPI: 144)
        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let model = VMPreviewModel(
            configuration: config, layout: VMBundleLayout(bundleURL: bundleURL))

        #expect(model.name == "Tahoe Dev")
        #expect(model.iconName == "apple.logo")
        #expect(model.subtitle == "macOS virtual machine")
        #expect(model.badge == nil)
        #expect(model.footer == config.id.uuidString)
        // macOS has exactly one valid boot mode, so the OS row omits it.
        #expect(field("Guest OS", in: model)?.value == "macOS")
        #expect(field("CPU Cores", in: model)?.value == "6")
        #expect(field("Memory", in: model)?.value == "12 GB")
        #expect(field("Display", in: model)?.value == "2560 × 1600 @ 144 PPI")
        #expect(field("Network", in: model)?.value == "Enabled")
        #expect(field("Shared Folders", in: model)?.value == "None")
        #expect(
            field("Created", in: model)?.value
                == config.createdAt.formatted(date: .abbreviated, time: .shortened))
    }

    @Test(
        "Linux guest shows boot mode and terminal icon",
        arguments: [
            (VMBootMode.efi, "Linux · EFI Boot"),
            (VMBootMode.linuxKernel, "Linux · Linux Kernel"),
        ])
    func linuxGuestShowsBootMode(bootMode: VMBootMode, expected: String) throws {
        let config = VMConfiguration(name: "Ubuntu", guestOS: .linux, bootMode: bootMode)
        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let model = VMPreviewModel(
            configuration: config, layout: VMBundleLayout(bundleURL: bundleURL))

        #expect(model.iconName == "terminal.fill")
        #expect(model.subtitle == "Linux virtual machine")
        #expect(field("Guest OS", in: model)?.value == expected)
    }

    @Test("Network disabled and shared folders are reflected")
    func networkAndSharedFolders() throws {
        let config = VMConfiguration(
            name: "Shares", guestOS: .linux, bootMode: .efi,
            networkEnabled: false,
            sharedDirectories: [
                SharedDirectory(path: "/Users/me/Developer"),
                SharedDirectory(path: "/Users/me/Downloads", readOnly: true),
            ])
        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let model = VMPreviewModel(
            configuration: config, layout: VMBundleLayout(bundleURL: bundleURL))

        #expect(field("Network", in: model)?.value == "Disabled")
        #expect(field("Shared Folders", in: model)?.value == "Developer, Downloads")
    }

    @Test("Additional disks row appears only beyond the primary disk")
    func additionalDisksRow() throws {
        let multiDisk = VMConfiguration(
            name: "Disks", guestOS: .linux, bootMode: .efi,
            storageDisks: [
                StorageDisk(path: "Disk.asif", isInternal: true),
                StorageDisk(path: "Scratch.asif", isInternal: true),
                StorageDisk(path: "/Volumes/External/data.img"),
            ])
        let bundleURL = try makeBundle(multiDisk)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let model = VMPreviewModel(
            configuration: multiDisk, layout: VMBundleLayout(bundleURL: bundleURL))
        #expect(field("Additional Disks", in: model)?.value == "2")

        let singleDisk = VMConfiguration(name: "One", guestOS: .linux, bootMode: .efi)
        let singleURL = try makeBundle(singleDisk)
        defer { try? FileManager.default.removeItem(at: singleURL) }
        let singleModel = VMPreviewModel(
            configuration: singleDisk, layout: VMBundleLayout(bundleURL: singleURL))
        #expect(field("Additional Disks", in: singleModel) == nil)
    }

    // MARK: - Storage row

    @Test("Storage row reads live sizes and computes the usage fraction")
    func storageRowWithDiskImage() throws {
        let config = VMConfiguration(name: "Sized", guestOS: .linux, bootMode: .efi)
        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let layout = VMBundleLayout(bundleURL: bundleURL)
        // A plain (non-ASIF) file: apparent size is treated as capacity.
        try Data(repeating: 0xAB, count: 100_000).write(to: layout.diskImageURL)

        let model = VMPreviewModel(configuration: config, layout: layout)
        let storage = try #require(field("Storage", in: model))

        let sizes = layout.diskSizes(
            forRelativePath: layout.diskImageURL.lastPathComponent, isInternal: true)
        #expect(
            storage.value
                == diskSubtitle(
                    sizes: sizes, path: layout.diskImageURL.lastPathComponent, isInternal: true))
        #expect(storage.value.contains("(allocated)"))
        let fraction = try #require(storage.usedFraction)
        #expect(fraction > 0 && fraction <= 1)
    }

    @Test("Missing disk image degrades to the in-bundle placeholder")
    func storageRowWithMissingDisk() throws {
        let config = VMConfiguration(name: "Empty", guestOS: .linux, bootMode: .efi)
        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let model = VMPreviewModel(
            configuration: config, layout: VMBundleLayout(bundleURL: bundleURL))
        let storage = try #require(field("Storage", in: model))

        #expect(storage.value == "In-bundle disk image")
        #expect(storage.usedFraction == nil)
    }

    // MARK: - Badges

    @Test("Save file produces the Suspended badge")
    func suspendedBadge() throws {
        let config = VMConfiguration(name: "Asleep", guestOS: .macOS, bootMode: .macOS)
        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let layout = VMBundleLayout(bundleURL: bundleURL)
        try Data().write(to: layout.saveFileURL)

        let model = VMPreviewModel(configuration: config, layout: layout)
        #expect(model.badge == .suspended)
        #expect(model.badge?.displayName == "Suspended")
    }

    @Test("Pending install wins over a save file")
    func installPendingBadge() throws {
        let config = VMConfiguration(
            name: "Fresh", guestOS: .macOS, bootMode: .macOS,
            installContext: MacOSInstallContext(source: .downloadLatest))
        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let layout = VMBundleLayout(bundleURL: bundleURL)
        try Data().write(to: layout.saveFileURL)

        let model = VMPreviewModel(configuration: config, layout: layout)
        #expect(model.badge == .installPending)
        #expect(model.badge?.displayName == "Install Pending")
    }

    // MARK: - Degraded bundle

    @Test("Unreadable bundle falls back to folder-name identity")
    func unreadableBundle() {
        let bundleURL = URL(fileURLWithPath: "/tmp/ABCD-1234.kernova")
        let model = VMPreviewModel.unreadable(bundleURL: bundleURL)

        #expect(model.name == "ABCD-1234")
        #expect(model.iconName == "questionmark.square.dashed")
        #expect(model.badge == nil)
        #expect(model.fields.isEmpty)
        #expect(model.footer == "Kernova Virtual Machine")
    }

    // MARK: - Bundle loading seam

    @Test("VMConfiguration.load(fromBundle:) round-trips the saved config")
    func loadFromBundleRoundTrip() throws {
        // Whole-second creation date: the ISO-8601 strategy drops fractional
        // seconds, which would break exact equality after the round trip.
        let config = VMConfiguration(
            name: "Round Trip", guestOS: .linux, bootMode: .efi, cpuCount: 4,
            createdAt: Date(timeIntervalSince1970: 1_750_000_000))
        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let loaded = try VMConfiguration.load(fromBundle: bundleURL)
        #expect(loaded == config)
    }

    @Test("VMConfiguration.load(fromBundle:) throws when config.json is absent")
    func loadFromBundleMissingConfig() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).kernova", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        #expect(throws: (any Error).self) {
            try VMConfiguration.load(fromBundle: bundleURL)
        }
    }
}
