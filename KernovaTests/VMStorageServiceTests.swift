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
        #expect(FileManager.default.fileExists(atPath: bundleURL.path))

        // Verify config.json exists
        let configURL = bundleURL.appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        // Clean up (use removeItem directly to avoid polluting Trash during tests)
        try FileManager.default.removeItem(at: bundleURL)
        #expect(!FileManager.default.fileExists(atPath: bundleURL.path))
    }

    @Test("Load configuration from bundle")
    func loadConfiguration() throws {
        let config = VMConfiguration(
            name: "Persistence Test",
            guestOS: .macOS,
            bootMode: .macOS,
            cpuCount: 6,
            memorySizeInGB: 12,
            notes: "Test notes"
        )

        let bundleURL = try service.createVMBundle(for: config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        let loaded = try service.loadConfiguration(from: bundleURL)
        #expect(loaded.id == config.id)
        #expect(loaded.name == config.name)
        #expect(loaded.cpuCount == 6)
        #expect(loaded.memorySizeInGB == 12)
        #expect(loaded.notes == "Test notes")
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

    // MARK: - Migration

    @Test("Migrate legacy bundle to .kernova")
    func migrateLegacyBundleToKernova() throws {
        let uuid = UUID()
        let vmsDir = try service.vmsDirectory
        let legacyURL = vmsDir.appendingPathComponent(uuid.uuidString, isDirectory: true)

        // Create a legacy bare-UUID directory with a config.json
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        let configData = "{}".data(using: .utf8)!
        try configData.write(to: legacyURL.appendingPathComponent("config.json"))
        defer {
            let migratedURL = vmsDir.appendingPathComponent("\(uuid.uuidString).kernova", isDirectory: true)
            try? FileManager.default.removeItem(at: migratedURL)
            try? FileManager.default.removeItem(at: legacyURL)
        }

        let result = try service.migrateBundleIfNeeded(at: legacyURL)
        #expect(result.pathExtension == "kernova")
        #expect(result.lastPathComponent == "\(uuid.uuidString).kernova")
        #expect(FileManager.default.fileExists(atPath: result.path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
    }

    @Test("Migrate already-migrated bundle is idempotent")
    func migrateAlreadyMigratedIsIdempotent() throws {
        let config = VMConfiguration(
            name: "Idempotent Test",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try service.createVMBundle(for: config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Already has .kernova extension — should return unchanged
        let result = try service.migrateBundleIfNeeded(at: bundleURL)
        #expect(result == bundleURL)
        #expect(result.pathExtension == "kernova")
    }

    @Test("Migrate conflict throws error")
    func migrateConflictThrows() throws {
        let uuid = UUID()
        let vmsDir = try service.vmsDirectory
        let legacyURL = vmsDir.appendingPathComponent(uuid.uuidString, isDirectory: true)
        let migratedURL = vmsDir.appendingPathComponent("\(uuid.uuidString).kernova", isDirectory: true)

        // Create both legacy and migrated directories
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: migratedURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: legacyURL)
            try? FileManager.default.removeItem(at: migratedURL)
        }

        #expect(throws: VMStorageError.self) {
            _ = try service.migrateBundleIfNeeded(at: legacyURL)
        }
    }
}
