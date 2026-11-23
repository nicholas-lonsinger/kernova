import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMLibrary Tests", .serialized, .caseScoped)
@MainActor
struct VMLibraryTests {
    private let scratch = TestScratchDirectory(prefix: "VMLibraryTests")
    /// What the library asked a user to be told, in place of a presenter.
    ///
    /// Fresh per test (the struct is re-instantiated).
    private let failures = MockLibraryFailureSink()
    private let preferences = makeTestPreferences()
    /// Records trash/remove requests so nothing ever lands in the user's Trash.
    private let fileSystem = MockFileSystem()

    private func makeLibrary(
        storageService: MockVMStorageService = MockVMStorageService(),
        virtualizationService: MockVirtualizationService = MockVirtualizationService(),
        removableMediaDeviceService: any RemovableMediaAttaching = MockRemovableMediaDeviceService(),
        linuxImageResolveService: MockLinuxImageResolveService = MockLinuxImageResolveService(),
        downloadService: MockDownloadService = MockDownloadService(),
        downloadsDirectory: URL = makeTestDownloadsDirectory(),
        vmnetNetworks: VmnetNetworkService = .scripted(),
        arpTable: ScriptedARPTable = ScriptedARPTable(),
        appActivation: HostNotification = HostNotifications.isolated().appDidBecomeActive
    ) -> (VMLibrary, MockVMStorageService, MockVirtualizationService, any RemovableMediaAttaching) {
        let library = makeWiredLibrary(
            storage: storageService,
            machineFiles: VMBundleMachineFiles(fileSystem: fileSystem, platform: FakePlatformFiles()),
            lifecycle: makeTestLifecycle(
                virtualization: virtualizationService,
                removableMedia: removableMediaDeviceService,
                linuxImageResolveService: linuxImageResolveService,
                downloadService: downloadService,
                fileSystem: fileSystem,
                downloadsDirectory: downloadsDirectory),
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: vmnetNetworks,
            arpTable: arpTable,
            appActivation: appActivation)
        library.onFailure = { [failures] title, message, subject in
            failures.record(title: title, message: message, subject: subject)
        }
        library.onUnreadableFilesFound = { [failures] in failures.recordCheckRequest() }
        return (library, storageService, virtualizationService, removableMediaDeviceService)
    }

    // MARK: - Load

    @Test("startLibrary reclaims what an interrupted run left staged")
    func startLibraryReclaimsStagedBundles() async {
        let (library, storage, _, _) = makeLibrary()

        await library.startLibrary()

        #expect(storage.reclaimStagedBundlesCallCount == 1)
        #expect(library.hasLoadedLibrary == true)
    }

    @Test("A bundle read leaves an interrupted revert's staging in place, and the launch reclaim removes it")
    func launchReclaimsRestoreStaging() async throws {
        let storage = MockVMStorageService()
        let (library, _, _, _) = makeLibrary(storageService: storage)
        let config = VMConfiguration(
            name: "Interrupted", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let bundleURL = try storage.bundleURL(for: config)
        storage.setConfiguration(config, at: bundleURL)
        let staging = VMBundleLayout(bundleURL: bundleURL).restoreStagingURL
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("half-cloned".utf8).write(to: staging.appendingPathComponent("Disk.asif"))

        _ = try library.bundleReader.read(at: bundleURL)
        #expect(FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))

        await library.startLibrary()
        #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
    }

    @Test("hasLoadedLibrary flips even when the bundle listing fails")
    func hasLoadedLibraryFlipsWhenListingFails() async {
        let storage = MockVMStorageService()
        storage.setListVMBundlesError(VMStorageError.bundleNotFound(scratch.url))

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        // The read is over and the answer is "no VMs" — the UI must not wait
        // forever on a load that already failed.
        #expect(library.hasLoadedLibrary == true)
        #expect(library.instances.isEmpty)
        #expect(failures.showError == true)
        #expect(failures.errorSubject?.isLibrary == true)
    }

    // MARK: - Configuration Writes

    @Test("A reverted configuration keeps the name and identity the bundle holds")
    func commitRevertedConfigurationKeepsTheBundleIdentity() throws {
        let (library, storage, _, _) = makeLibrary()
        let instance = library.registerFixture(name: "Loaded")
        // Another copy renamed the VM and gave it a machine identifier after
        // this one read the bundle.
        var onDisk = instance.configuration
        onDisk.name = "Renamed Elsewhere"
        onDisk.genericMachineIdentifierData = Data([0x01, 0x02, 0x03])
        storage.files.setConfiguration(onDisk, at: instance.bundleURL)
        var captured = VMConfiguration(
            name: "Captured", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        captured.memorySizeInGB = onDisk.memorySizeInGB.adding(gibibytes: 2)
        captured.genericMachineIdentifierData = Data([0x0A])

        try withOperationNow(on: instance) { context in
            try library.commitRevertedConfiguration(
                VMSnapshotRestorePlan(configuration: captured, relativePaths: [], kind: .cold),
                context.permit)
        }

        #expect(instance.configuration.name == "Renamed Elsewhere")
        #expect(instance.configuration.id == onDisk.id)
        #expect(instance.configuration.createdAt == onDisk.createdAt)
        #expect(instance.configuration.genericMachineIdentifierData == Data([0x01, 0x02, 0x03]))
        #expect(instance.configuration.memorySizeInGB == captured.memorySizeInGB)
        #expect(storage.bundles[instance.bundleURL] == instance.configuration)
    }

    // MARK: - Eviction

    @Test("reconcileWithDisk presents error when listing bundles fails")
    func reconcilePresentsErrorForFilesystemFailure() {
        let (library, storage, _, _) = makeLibrary()
        failures.reset()

        storage.setListVMBundlesError(VMStorageError.bundleNotFound(scratch.url))

        library.reconcileWithDisk()

        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("VM bundle not found") == true)
        #expect(failures.errorSubject?.isLibrary == true)
    }

    /// A present but unreadable sidecar holds state nobody knows, so the VM stays
    /// out rather than entering with defaults a later write would put over it.
    @Test("A bundle whose host state cannot be read is reported and kept as an unreadable row")
    func unreadableHostStateKeepsTheBundleOut() async throws {
        let storage = MockVMStorageService()
        let goodConfig = VMConfiguration(
            name: "Good VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let goodURL = scratch.url
            .appendingPathComponent("\(goodConfig.id.uuidString).kernova", isDirectory: true)
        storage.setConfiguration(goodConfig, at: goodURL)
        let badURL = scratch.url
            .appendingPathComponent("unreadable-host-state.kernova", isDirectory: true)
        storage.setConfiguration(
            VMConfiguration(
                name: "Bad VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize), at: badURL)
        storage.setHostStateUnreadable(true, at: badURL)

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.instances.map(\.name) == ["Good VM"])
        let row = try #require(library.entries.compactMap(\.unreadable).first)
        #expect(row.name == "Bad VM")
        #expect(row.file.location == .bundle(badURL, .hostState))
        #expect(failures.checkRequests == 1)
        #expect(storage.saveHostStateCallCount == 0)
    }

    // MARK: - USB Accessory Pairings

    /// A library over `storage`, whose bundle files hold every VM's pairings.
    private func makePairingLibrary() -> (VMLibrary, MockVMStorageService) {
        let storage = MockVMStorageService()
        // A process that passes accessories through, the only one that edits
        // pairings.
        let library = makeWiredLibrary(
            storage: storage, machineFiles: VMBundleMachineFiles(fileSystem: fileSystem, platform: FakePlatformFiles()),
            lifecycle: makeTestLifecycle(usbAccessoryPassthrough: .available(MockUSBAccessoryService())),
            fileSystem: fileSystem, preferences: preferences)
        library.onFailure = { [failures] title, message, subject in
            failures.record(title: title, message: message, subject: subject)
        }
        return (library, storage)
    }

    private func pairing(key: String) -> USBAccessoryPairing {
        USBAccessoryPairing(
            key: key, form: .serialNumber, displayName: "Samsung Type-C",
            receptacleLabel: "Port-USB-C@2", pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("Pairing an accessory takes its key off every other virtual machine")
    func pairUSBAccessoryIsLibraryWide() throws {
        let (library, _) = makePairingLibrary()
        let first = library.registerFixture(name: "First")
        let second = library.registerFixture(name: "Second")
        try library.updateUSBPairings(of: first) { $0.upsert(self.pairing(key: "k")) }

        try second.activity.edit(.pairingRules) {
            try library.pairUSBAccessory(pairing(key: "k"), $0)
        }

        #expect(first.usbPairings.isEmpty)
        #expect(second.usbPairings.pairings.map(\.key) == ["k"])
    }
}
