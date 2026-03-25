import Testing
import Foundation
@testable import Kernova

@Suite("VMStorageService Tests")
struct VMStorageServiceTests {

    private let service = VMStorageService()

    @Test("Create and delete VM bundle")
    func createAndDeleteBundle() throws {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try service.createVMBundle(for: config)
        #expect(FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)))

        // Verify config.json exists
        let configURL = bundleURL.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)))

        // Clean up (use removeItem directly to avoid polluting Trash during tests)
        try FileManager.default.removeItem(at: bundleURL)
        #expect(!FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)))
    }

    @Test("Load configuration from bundle")
    func loadConfiguration() throws {
        let config = VMConfiguration(
            name: "Persistence Test",
            guestOS: .macOS,
            bootMode: .macOS,
            cpuCount: 6,
            memorySizeInGB: 12
        )

        let bundleURL = try service.createVMBundle(for: config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let loaded = try service.loadConfiguration(from: bundleURL)
        #expect(loaded.id == config.id)
        #expect(loaded.name == config.name)
        #expect(loaded.cpuCount == 6)
        #expect(loaded.memorySizeInGB == 12)
    }

    @Test("Save updated configuration")
    func saveUpdatedConfiguration() throws {
        var config = VMConfiguration(
            name: "Original Name",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try service.createVMBundle(for: config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Update and save
        config.name = "Updated Name"
        config.cpuCount = 8
        try service.saveConfiguration(config, to: bundleURL)

        // Reload and verify
        let loaded = try service.loadConfiguration(from: bundleURL)
        #expect(loaded.name == "Updated Name")
        #expect(loaded.cpuCount == 8)
    }

    @Test("Creating duplicate bundle throws error")
    func duplicateBundleThrows() throws {
        let config = VMConfiguration(
            name: "Duplicate Test",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try service.createVMBundle(for: config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        #expect(throws: VMStorageError.self) {
            _ = try service.createVMBundle(for: config)
        }
    }

    @Test("Deleting non-existent bundle throws error")
    func deleteNonExistentThrows() {
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-vm-bundle")

        #expect(throws: VMStorageError.self) {
            try service.deleteVMBundle(at: fakeURL)
        }
    }

    @Test("List VM bundles finds created bundles")
    func listBundles() throws {
        let config = VMConfiguration(
            name: "List Test",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try service.createVMBundle(for: config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let bundles = try service.listVMBundles()
        #expect(bundles.contains(bundleURL))
    }

    // MARK: - Bundle Extension

    @Test("Bundle URL has .kernova extension")
    func bundleURLHasKernovaExtension() throws {
        let config = VMConfiguration(
            name: "Extension Test",
            guestOS: .linux,
            bootMode: .efi
        )

        let url = try service.bundleURL(for: config)
        #expect(url.pathExtension == "kernova")
        #expect(url.lastPathComponent == "\(config.id.uuidString).kernova")
    }

}
