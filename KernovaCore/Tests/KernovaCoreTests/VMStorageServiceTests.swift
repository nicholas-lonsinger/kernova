import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Synchronization
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMStorageService Tests", .caseScoped)
struct VMStorageServiceTests {
    /// The library this test owns: the test host is the app, so
    /// ``VMStorageService/productionLibraryDirectory`` is the maintainer's
    /// real library.
    private let library = TestScratchDirectory(prefix: "KernovaTestLibrary")
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

    @Test("Deleting non-existent bundle throws error")
    func deleteNonExistentThrows() {
        let fakeURL = library.url.appendingPathComponent("nonexistent-vm-bundle")

        #expect(throws: VMStorageError.self) {
            try service.deleteVMBundle(at: fakeURL)
        }
    }

    @Test("Permanently deleting a suspended VM's bundle takes its saved state with it")
    func permanentlyDeleteBundleRemovesSaveFile() throws {
        let config = VMConfiguration(
            name: "Suspended Delete VM",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize
        )

        let bundleURL = try makeBundle(config)
        let saveFileURL = VMBundleLayout(bundleURL: bundleURL).saveFileURL
        try Data("saved state".utf8).write(to: saveFileURL)
        #expect(FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false)))

        try service.permanentlyDeleteVMBundle(at: bundleURL)

        #expect(!FileManager.default.fileExists(atPath: saveFileURL.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: bundleURL.path(percentEncoded: false)))
    }

    // MARK: - Bundle Identity

    @Test("A bundle's identity follows the directory across a rename, and a place with no bundle has none")
    func bundleIdentityFollowsTheDirectory() throws {
        let first = try makeBundle(
            VMConfiguration(
                name: "First", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))
        let second = try makeBundle(
            VMConfiguration(
                name: "Second", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))
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
        .enabled(if: TestScratchDirectory.volumeFoldsCase))
    func bundleIdentityIsTheVolumes() throws {
        let url = try makeBundle(
            VMConfiguration(
                name: "Folded", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))
        let respelled = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent.lowercased(), isDirectory: true)
        #expect(VMBundleIdentity.spelling(respelled) != VMBundleIdentity.spelling(url))

        #expect(service.bundleIdentity(at: respelled) == service.bundleIdentity(at: url))
    }

    // MARK: - Bundle Extension

    @Test("Bundle URL has .kernova extension")
    func bundleURLHasKernovaExtension() throws {
        let config = VMConfiguration(
            name: "Extension Test",
            guestOS: .linux,
            bootMode: .efi,
            cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize
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

    @Test("Listing bundles never admits a config-bearing bundle that is still staged")
    func listIgnoresStagedBundles() throws {
        let staged = try stageBundle(
            VMConfiguration(
                name: "Interrupted Write", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))

        let configURL = VMBundleLayout(bundleURL: staged).configURL
        #expect(FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)))
        #expect(!(try service.listVMBundles().contains(staged)))
    }

    @Test("Publishing renames the staged bundle into the library and makes it listable")
    func publishMakesBundleListable() throws {
        let config = VMConfiguration(
            name: "Published", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)

        let staged = try stageBundle(config)
        let finalURL = try service.bundleURL(for: config)

        try service.publishBundle(from: staged, to: finalURL)

        #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: finalURL.path(percentEncoded: false)))
        // By resolved path: outside a sandbox the scratch library is under
        // `/var`, which a directory listing spells `/private/var`.
        #expect(
            try service.listVMBundles().map { $0.resolvingSymlinksInPath().path }
                .contains(finalURL.resolvingSymlinksInPath().path))
        #expect(try files(finalURL).readConfiguration().id == config.id)
    }

    @Test(
        "Of two publishes to one name the loser gets exists, and the winner's bundle is intact",
        arguments: [false, true])
    func ofTwoPublishesToOneNameTheLoserGetsExists(destinationIsEmpty: Bool) throws {
        let winner = VMConfiguration(
            name: "Winner", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let finalURL = try service.bundleURL(for: winner)
        if destinationIsEmpty {
            // An empty directory is still an occupied name: `rename(2)` alone
            // would replace it.
            try FileManager.default.createDirectory(at: finalURL, withIntermediateDirectories: true)
        } else {
            _ = try makeBundle(winner)
        }
        let staged = try stageBundle(
            VMConfiguration(
                name: "Loser", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))

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

    @Test("Reclaiming keeps a bundle another running process is staging, and this process's own")
    func reclaimKeepsBundlesLiveProcessesAreStaging() async throws {
        let other = otherProcess()
        let theirs = try stageBundle(
            VMConfiguration(
                name: "Theirs", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize), in: other)
        let ours = try stageBundle(
            VMConfiguration(
                name: "Ours", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))

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
                VMConfiguration(
                    name: "Abandoned", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                    memorySizeInGB: VMGuestOS.linux.hostMemorySize), in: otherProcess())
        }

        await service.reclaimStagedBundles().value

        #expect(!FileManager.default.fileExists(atPath: abandoned.path(percentEncoded: false)))
        #expect(
            !FileManager.default.fileExists(
                atPath: abandoned.deletingLastPathComponent().path(percentEncoded: false)))
    }

    @Test("A clone copies only the files it was given, so it inherits no USB pairings")
    func cloneLeavesUSBPairingsBehind() throws {
        let sourceURL = try makeBundle(
            VMConfiguration(
                name: "Pairing Source", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))
        let cloneURL = try service.makeStagedBundleURL()
        try writer(sourceURL).update(.usbPairings) {
            $0 = USBAccessoryPairingSet(pairings: [
                USBAccessoryPairing(
                    key: "04e8:6300:0100:0373", form: .serialNumber, displayName: "Samsung Type-C",
                    receptacleLabel: "Port-USB-C@2")
            ])
        }

        try service.cloneVMBundle(
            from: sourceURL, to: cloneURL, relativePaths: ["Disk.asif", "EFIVariableStore"])

        // The omission is silent by construction — nothing lists the file — so
        // it is asserted here: two VMs expecting one device would race for it.
        // A change that moves nothing answers what the file holds.
        #expect(try writer(cloneURL).update(.usbPairings) { _ in }.isEmpty)
        #expect(try !writer(sourceURL).update(.usbPairings) { _ in }.isEmpty)
    }
}
