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

    // MARK: - Legacy `discImageDeviceUUID` Migration Persistence

    /// Writes raw JSON to a bundle's `config.json` so the next `loadConfiguration`
    /// reads exactly the bytes the caller provided, simulating a config file
    /// that was saved before the `discImageDeviceUUID` field existed.
    private func writeLegacyConfigJSON(toBundle bundleURL: URL, includeDiscUUID: Bool) throws {
        let uuidPart =
            includeDiscUUID
            ? "\"discImageDeviceUUID\": \"33333333-3333-3333-3333-333333333333\","
            : ""
        let json = """
            {
                "id": "12345678-1234-1234-1234-123456789012",
                "name": "Legacy Test",
                "guestOS": "linux",
                "bootMode": "efi",
                "cpuCount": 4,
                "memorySizeInGB": 8,
                "diskSizeInGB": 64,
                "displayWidth": 1920,
                "displayHeight": 1200,
                "displayPPI": 144,
                "displayPreference": "inline",
                "networkEnabled": true,
                "clipboardSharingEnabled": false,
                "microphoneEnabled": false,
                "discImagePath": "/tmp/legacy.iso",
                "discImageReadOnly": true,
                "bootFromDiscImage": false,
                \(uuidPart)
                "createdAt": "2025-01-01T00:00:00Z"
            }
            """
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: bundleURL.appendingPathComponent("config.json"))
    }

    @Test("Loading a legacy config with disc but no UUID persists the migrated UUID")
    func loadPersistsLegacyDiscImageDeviceUUID() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".kernova")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try writeLegacyConfigJSON(toBundle: bundleURL, includeDiscUUID: false)

        // First load: migration fires and persists.
        let firstLoad = try service.loadConfiguration(from: bundleURL)
        let migratedUUID = try #require(firstLoad.discImageDeviceUUID)

        // Second load: the on-disk JSON now carries the UUID, so subsequent
        // loads must return the same value (no re-migration, no re-save loop).
        let secondLoad = try service.loadConfiguration(from: bundleURL)
        #expect(secondLoad.discImageDeviceUUID == migratedUUID)

        // Spot-check: the file actually contains the UUID now.
        let rawJSON = try Data(contentsOf: bundleURL.appendingPathComponent("config.json"))
        let parsed = try #require(try JSONSerialization.jsonObject(with: rawJSON) as? [String: Any])
        #expect(parsed["discImageDeviceUUID"] is String)
    }

    @Test("Loading a config without a disc image leaves no UUID and writes nothing extra")
    func loadDoesNotMigrateWhenNoDiscImage() async throws {
        let config = VMConfiguration(name: "No Disc", guestOS: .linux, bootMode: .efi)
        let bundleURL = try service.createVMBundle(for: config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let configURL = bundleURL.appendingPathComponent("config.json")
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date

        // Sleep a tick so a spurious re-save would observably bump mtime.
        try await Task.sleep(for: .milliseconds(50))

        let loaded = try service.loadConfiguration(from: bundleURL)
        #expect(loaded.discImageDeviceUUID == nil)

        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }

    @Test("Loading a config that already has a disc UUID does not rewrite the file")
    func loadIsIdempotentWhenUUIDAlreadyPresent() async throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".kernova")
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        try writeLegacyConfigJSON(toBundle: bundleURL, includeDiscUUID: true)

        let configURL = bundleURL.appendingPathComponent("config.json")
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date

        try await Task.sleep(for: .milliseconds(50))

        _ = try service.loadConfiguration(from: bundleURL)

        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: configURL.path)[.modificationDate] as? Date
        #expect(mtimeBefore == mtimeAfter)
    }
}
