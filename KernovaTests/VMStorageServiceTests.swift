import Testing
import Foundation
import KernovaKit
import KernovaTestSupport
import Synchronization
@testable import Kernova

@Suite("VMStorageService Tests", .admissionGated)
struct VMStorageServiceTests {
    /// A library directory this test owns, removed with the suite instance: the
    /// test host is the app, so ``VMStorageService/productionLibraryDirectory``
    /// is the maintainer's real library.
    private final class ScratchLibrary: Sendable {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernovaTestLibrary-\(UUID().uuidString)", isDirectory: true)

        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private let library = ScratchLibrary()
    private let service: VMStorageService

    init() {
        service = VMStorageService(libraryDirectory: library.url)
    }

    /// A service over this test's library with a root of its own, standing in
    /// for another process's.
    private func otherProcess() -> VMStorageService {
        VMStorageService(libraryDirectory: library.url)
    }

    private func files(_ bundleURL: URL) -> VMBundleFiles {
        VMBundleFiles(url: bundleURL, access: CoordinatedBundleFileAccess())
    }

    /// A writer to the bundle's files that no permit governs.
    private func writer(_ bundleURL: URL) -> VMStagedBundle {
        VMStagedBundle.fixtureForTesting(at: bundleURL, access: CoordinatedBundleFileAccess())
    }

    /// Stages a bundle through `stager` and writes its first `config.json`, as
    /// a create does.
    private func stageBundle(
        _ configuration: VMConfiguration, in stager: VMStorageService? = nil
    ) throws -> URL {
        let stager = stager ?? service
        let url = try stager.makeStagedBundleURL()
        try stager.createVMBundle(at: url)
        try writer(url).writeInitial(configuration)
        return url
    }

    /// Stages and publishes a bundle, the shape publication leaves one in.
    private func makeBundle(_ configuration: VMConfiguration) throws -> URL {
        let url = try service.bundleURL(for: configuration)
        try service.publishBundle(from: try stageBundle(configuration), to: url)
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

        // Update and save
        try writer(bundleURL).update(.configuration) {
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
        let fakeURL = library.url.appendingPathComponent("nonexistent-vm-bundle")

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
        let fakeURL = library.url.appendingPathComponent("nonexistent-vm-bundle")

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

        let bundles = try service.listVMBundles()
        #expect(bundles.contains(bundleURL))
    }

    // MARK: - Bundle Identity

    @Test("A bundle's identity follows the directory across a rename, and a place with no bundle has none")
    func bundleIdentityFollowsTheDirectory() throws {
        let first = try makeBundle(VMConfiguration(name: "First", guestOS: .linux, bootMode: .efi))
        let second = try makeBundle(VMConfiguration(name: "Second", guestOS: .linux, bootMode: .efi))
        let moved = first.deletingLastPathComponent()
            .appendingPathComponent("Moved-\(UUID().uuidString).kernova", isDirectory: true)
        let identity = try #require(service.bundleIdentity(at: first))
        #expect(service.bundleIdentity(at: second) != identity)

        try FileManager.default.moveItem(at: first, to: moved)

        #expect(service.bundleIdentity(at: moved) == identity)
        #expect(service.bundleIdentity(at: first) == nil)
        try FileManager.default.removeItem(at: VMBundleLayout(bundleURL: second).configURL)
        #expect(service.bundleIdentity(at: second) == nil)
    }

    @Test(
        "Two spellings a case-insensitive volume folds together name one bundle",
        .enabled(if: VMStorageServiceTests.scratchVolumeFoldsCase()))
    func bundleIdentityIsTheVolumes() throws {
        let url = try makeBundle(VMConfiguration(name: "Folded", guestOS: .linux, bootMode: .efi))
        let respelled = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent.lowercased(), isDirectory: true)
        #expect(VMBundleIdentity.spelling(respelled) != VMBundleIdentity.spelling(url))

        #expect(service.bundleIdentity(at: respelled) == service.bundleIdentity(at: url))
    }

    /// Whether the volume every ``ScratchLibrary`` sits on folds case.
    private static func scratchVolumeFoldsCase() -> Bool {
        guard
            let values = try? FileManager.default.temporaryDirectory.resourceValues(
                forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        else { return false }
        return values.volumeSupportsCaseSensitiveNames == false
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

    @Test("The production library is Kernova/VMs in the app's Application Support")
    func productionLibraryLocation() {
        let expected = URL.applicationSupportDirectory.appendingPathComponent(
            "Kernova/VMs", isDirectory: true)
        #expect(
            VMStorageService.productionLibraryDirectory.path(percentEncoded: false)
                == expected.path(percentEncoded: false))
    }

    @Test("A staged bundle sits in this service's claimed root, hidden inside the library, and is absent")
    func stagedBundleURLIsHiddenAndAbsent() throws {
        let root = service.stagingRoot.url
        let staged = try service.makeStagedBundleURL()

        #expect(staged.deletingLastPathComponent() == root)
        #expect(FileManager.default.fileExists(atPath: root.path(percentEncoded: false)))
        #expect(
            root.deletingLastPathComponent()
                == library.url.appendingPathComponent(".Staging", isDirectory: true))
        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
    }

    @Test("Each staged path is minted fresh, so no two writes can name the same tree")
    func stagedBundleURLsAreUniquePerWrite() throws {
        // An import keeps the source bundle's configuration id, so a retry after
        // an attempt whose discard failed would otherwise stage onto its tree.
        #expect(try service.makeStagedBundleURL() != (try service.makeStagedBundleURL()))
    }

    @Test("Listing bundles never admits a config-bearing bundle that is still staged")
    func listIgnoresStagedBundles() throws {
        let staged = try stageBundle(
            VMConfiguration(name: "Interrupted Write", guestOS: .linux, bootMode: .efi))

        let configURL = VMBundleLayout(bundleURL: staged).configURL
        #expect(FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)))
        #expect(!(try service.listVMBundles().contains(staged)))
    }

    @Test("Publishing renames the staged bundle into the library and makes it listable")
    func publishMakesBundleListable() throws {
        let config = VMConfiguration(name: "Published", guestOS: .linux, bootMode: .efi)

        let staged = try stageBundle(config)
        let finalURL = try service.bundleURL(for: config)

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
            _ = try makeBundle(winner)
        }
        let staged = try stageBundle(VMConfiguration(name: "Loser", guestOS: .linux, bootMode: .efi))

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
        let staged = try contenders.map { try stageBundle($0) }

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

    @Test("Reclaiming keeps a bundle another running process is staging, and this process's own")
    func reclaimKeepsBundlesLiveProcessesAreStaging() async throws {
        let other = otherProcess()
        let theirs = try stageBundle(
            VMConfiguration(name: "Theirs", guestOS: .linux, bootMode: .efi), in: other)
        let ours = try stageBundle(VMConfiguration(name: "Ours", guestOS: .linux, bootMode: .efi))

        await service.reclaimStagedBundles().value

        #expect(FileManager.default.fileExists(atPath: theirs.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: ours.path(percentEncoded: false)))
        withExtendedLifetime(other) {}
    }

    @Test("Reclaiming discards the bundles an exited process was staging")
    func reclaimDiscardsAnExitedProcessesBundles() async throws {
        let abandoned: URL
        do {
            // Deinitializing the root releases its lock, as its process's exit does.
            abandoned = try stageBundle(
                VMConfiguration(name: "Abandoned", guestOS: .linux, bootMode: .efi), in: otherProcess())
        }

        await service.reclaimStagedBundles().value

        #expect(!FileManager.default.fileExists(atPath: abandoned.path(percentEncoded: false)))
        #expect(
            !FileManager.default.fileExists(
                atPath: abandoned.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test("Reclaiming discards a bundle staged directly under the staging directory, where no lock holds it")
    func reclaimDiscardsAnUnrootedStagedBundle() async throws {
        let unrooted = service.stagingRoot.url.deletingLastPathComponent().appendingPathComponent(
            "\(UUID().uuidString).\(VMBundleFormat.fileExtension)", isDirectory: true)
        try FileManager.default.createDirectory(at: unrooted, withIntermediateDirectories: true)
        try writer(unrooted).writeInitial(
            VMConfiguration(name: "Unrooted", guestOS: .linux, bootMode: .efi))

        await service.reclaimStagedBundles().value

        #expect(!FileManager.default.fileExists(atPath: unrooted.path(percentEncoded: false)))
    }

    @Test("A clone copies only the files it was given, so it inherits no USB pairings")
    func cloneLeavesUSBPairingsBehind() throws {
        let sourceURL = try makeBundle(
            VMConfiguration(name: "Pairing Source", guestOS: .linux, bootMode: .efi))
        let cloneURL = try service.makeStagedBundleURL()
        try writer(sourceURL).update(.usbPairings) {
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
        #expect(try writer(cloneURL).update(.usbPairings) { _ in }.isEmpty)
        #expect(try !writer(sourceURL).update(.usbPairings) { _ in }.isEmpty)
    }
}
