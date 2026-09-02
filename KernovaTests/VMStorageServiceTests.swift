import Testing
import Foundation
import KernovaTestSupport
@testable import Kernova

/// Serialized because ``VMStorageService/reclaimStagedBundles()`` sweeps the whole
/// real staging directory, which every case here shares.
@Suite("VMStorageService Tests", .serialized, .admissionGated)
struct VMStorageServiceTests {
    private let service = VMStorageService()

    /// Creates a bundle at its final URL, the shape publication leaves one in.
    private func makeBundle(_ configuration: VMConfiguration) throws -> URL {
        let url = try service.bundleURL(for: configuration)
        try service.createVMBundle(configuration, at: url)
        return url
    }

    @Test("Create and delete VM bundle")
    func createAndDeleteBundle() throws {
        let config = VMConfiguration(
            name: "Test VM",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try makeBundle(config)
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

        let bundleURL = try makeBundle(config)
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

        let bundleURL = try makeBundle(config)
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

        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        #expect(throws: VMStorageError.self) {
            try service.createVMBundle(config, at: bundleURL)
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

    @Test("Permanently delete VM bundle removes it from disk")
    func permanentlyDeleteBundle() throws {
        let config = VMConfiguration(
            name: "Immediate Delete VM",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try makeBundle(config)
        #expect(FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)))

        try service.permanentlyDeleteVMBundle(at: bundleURL)
        #expect(!FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)))
    }

    @Test("Permanently deleting a suspended VM's bundle takes its saved state with it")
    func permanentlyDeleteBundleRemovesSaveFile() throws {
        let config = VMConfiguration(
            name: "Suspended Delete VM",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try makeBundle(config)
        let saveFileURL = VMBundleLayout(bundleURL: bundleURL).saveFileURL
        try Data("saved state".utf8).write(to: saveFileURL)
        #expect(FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false)))

        try service.permanentlyDeleteVMBundle(at: bundleURL)

        #expect(!FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)))
    }

    @Test("Permanently deleting non-existent bundle throws error")
    func permanentlyDeleteNonExistentThrows() {
        let fakeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-vm-bundle")

        #expect(throws: VMStorageError.self) {
            try service.permanentlyDeleteVMBundle(at: fakeURL)
        }
    }

    @Test("List VM bundles finds created bundles")
    func listBundles() throws {
        let config = VMConfiguration(
            name: "List Test",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try makeBundle(config)
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

    // MARK: - Staging & Publication

    @Test("A staged bundle sits hidden inside the VMs directory and does not exist yet")
    func stagedBundleURLIsHiddenAndAbsent() throws {
        let config = VMConfiguration(name: "Staging Path", guestOS: .linux, bootMode: .efi)

        let staged = try service.stagedBundleURL(for: config)
        let staging = try service.stagingDirectory

        #expect(staged.deletingLastPathComponent() == staging)
        #expect(staging.lastPathComponent.hasPrefix("."))
        #expect(staging.deletingLastPathComponent() == (try service.vmsDirectory))
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
    }

    @Test("Listing bundles never admits a config-bearing bundle that is still staged")
    func listIgnoresStagedBundles() throws {
        let config = VMConfiguration(name: "Interrupted Write", guestOS: .linux, bootMode: .efi)

        let staged = try service.stagedBundleURL(for: config)
        try service.createVMBundle(config, at: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        let configURL = VMBundleLayout(bundleURL: staged).configURL
        #expect(FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)))
        #expect(!(try service.listVMBundles().contains(staged)))
    }

    @Test("Publishing renames the staged bundle into the library and makes it listable")
    func publishMakesBundleListable() throws {
        let config = VMConfiguration(name: "Published", guestOS: .linux, bootMode: .efi)

        let staged = try service.stagedBundleURL(for: config)
        try service.createVMBundle(config, at: staged)
        let finalURL = try service.bundleURL(for: config)
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: finalURL)
        }

        try service.publishBundle(from: staged, to: finalURL)

        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
        #expect(try service.listVMBundles().contains(finalURL))
        #expect(try service.loadConfiguration(from: finalURL).id == config.id)
    }

    @Test("Publishing onto an occupied destination throws and leaves the staged bundle intact")
    func publishOntoOccupiedDestinationThrows() throws {
        let config = VMConfiguration(name: "Collision", guestOS: .linux, bootMode: .efi)

        let finalURL = try makeBundle(config)
        let staged = try service.stagedBundleURL(for: config)
        try service.createVMBundle(config, at: staged)
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: finalURL)
        }

        #expect(throws: VMStorageError.self) {
            try service.publishBundle(from: staged, to: finalURL)
        }

        #expect(FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
    }

    @Test("Reclaiming discards staged bundles and leaves published ones alone")
    func reclaimDiscardsOnlyStagedBundles() async throws {
        let staleConfig = VMConfiguration(name: "Abandoned", guestOS: .linux, bootMode: .efi)
        let staged = try service.stagedBundleURL(for: staleConfig)
        try service.createVMBundle(staleConfig, at: staged)

        let survivor = try makeBundle(
            VMConfiguration(name: "Survivor", guestOS: .linux, bootMode: .efi))
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: survivor)
        }

        service.reclaimStagedBundles()

        // RATIONALE: sanctioned no-signal poll (docs/TESTING.md "Async waits in
        // tests") — the removals run on a detached task the caller does not
        // hold, so the file's disappearance is the only signal there is.
        try await waitUntil {
            !FileManager.default.fileExists(atPath: staged.path(percentEncoded: false))
        }
        #expect(FileManager.default.fileExists(atPath: survivor.path(percentEncoded: false)))
    }
}
