import Foundation
import KernovaCommandModel
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

    @Test("Publishing a staged bundle dates it as added to the library then, and a write inside it leaves that date")
    func publicationDatesABundleAndAWriteInsideLeavesIt() throws {
        func configuration(_ name: String) -> VMConfiguration {
            VMConfiguration(
                name: name, guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        }
        let second = configuration("Second")
        let first = configuration("First")
        // Staged in the other order, so a date the staging directory gave
        // would order them the other way.
        let stagedSecond = try stageBundle(second)
        let stagedFirst = try stageBundle(first)
        let firstURL = try service.bundleURL(for: first)
        let secondURL = try service.bundleURL(for: second)
        try service.publishBundle(from: stagedFirst, to: firstURL)
        try service.publishBundle(from: stagedSecond, to: secondURL)
        let access = CoordinatedBundleFileAccess()
        let firstAdded = try #require(access.dateAdded(ofBundleAt: firstURL))
        let secondAdded = try #require(access.dateAdded(ofBundleAt: secondURL))

        try writer(firstURL).update(.configuration) { $0.name = "Renamed" }

        #expect(firstAdded < secondAdded)
        #expect(access.dateAdded(ofBundleAt: firstURL) == firstAdded)
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

        try await service.reclaimStagedBundles().joined()

        #expect(FileManager.default.fileExists(atPath: theirs.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: ours.path(percentEncoded: false)))
        withExtendedLifetime(other) {}
    }

    @Test("A clone of a bundle whose disk is a symbolic link is refused, naming the link")
    func cloneOfALinkedDiskIsRefused() throws {
        let sourceURL = try makeBundle(
            VMConfiguration(
                name: "Linked Source", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize))
        let moved = library.url.appendingPathComponent("Moved.asif")
        try Data("disk".utf8).write(to: moved)
        let disk = VMBundleLayout(bundleURL: sourceURL).diskImageURL
        try FileManager.default.createSymbolicLink(at: disk, withDestinationURL: moved)
        let cloneURL = try service.makeStagedBundleURL()

        #expect(throws: VMBundleItems.SymbolicLinkError(url: disk)) {
            try service.cloneVMBundle(from: sourceURL, to: cloneURL, relativePaths: ["Disk.asif"])
        }

        #expect(
            !FileManager.default.fileExists(
                atPath: VMBundleLayout(bundleURL: cloneURL).diskImageURL.path(percentEncoded: false)))
    }
}
