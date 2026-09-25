import Testing
import Foundation
import KernovaTestSupport
import Synchronization
@testable import Kernova

/// Serialized because ``VMStorageService/reclaimStagedBundles()`` sweeps the whole
/// real staging directory, which every case here shares.
@Suite("VMStorageService Tests", .serialized, .admissionGated)
struct VMStorageServiceTests {
    private let service = VMStorageService()

    private func files(_ bundleURL: URL) -> VMBundleFiles {
        VMBundleFiles(url: bundleURL, access: CoordinatedBundleFileAccess())
    }

    /// Creates the bundle directory at `url` and writes its first `config.json`,
    /// as a create does.
    private func createBundle(_ configuration: VMConfiguration, at url: URL) throws {
        try service.createVMBundle(at: url)
        try files(url).writeInitial(configuration)
    }

    /// Creates a bundle at its final URL, the shape publication leaves one in.
    private func makeBundle(_ configuration: VMConfiguration) throws -> URL {
        let url = try service.bundleURL(for: configuration)
        try createBundle(configuration, at: url)
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

        let loaded = try files(bundleURL).readConfiguration()
        #expect(loaded.id == config.id)
        #expect(loaded.name == config.name)
        #expect(loaded.cpuCount == 6)
        #expect(loaded.memorySizeInGB == 12)
    }

    @Test("Save updated configuration")
    func saveUpdatedConfiguration() throws {
        let config = VMConfiguration(
            name: "Original Name",
            guestOS: .linux,
            bootMode: .efi
        )

        let bundleURL = try makeBundle(config)
        defer { try? FileManager.default.removeItem(at: bundleURL) }

        // Update and save
        try files(bundleURL).update(.configuration) {
            $0.name = "Updated Name"
            $0.cpuCount = 8
        }

        // Reload and verify
        let loaded = try files(bundleURL).readConfiguration()
        #expect(loaded.name == "Updated Name")
        #expect(loaded.cpuCount == 8)
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
        let staged = try service.makeStagedBundleURL()
        let staging = try service.stagingDirectory

        #expect(staged.deletingLastPathComponent() == staging)
        #expect(staging.lastPathComponent.hasPrefix("."))
        #expect(staging.deletingLastPathComponent() == (try service.vmsDirectory))
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
    }

    @Test("Each staged path is minted fresh, so no two writes can name the same tree")
    func stagedBundleURLsAreUniquePerWrite() throws {
        // An import keeps the source bundle's configuration id, so a retry after
        // an interrupted attempt would otherwise stage where the launch reclaim
        // is still deleting.
        #expect(try service.makeStagedBundleURL() != (try service.makeStagedBundleURL()))
    }

    @Test("Listing bundles never admits a config-bearing bundle that is still staged")
    func listIgnoresStagedBundles() throws {
        let config = VMConfiguration(name: "Interrupted Write", guestOS: .linux, bootMode: .efi)

        let staged = try service.makeStagedBundleURL()
        try createBundle(config, at: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        let configURL = VMBundleLayout(bundleURL: staged).configURL
        #expect(FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)))
        #expect(!(try service.listVMBundles().contains(staged)))
    }

    @Test("Publishing renames the staged bundle into the library and makes it listable")
    func publishMakesBundleListable() throws {
        let config = VMConfiguration(name: "Published", guestOS: .linux, bootMode: .efi)

        let staged = try service.makeStagedBundleURL()
        try createBundle(config, at: staged)
        let finalURL = try service.bundleURL(for: config)
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: finalURL)
        }

        try service.publishBundle(from: staged, to: finalURL)

        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
        #expect(try service.listVMBundles().contains(finalURL))
        #expect(try files(finalURL).readConfiguration().id == config.id)
    }

    @Test(
        "Of two publishes to one name the loser gets exists, and the winner's bundle is intact",
        arguments: [false, true])
    func ofTwoPublishesToOneNameTheLoserGetsExists(destinationIsEmpty: Bool) throws {
        let winner = VMConfiguration(name: "Winner", guestOS: .linux, bootMode: .efi)
        let finalURL = try service.bundleURL(for: winner)
        if destinationIsEmpty {
            // An empty directory is still an occupied name: `rename(2)` alone
            // would replace it.
            try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: true)
        } else {
            try createBundle(winner, at: finalURL)
        }
        let loser = VMConfiguration(name: "Loser", guestOS: .linux, bootMode: .efi)
        let staged = try service.makeStagedBundleURL()
        try createBundle(loser, at: staged)
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: finalURL)
        }

        let refusal = #expect(throws: VMStorageError.self) {
            try service.publishBundle(from: staged, to: finalURL)
        }
        guard case .bundleAlreadyExists(let url)? = refusal else {
            Issue.record("expected an exists refusal, got \(String(describing: refusal))")
            return
        }
        #expect(url == finalURL)

        #expect(FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        if !destinationIsEmpty {
            #expect(try files(finalURL).readConfiguration().id == winner.id)
        }
    }

    @Test("Of many concurrent publishes to one name, exactly one wins and every other gets exists")
    func concurrentPublishesToOneNameYieldOneWinner() throws {
        let contenders = (0..<8).map {
            VMConfiguration(name: "Contender \($0)", guestOS: .linux, bootMode: .efi)
        }
        let finalURL = try service.bundleURL(for: contenders[0])
        let staged = try contenders.map { config in
            let url = try service.makeStagedBundleURL()
            try createBundle(config, at: url)
            return url
        }
        defer {
            for url in staged { try? FileManager.default.removeItem(at: url) }
            try? FileManager.default.removeItem(at: finalURL)
        }

        let outcomes = Mutex<[Int: Result<Void, any Error>]>([:])
        let service = service
        DispatchQueue.concurrentPerform(iterations: staged.count) { index in
            let outcome = Result { try service.publishBundle(from: staged[index], to: finalURL) }
            outcomes.withLock { $0[index] = outcome }
        }

        let results = outcomes.withLock { $0 }
        let winners = results.filter { if case .success = $0.value { true } else { false } }
        #expect(winners.count == 1)
        for (_, outcome) in results {
            guard case .failure(let error) = outcome else { continue }
            guard case VMStorageError.bundleAlreadyExists? = error as? VMStorageError else {
                Issue.record("a losing publish failed with \(error), not an exists refusal")
                continue
            }
        }
        let winner = try #require(winners.keys.first)
        #expect(try files(finalURL).readConfiguration().id == contenders[winner].id)
    }

    @Test("Reclaiming discards staged bundles and leaves published ones alone")
    func reclaimDiscardsOnlyStagedBundles() async throws {
        let staleConfig = VMConfiguration(name: "Abandoned", guestOS: .linux, bootMode: .efi)
        let staged = try service.makeStagedBundleURL()
        try createBundle(staleConfig, at: staged)

        let survivor = try makeBundle(
            VMConfiguration(name: "Survivor", guestOS: .linux, bootMode: .efi))
        defer {
            try? FileManager.default.removeItem(at: staged)
            try? FileManager.default.removeItem(at: survivor)
        }

        await service.reclaimStagedBundles().value

        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: survivor.path(percentEncoded: false)))
    }

    @Test("A clone copies only the files it was given, so it inherits no USB pairings")
    func cloneLeavesUSBPairingsBehind() throws {
        let source = VMConfiguration(name: "Pairing Source", guestOS: .linux, bootMode: .efi)
        let sourceURL = try makeBundle(source)
        let clone = VMConfiguration(name: "Pairing Clone", guestOS: .linux, bootMode: .efi)
        let cloneURL = try service.bundleURL(for: clone)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: cloneURL)
        }
        try files(sourceURL).update(.usbPairings) {
            $0 = USBAccessoryPairingSet(pairings: [
                USBAccessoryPairing(
                    key: "04e8:6300:0100:0373", form: .serialNumber, displayName: "Samsung Type-C",
                    receptacleLabel: "Port-USB-C@2")
            ])
        }

        try service.cloneVMBundle(
            from: sourceURL, to: cloneURL, filesToCopy: ["Disk.asif", "EFIVariableStore"])

        // The omission is silent by construction — nothing lists the file — so
        // it is asserted here: two VMs expecting one device would race for it.
        // A change that moves nothing answers what the file holds.
        #expect(try files(cloneURL).update(.usbPairings) { _ in }.isEmpty)
        #expect(try !files(sourceURL).update(.usbPairings) { _ in }.isEmpty)
    }
}
