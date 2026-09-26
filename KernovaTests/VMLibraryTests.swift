import Testing
import Foundation
import KernovaTestSupport

@testable import Kernova

@Suite("VMLibrary Tests", .serialized, .admissionGated)
@MainActor
struct VMLibraryTests {
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
        downloadsDirectory: URL? = nil,
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        arpTable: ScriptedARPTable = ScriptedARPTable()
    ) -> (VMLibrary, MockVMStorageService, MockVirtualizationService, any RemovableMediaAttaching) {
        let library = makeWiredLibrary(
            storage: storageService,
            machineFiles: VMBundleMachineFiles(fileSystem: fileSystem),
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
            arpTable: arpTable)
        library.onFailure = { [failures] title, message in
            failures.record(title: title, message: message)
        }
        return (library, storageService, virtualizationService, removableMediaDeviceService)
    }

    // MARK: - Load

    @Test("init reads nothing — the library is loaded after launch, not during construction")
    func initDoesNotReadStorage() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        let (library, _, _, _) = makeLibrary(storageService: storage)

        #expect(storage.listVMBundlesCallCount == 0)
        #expect(library.instances.isEmpty)
        #expect(library.hasLoadedLibrary == false)
    }

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
        let config = VMConfiguration(name: "Interrupted", guestOS: .linux, bootMode: .efi)
        let bundleURL = try storage.bundleURL(for: config)
        storage.bundles[bundleURL] = config
        let staging = VMBundleLayout(bundleURL: bundleURL).restoreStagingURL
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        try Data("half-cloned".utf8).write(to: staging.appendingPathComponent("Disk.asif"))

        _ = try library.bundleReader.read(at: bundleURL)
        #expect(FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))

        await library.startLibrary()
        #expect(!FileManager.default.fileExists(atPath: staging.path(percentEncoded: false)))
    }

    @Test("hasLoadedLibrary flips once the read applies, even for an empty library")
    func hasLoadedLibraryFlipsOnEmptyLibrary() async {
        let (library, _, _, _) = makeLibrary()
        #expect(library.hasLoadedLibrary == false)

        await library.loadVMs()

        #expect(library.hasLoadedLibrary == true)
        #expect(library.instances.isEmpty)
    }

    @Test("hasLoadedLibrary flips even when the bundle listing fails")
    func hasLoadedLibraryFlipsWhenListingFails() async {
        let storage = MockVMStorageService()
        storage.listVMBundlesError = VMStorageError.bundleNotFound(
            FileManager.default.temporaryDirectory)

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        // The read is over and the answer is "no VMs" — the UI must not wait
        // forever on a load that already failed.
        #expect(library.hasLoadedLibrary == true)
        #expect(library.instances.isEmpty)
        #expect(failures.showError == true)
    }

    @Test("An arrival registered while the read is in flight survives the load")
    func loadVMsKeepsArrivalsAddedDuringTheRead() async {
        let storage = MockVMStorageService()
        let onDisk = VMConfiguration(name: "On Disk", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(onDisk.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = onDisk
        let (library, _, _, _) = makeLibrary(storageService: storage)

        let load = Task { @MainActor in await library.loadVMs() }
        // Runs behind `load`, so `loadVMs` has captured the pre-read instance
        // list and suspended on the detached scan. The append below then lands
        // in the read window, with no `await` before it for `apply` to slip in.
        await Task { @MainActor in }.value

        // An import or a wizard-created VM registered after the scan started,
        // so the scan cannot know about it.
        let gate = GatedStep()
        let arrival = library.beginGatedArrival(named: "Arrived Mid-Read", gate: gate)

        await load.value

        // The scan's result must not delete it — its bundle copy is still
        // running, and nothing else would put the row back.
        #expect(library.arrivals.map(\.id) == [arrival.id])
        #expect(library.instances.map(\.id) == [onDisk.id])
        #expect(library.entries.count == 2)

        gate.release()
        await arrival.settle()
    }

    @Test("loadVMs auto-selects the first VM")
    func loadVMsAutoSelectsFirst() async {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.instances.count == 2)
        #expect(library.selectedID == library.instances.first?.id)
    }

    @Test("loadVMs preserves valid selection on reload")
    func loadVMsPreservesSelection() async {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()
        let secondID = library.instances.last?.id
        library.selectedID = secondID

        await library.loadVMs()

        #expect(library.selectedID == secondID)
    }

    // MARK: - Selection Persistence

    @Test("selectedID persists to UserDefaults on change")
    func selectedIDPersistsToUserDefaults() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()
        library.admitForTesting(instance)

        library.selectedID = instance.id

        #expect(preferences.lastSelectedVMID == instance.id)
    }

    @Test("selectedID clears UserDefaults when set to nil")
    func selectedIDClearsUserDefaults() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()
        library.admitForTesting(instance)
        library.selectedID = instance.id

        library.selectedID = nil

        #expect(preferences.lastSelectedVMID == nil)
    }

    @Test("loadVMs restores selection from UserDefaults when VM still exists")
    func loadVMsRestoresFromUserDefaults() async {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        // Seed preferences before the load, which is what consults them
        preferences.lastSelectedVMID = config2.id

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.selectedID == config2.id)
    }

    @Test("loadVMs surfaces error when individual bundles fail to load")
    func loadVMsSurfacesErrorForFailedBundles() async {
        let storage = MockVMStorageService()
        // Add a good bundle and a bad bundle
        let goodConfig = VMConfiguration(name: "Good VM", guestOS: .linux, bootMode: .efi)
        let goodURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(goodConfig.id.uuidString).kernova", isDirectory: true)
        storage.bundles[goodURL] = goodConfig

        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bad-bundle.kernova", isDirectory: true)
        // Register the URL so listVMBundles returns it, but mark it to fail on load
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs = [badURL]

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        // Good VM loaded, bad VM skipped
        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Good VM")
        // Error surfaced to user about the failed bundle
        #expect(failures.showError == true)
        #expect(failures.errorMessage != nil)
    }

    @Test("loadVMs falls back to first VM when stored ID is invalid")
    func loadVMsFallsBackWhenStoredIDInvalid() async {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Only VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        // Seed preferences with a UUID that doesn't match any VM
        preferences.lastSelectedVMID = UUID()

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.selectedID == config.id)
    }

    // MARK: - Configuration Writes

    /// `instance`, live on a session no lifecycle call holds, registered in
    /// `library` over `storage`.
    private func registerRunning(
        _ instance: VMInstance, in library: VMLibrary, storage: MockVMStorageService
    ) -> UUID {
        library.register(instance, storage: storage)
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        return sessionID
    }

    @Test("A request whose save fails changes nothing, in memory or on the running VM")
    func discardedWriteLeavesTheOldValue() throws {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Before")
        _ = registerRunning(instance, in: library, storage: storage)
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        let saved = try library.updateConfiguration(of: instance, as: [.rename, .hotPlugMedia]) {
            $0.name = "After"
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/A.iso", readOnly: true)]
        }

        #expect(saved.failedToSave)
        #expect(instance.name == "Before")
        #expect(instance.configuration.removableMedia == nil)
        #expect(storage.bundles[instance.bundleURL]?.name == "Before")
        // No pass was launched for a list that never became the configuration.
        #expect(instance.phase.operation == nil)
        #expect(failures.showError)
    }

    @Test("A snapshot's whole configuration passes the MAC-address refusal only as the revert's own write")
    func onlyARevertCommitsPastTheMACAddressRefusal() async throws {
        let (library, storage, _, _) = makeLibrary()
        let address = "02:11:22:33:44:55"
        let snapshot = VMSnapshot(name: "Baseline", macAddress: address)
        let reverting = VMInstanceFixture.make(
            name: "Reverting", snapshots: VMSnapshotManifest(snapshots: [snapshot])
        ) { $0.macAddress = "02:66:77:88:99:aa" }
        let holder = VMInstanceFixture.make(name: "Holder") { $0.macAddress = address }
        for instance in [reverting, holder] {
            library.register(instance, storage: storage)
        }
        var captured = reverting.configuration
        captured.macAddress = address
        func install(_ permit: borrowing VMEditPermit) throws {
            try permit.bundle.commitConfiguration { $0 = $0.adoptingSnapshotState(captured) }
        }

        // An edit that may write the machine keys, and another operation's
        // own write, are refused whole.
        #expect(throws: VMLibrary.SettingsRefusal.self) {
            try reverting.activity.edit(.machineKeys, install)
        }
        #expect(throws: VMLibrary.SettingsRefusal.self) {
            try reverting.activity.performNow(.deletingSnapshot) { context in
                try install(context.permit)
                return .rest(.asStarted, ())
            }
        }
        #expect(reverting.configuration.macAddress != address)

        try await reverting.activity.bringUp(
            .reverting(snapshotID: snapshot.id, resumesAfter: false)
        ) { context in
            try install(context.operation.permit)
            return .rest(.atRest(.stopped), ())
        }
        #expect(reverting.configuration.macAddress == address)
    }

    @Test("Settling on the live media list writes that field alone and tells the VM nothing")
    func settleRemovableMediaWritesOnlyTheList() async throws {
        let (library, storage, _, _) = makeLibrary()
        let queued = RemovableMediaItem(path: "/tmp/queued.iso", readOnly: true)
        let live = RemovableMediaItem(path: "/tmp/live.iso", readOnly: true)
        let instance = VMInstanceFixture.make(name: "Mine") { $0.removableMedia = [queued] }
        _ = registerRunning(instance, in: library, storage: storage)
        let before = instance.configuration

        // The reconcile pass whose refusal the settle answers holds the VM.
        let held = try await withOperation(on: instance, .reconcilingMedia) { context in
            library.settleRemovableMedia(context.permit, toLive: [live])
            return instance.phase.operation?.kind
        }

        var expected = before
        expected.removableMedia = [live]
        #expect(instance.configuration == expected)
        #expect(storage.bundles[instance.bundleURL] == expected)
        // No second pass was launched: the reconcile still held the VM.
        #expect(held == .reconcilingMedia)
        #expect(instance.phase.operation == nil)
        #expect(!failures.showError)
    }

    @Test("Settling on the list the configuration already holds writes nothing")
    func settleRemovableMediaNoOpsWhenUnchanged() async throws {
        let (library, storage, _, _) = makeLibrary()
        let live = RemovableMediaItem(path: "/tmp/live.iso", readOnly: true)
        let instance = VMInstanceFixture.make { $0.removableMedia = [live] }
        _ = registerRunning(instance, in: library, storage: storage)
        let saves = storage.saveConfigurationCallCount

        try await withOperation(on: instance, .reconcilingMedia) { context in
            library.settleRemovableMedia(context.permit, toLive: [live])
        }

        #expect(storage.saveConfigurationCallCount == saves)
    }

    @Test("A settle whose write fails is reported and memory stays as the bundle holds it")
    func settleRemovableMediaWhoseWriteFailsKeepsTheBundleList() async throws {
        let (library, storage, _, _) = makeLibrary()
        let queued = [RemovableMediaItem(path: "/tmp/queued.iso", readOnly: true)]
        let instance = VMInstanceFixture.make { $0.removableMedia = queued }
        _ = registerRunning(instance, in: library, storage: storage)
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        try await withOperation(on: instance, .reconcilingMedia) { context in
            library.settleRemovableMedia(context.permit, toLive: nil)
        }

        #expect(instance.configuration.removableMedia == queued)
        #expect(storage.bundles[instance.bundleURL]?.removableMedia == queued)
        #expect(failures.showError)
    }

    @Test("A reverted configuration is committed as captured, with nothing refused")
    func commitRevertedConfigurationWritesWithoutRefusing() async throws {
        let (library, storage, _, _) = makeLibrary()
        let other = VMInstanceFixture.make(name: "Other") {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:01"
        }
        let snapshot = VMSnapshot(name: "Baseline", macAddress: "aa:bb:cc:dd:ee:01")
        let instance = VMInstanceFixture.make(
            name: "Mine", snapshots: VMSnapshotManifest(snapshots: [snapshot])
        ) {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:02"
        }
        library.register(other, storage: storage)
        library.register(instance, storage: storage)
        var written = instance.configuration
        written.macAddress = "aa:bb:cc:dd:ee:01"
        written.memorySizeInGB += 2
        let saves = storage.saveConfigurationCallCount

        try await instance.activity.bringUp(
            .reverting(snapshotID: snapshot.id, resumesAfter: false)
        ) { context in
            try library.commitRevertedConfiguration(
                VMSnapshotRestorePlan(configuration: written, relativePaths: [], kind: .cold),
                context.operation.permit)
            return .rest(.asStarted, ())
        }

        #expect(instance.configuration == written)
        #expect(storage.bundles[instance.bundleURL] == written)
        #expect(storage.saveConfigurationCallCount == saves + 1)
        #expect(!failures.showError)
    }

    @Test("A reverted configuration keeps the name and identity the bundle holds")
    func commitRevertedConfigurationKeepsTheBundleIdentity() throws {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Loaded")
        library.register(instance, storage: storage)
        // Another copy renamed the VM and gave it a machine identifier after
        // this one read the bundle.
        var onDisk = instance.configuration
        onDisk.name = "Renamed Elsewhere"
        onDisk.genericMachineIdentifierData = Data([0x01, 0x02, 0x03])
        storage.files.setConfiguration(onDisk, at: instance.bundleURL)
        var captured = VMConfiguration(name: "Captured", guestOS: .linux, bootMode: .efi)
        captured.memorySizeInGB = onDisk.memorySizeInGB + 2
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

    @Test(
        "An updateSettings whose host-state write fails reports that the configuration landed, and memory equals both files"
    )
    func updateSettingsWhoseHostStateWriteFailsReportsTheConfigurationLanded() throws {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()
        library.register(instance, storage: storage)
        let memory = instance.configuration.memorySizeInGB
        storage.saveHostStateError = NSError(domain: "test", code: 1)

        let outcome = try library.updateSettings(
            of: instance, as: [.machineKeys, .liveKeys],
            configuration: { $0.memorySizeInGB = memory + 2 },
            hostState: { $0.startsAutomaticallyOnLaunch = true })

        guard case .notSaved(let failure) = outcome else {
            Issue.record("expected a partial write, got \(outcome)")
            return
        }
        #expect(failure.failed == .hostState)
        #expect(failure.landed == [.configuration])
        #expect(instance.configuration.memorySizeInGB == memory + 2)
        #expect(!instance.hostState.startsAutomaticallyOnLaunch)
        #expect(instance.configuration == storage.bundles[instance.bundleURL])
        #expect(instance.hostState == storage.hostStates[instance.bundleURL])
        #expect(failures.showError)
    }

    @Test("An arrival becomes a VM holding the configuration its write put in the bundle")
    func arrivalAdoptsTheWrittenConfiguration() async throws {
        let (library, storage, _, _) = makeLibrary()
        let requested = VMConfiguration(name: "Copy", guestOS: .linux, bootMode: .efi)
        var written = requested
        written.storageDisks = [
            StorageDisk(
                path: "AdditionalDisks/\(UUID().uuidString).asif", readOnly: false,
                label: "Remapped", isInternal: true, kind: .virtio)
        ]
        let published = written

        let arrival = library.beginArrival(
            kind: .creating, configuration: requested,
            destination: try storage.bundleURL(for: requested)
        ) { staged in
            try storage.createVMBundle(at: staged)
            try VMBundleFiles(url: staged, access: storage.bundleFiles).writeInitial(published)
        }
        let instance = try await arrival.settled.value

        // What the bundle holds, which is the written configuration as its
        // coding keeps it.
        #expect(instance.configuration == storage.bundles[instance.bundleURL])
        #expect(instance.configuration.storageDisks == published.storageDisks)
        #expect(library.arrivals.isEmpty)
        #expect(library.instances.map(\.id) == [requested.id])
    }

    // MARK: - Guest Addresses

    @Test("A running VM switched live onto Shared is watched until its address is seen")
    func liveSwitchOntoSharedWatchesTheGuest() async throws {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedSubnets = [.shared: .scripted("192.168.64.0")]
        let table = ScriptedARPTable([
            .scripted("192.168.64.4", mac: "aa:bb:cc:dd:ee:01", expiry: ARPEntry.freshExpiry)
        ])
        let (library, _, _, _) = makeLibrary(vmnetNetworks: vmnet, arpTable: table)
        let instance = VMInstanceFixture.make(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.macAddress = "aa:bb:cc:dd:ee:01"
        }
        library.admitForTesting(instance)
        library.guestAddresses.watch()
        // Bridged is nothing the table answers for, so nothing is read.
        #expect(library.guestAddresses.readTaskForTesting == nil)

        try library.updateConfiguration(of: instance, as: .networkAttachment) {
            $0.networkMode = .shared
        }

        let loop = try #require(library.guestAddresses.readTaskForTesting)
        try await waitForChange {
            library.guestAddresses.address(for: instance) == .observed("192.168.64.4")
        }
        loop.cancel()
        await loop.value
    }

    // MARK: - Selected Instance

    @Test("selectedInstance returns the instance matching selectedID")
    func selectedInstance() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()
        library.admitForTesting(instance)
        library.selectedID = instance.id

        #expect(library.selectedInstance?.id == instance.id)
    }

    @Test("selectedInstance returns nil when no match")
    func selectedInstanceNil() {
        let (library, _, _, _) = makeLibrary()
        library.selectedID = UUID()

        #expect(library.selectedInstance == nil)
    }

    // MARK: - Reconcile With Disk

    @Test("reconcileWithDisk adds discovered bundles not in memory")
    func reconcileAddsNewBundles() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Discovered VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[bundleURL] = config

        // The library is never loaded here, so the bundle is on disk and absent
        // from memory — exactly what reconciliation is for.
        let (library, _, _, _) = makeLibrary(storageService: storage)

        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Discovered VM")
    }

    @Test("reconcileWithDisk removes stopped VMs whose bundles are gone")
    func reconcileRemovesStoppedVMs() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Gone VM")
        instance.activity.placeForTesting(.stopped)
        library.admitForTesting(instance)

        // Storage has no bundles, so instance should be removed
        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
    }

    @Test("Evicting a VM whose bundle is gone drops its held guest-account password")
    func reconcileDropsTheHeldGuestAccountPassword() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Gone VM")
        instance.activity.placeForTesting(.stopped)
        library.admitForTesting(instance)
        library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance.id)

        // Storage has no bundles, so the VM is evicted — and eviction is where a
        // held answer goes, whichever way the VM left the library.
        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
        #expect(library.heldGuestAccountPassword(for: instance) == nil)
    }

    @Test("reconcileWithDisk preserves running VMs even if bundle is missing")
    func reconcilePreservesRunningVMs() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Running VM")
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        library.admitForTesting(instance)

        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Running VM")
    }

    // MARK: - Eviction (F16)

    @Test("A cold-suspended VM whose bundle is removed is evicted")
    func aColdSuspendedVMWhoseBundleIsRemovedIsEvicted() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = RegisteredVMInstanceFixture.register(
            name: "Suspended", phase: .suspended, guestOS: .linux, library: library,
            storage: storage, preferences: makeTestPreferences())

        storage.files.removeBundle(at: instance.bundleURL)
        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
    }

    @Test("A live-paused VM whose bundle is removed is kept")
    func aLivePausedVMWhoseBundleIsRemovedIsKept() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = RegisteredVMInstanceFixture.register(
            name: "Paused", phase: .livePaused(sessionID: UUID()), guestOS: .linux,
            library: library, storage: storage, preferences: makeTestPreferences())

        storage.files.removeBundle(at: instance.bundleURL)
        library.reconcileWithDisk()

        #expect(library.instances.first === instance)
    }

    @Test("A VM at rest with an operation in flight is kept when its bundle is removed")
    func aVMWithAnOperationInFlightIsKept() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = RegisteredVMInstanceFixture.register(
            name: "Reverting", phase: .stopped, guestOS: .linux, library: library,
            storage: storage, preferences: makeTestPreferences())
        instance.activity.placeForTesting(
            .operating(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped))

        storage.files.removeBundle(at: instance.bundleURL)
        library.reconcileWithDisk()

        #expect(library.instances.first === instance)
    }

    /// ``VMLifecyclePhase/suspended`` names a session on disk, so a slot removed
    /// out of band leaves the phase describing something that is not there —
    /// every predicate that asks the bundle has already moved on.
    @Test("reconcileWithDisk rests a suspension whose slot has left the bundle")
    func reconcileNormalizesAnEmptiedSuspension() throws {
        let (library, storage, _, _) = makeLibrary()
        let holding = VMInstanceFixture.make(name: "Still suspended")
        holding.activity.placeForTesting(.suspended)
        defer { VMInstanceFixture.removeBundle(of: holding) }
        try VMInstanceFixture.writeSaveFile(for: holding)
        let emptied = VMInstanceFixture.make(name: "Slot gone")
        emptied.activity.placeForTesting(.suspended)
        // Both bundles are on disk, so the pass has read them and what it found
        // inside them stands.
        storage.bundles[holding.bundleURL] = holding.configuration
        storage.bundles[emptied.bundleURL] = emptied.configuration
        library.admitForTesting([holding, emptied])

        library.reconcileWithDisk()

        #expect(emptied.phase == .stopped)
        // The one whose slot is still there is left naming it.
        #expect(holding.phase == .suspended)
    }

    @Test("reconcileWithDisk leaves a suspension alone when it could not read the bundle")
    func reconcileLeavesAnUnreadBundlesSuspensionAlone() {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Bundle out of sight")
        instance.activity.placeForTesting(.suspended)
        // Listed, but its configuration cannot be read this pass.
        storage.bundles[instance.bundleURL] = instance.configuration
        storage.loadConfigurationFailURLs = [instance.bundleURL]
        library.admitForTesting(instance)

        library.reconcileWithDisk()

        // A bundle the scan could not read says nothing about the slot inside
        // it, and the eviction pass keeps a VM whose bundle is still listed.
        #expect(library.instances.count == 1)
        #expect(instance.phase == .suspended)
    }

    @Test("reconcileWithDisk updates selection when selected stopped VM is removed")
    func reconcileUpdatesSelection() {
        let (library, storage, _, _) = makeLibrary()
        let remaining = VMInstanceFixture.make(name: "Remaining")
        let removed = VMInstanceFixture.make(name: "Removed")
        removed.activity.placeForTesting(.stopped)
        library.admitForTesting([remaining, removed])
        library.selectedID = removed.id

        // Only keep the remaining instance's bundle on disk
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(remaining.id.uuidString).kernova", isDirectory: true)
        storage.bundles = [bundleURL: remaining.configuration]

        library.reconcileWithDisk()

        #expect(library.selectedID == remaining.id || library.selectedID != removed.id)
    }

    @Test("reconcileWithDisk presents error when config loading fails")
    func reconcilePresentsErrorForFailedConfigs() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Good VM", guestOS: .linux, bootMode: .efi)
        let goodURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[goodURL] = config

        // Create library first (no bad bundles yet)
        let (library, _, _, _) = makeLibrary(storageService: storage)

        // Introduce the bad bundle after construction so it is new to reconcileWithDisk
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        failures.reset()

        library.reconcileWithDisk()

        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("broken-vm") == true)
        #expect(library.instances.contains { $0.name == "Good VM" })
    }

    @Test("reconcileWithDisk presents error when listing bundles fails")
    func reconcilePresentsErrorForFilesystemFailure() {
        let (library, storage, _, _) = makeLibrary()
        failures.reset()

        storage.listVMBundlesError = VMStorageError.bundleNotFound(
            FileManager.default.temporaryDirectory
        )

        library.reconcileWithDisk()

        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("VM bundle not found") == true)
    }

    @Test("reconcileWithDisk does not re-present error for already-reported corrupted bundles")
    func reconcileDeduplicatesFailedBundleErrors() {
        let storage = MockVMStorageService()
        let (library, _, _, _) = makeLibrary(storageService: storage)

        // Introduce the bad bundle after construction so it is new to reconcileWithDisk
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // First reconciliation should present the error
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("broken-vm") == true)

        // Second reconciliation should NOT re-present the same error
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.showError == false)
        #expect(failures.errorMessage == nil)
    }

    @Test("reconcileWithDisk suppression is maintained after full reload")
    func reconcileSuppressionMaintainedAfterReload() async {
        let storage = MockVMStorageService()
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // The initial load reports the error and seeds reportedFailedBundles
        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("broken-vm") == true)

        // First reconcile after the load is suppressed
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.showError == false)

        // Full reload resets suppression, then re-seeds from its own failures
        await library.loadVMs()
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("broken-vm") == true)

        // Reconciliation should still be suppressed since loadVMs re-seeded the set
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.showError == false)
    }

    @Test("reconcileWithDisk does not re-present errors already reported by loadVMs")
    func reconcileDoesNotDuplicateLoadVMsErrors() async {
        let storage = MockVMStorageService()
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // The initial load should report the error
        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("broken-vm") == true)

        // Clear the alert state (simulating user dismissing the dialog)
        failures.reset()

        // First reconcileWithDisk should NOT re-present the same error
        library.reconcileWithDisk()
        #expect(failures.showError == false)
        #expect(failures.errorMessage == nil)
    }

    /// A present but unreadable sidecar holds state nobody knows, so the VM stays
    /// out rather than entering with defaults a later write would put over it.
    @Test("A bundle whose host state cannot be read is reported and not loaded")
    func unreadableHostStateKeepsTheBundleOut() async {
        let storage = MockVMStorageService()
        let goodConfig = VMConfiguration(name: "Good VM", guestOS: .linux, bootMode: .efi)
        let goodURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(goodConfig.id.uuidString).kernova", isDirectory: true)
        storage.bundles[goodURL] = goodConfig
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreadable-host-state.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadHostStateFailURLs = [badURL]

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.instances.map(\.name) == ["Good VM"])
        #expect(failures.errorMessage?.contains("unreadable-host-state") == true)
        #expect(storage.saveHostStateCallCount == 0)
    }

    /// Pairings are made again by attaching the device once, so an unreadable
    /// file costs the VM nothing more than them.
    @Test("A bundle whose pairings cannot be read loads with none, is reported, and keeps the file")
    func unreadablePairingsLoadEmpty() async throws {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Paired VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = try storage.bundleURL(for: config)
        storage.bundles[bundleURL] = config
        let unreadable = Data("{ not json".utf8)
        storage.files.setData(
            unreadable, atRelativePath: VMBundleLayout.usbPairingsRelativePath, in: bundleURL)

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.instances.map(\.name) == ["Paired VM"])
        #expect(library.instances.first?.usbPairings.isEmpty == true)
        #expect(
            storage.files.data(atRelativePath: VMBundleLayout.usbPairingsRelativePath, in: bundleURL)
                == unreadable)
        #expect(failures.errorMessage?.contains("Paired VM") == true)
    }

    @Test("reconcileWithDisk keeps out, and reports once, a new bundle whose host state cannot be read")
    func reconcileKeepsOutAnUnreadableHostState() {
        let storage = MockVMStorageService()
        let (library, _, _, _) = makeLibrary(storageService: storage)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("unreadable-sidecar.kernova", isDirectory: true)
        storage.bundles[bundleURL] = VMConfiguration(
            name: "Unreadable VM", guestOS: .linux, bootMode: .efi)
        storage.loadHostStateFailURLs.insert(bundleURL)

        failures.reset()
        library.reconcileWithDisk()
        #expect(library.instances.isEmpty)
        #expect(failures.errorMessage?.contains("unreadable-sidecar") == true)

        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.showError == false)

        storage.loadHostStateFailURLs.remove(bundleURL)
        library.reconcileWithDisk()
        #expect(library.instances.map(\.name) == ["Unreadable VM"])
    }

    @Test("reconcileWithDisk re-presents error after previously-failed bundle loads successfully")
    func reconcileReReportsAfterBundleRecovery() {
        let storage = MockVMStorageService()
        let (library, _, _, _) = makeLibrary(storageService: storage)

        // Introduce the bad bundle after construction so it is new to reconcileWithDisk
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recoverable.kernova", isDirectory: true)
        let config = VMConfiguration(name: "Recoverable VM", guestOS: .linux, bootMode: .efi)
        storage.bundles[bundleURL] = config
        storage.loadConfigurationFailURLs.insert(bundleURL)

        // First reconciliation reports the error
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("recoverable") == true)

        // "Fix" the bundle by removing it from the fail set
        storage.loadConfigurationFailURLs.remove(bundleURL)

        // Reconciliation succeeds — no error, and the bundle is cleared from reported set
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.showError == false)

        // Re-corrupt it
        storage.loadConfigurationFailURLs.insert(bundleURL)
        // Remove the instance that was added on successful load so reconciliation tries again
        for instance in library.instances where instance.name == "Recoverable VM" {
            library.evict(instance)
        }

        // Should report the error again since it was cleared from the reported set
        library.reconcileWithDisk()
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("recoverable") == true)
    }

    // MARK: - Initial Boot status assignment

    @Test("loadVMs assigns .initialBoot when config has installContext")
    func loadVMsAssignsInitialBoot() async {
        let storage = MockVMStorageService()
        var config = VMConfiguration(name: "Pending VM", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/tmp/restore.ipsw"
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.instances.count == 1)
        #expect(library.instances[0].status == .initialBoot)
    }

    @Test("loadVMs assigns .stopped when no installContext")
    func loadVMsAssignsStoppedWithoutInstallContext() async {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Installed VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.instances.count == 1)
        #expect(library.instances[0].status == .stopped)
    }

    @Test("reconcileWithDisk removes .initialBoot VMs whose bundles vanish")
    func reconcileRemovesInitialBootVMs() {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(
            name: "Pending VM", guestOS: .macOS, phase: .initialBoot
        ) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        library.admitForTesting(instance)
        // Bundle is NOT in storage.bundles — simulating an on-disk deletion.

        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
        // Note: deleteVMBundle is NOT called — reconcile only evicts the in-memory entry.
        #expect(storage.deleteVMBundleCallCount == 0)
    }

    @Test("reconcileWithDisk keeps an orphaned VM its setup holds, and evicts it once at rest")
    func reconcileKeepsAVMItsSetupHolds() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(
            name: "Pending VM", guestOS: .macOS, phase: .initialBoot
        ) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }
        instance.activity.placeForTesting(
            .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot))
        library.admitForTesting(instance)
        // Bundle absent from storage → eligible for eviction once nothing holds it.

        library.reconcileWithDisk()

        // Evicting it now would leave the setup mutating a VM the library no
        // longer knows about.
        #expect(library.instances.first === instance)

        instance.activity.placeForTesting(.initialBoot)
        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
        #expect(instance.phase == .removed)
    }

    // MARK: - Reconcile With Disk (Arrivals)

    @Test("reconcileWithDisk leaves an arrival in flight in place")
    func reconcilePreservesArrivals() async {
        let (library, _, _, _) = makeLibrary()
        let gate = GatedStep()
        let arrival = library.beginGatedArrival(named: "Preparing VM", gate: gate)

        // Storage lists no bundle — the arrival's is still under the staging
        // directory, which no listing admits.
        library.reconcileWithDisk()

        #expect(library.arrivals.map(\.id) == [arrival.id])
        #expect(library.entries.map(\.name) == ["Preparing VM"])

        gate.release()
        await arrival.settle()
    }

    // MARK: - USB Accessory Pairings

    /// A library over `storage`, whose bundle files hold every VM's pairings.
    private func makePairingLibrary() -> (VMLibrary, MockVMStorageService) {
        let storage = MockVMStorageService()
        // A build that passes accessories through, the only one that edits
        // pairings.
        let library = makeWiredLibrary(
            storage: storage, machineFiles: VMBundleMachineFiles(fileSystem: fileSystem),
            lifecycle: makeTestLifecycle(usbAccessoryService: MockUSBAccessoryService()),
            fileSystem: fileSystem, preferences: preferences)
        library.onFailure = { [failures] title, message in
            failures.record(title: title, message: message)
        }
        return (library, storage)
    }

    private func pairing(key: String) -> USBAccessoryPairing {
        USBAccessoryPairing(
            key: key, form: .serialNumber, displayName: "Samsung Type-C",
            receptacleLabel: "Port-USB-C@2", pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("A loaded VM mirrors the pairings its bundle holds")
    func loadMirrorsPairings() async throws {
        let (library, storage) = makePairingLibrary()
        let config = VMConfiguration(name: "Paired VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = try storage.bundleURL(for: config)
        storage.bundles[bundleURL] = config
        storage.files.setPairings(USBAccessoryPairingSet(pairings: [pairing(key: "k")]), at: bundleURL)

        await library.loadVMs()

        #expect(library.instances.first?.usbPairings.pairings.map(\.key) == ["k"])
    }

    @Test("An arrival's VM takes on its bundle's pairings when it publishes, and not before")
    func publicationMirrorsPairings() async throws {
        let (library, storage) = makePairingLibrary()
        let written = VMConfiguration(name: "Fresh VM", guestOS: .linux, bootMode: .efi)
        let pairings = USBAccessoryPairingSet(pairings: [pairing(key: "k")])
        let gate = GatedStep()

        let arrival = library.beginArrival(
            kind: .importing, configuration: written,
            destination: try storage.bundleURL(for: written)
        ) { staged in
            try await gate.pass()
            try storage.createVMBundle(at: staged)
            let files = VMBundleFiles(url: staged, access: storage.bundleFiles)
            try files.writeInitial(written)
            try files.update(.usbPairings) { $0 = pairings }
        }
        // Registered, but no VM exists yet to hold any pairing.
        #expect(library.instances.isEmpty)
        #expect(library.arrivals.map(\.id) == [arrival.id])

        gate.release()
        let instance = try await arrival.settled.value

        #expect(instance.usbPairings.pairings.map(\.key) == ["k"])
    }

    @Test("A bundle with no pairings mirrors an empty set")
    func loadMirrorsNoPairingsForAFreshBundle() async throws {
        let (library, storage) = makePairingLibrary()
        let config = VMConfiguration(name: "Fresh VM", guestOS: .linux, bootMode: .efi)
        storage.bundles[try storage.bundleURL(for: config)] = config

        await library.loadVMs()

        // A clone's bundle is a fresh directory, and the pairing file is
        // not among the ones a clone copies — so the clone starts
        // expecting nothing, rather than racing its source for one device.
        #expect(library.instances.first?.usbPairings.isEmpty == true)
    }

    @Test("updateUSBPairings writes the bundle, and writes nothing when nothing changed")
    func updateUSBPairingsPersistsAndNoOps() throws {
        let (library, storage) = makePairingLibrary()
        let instance = VMInstanceFixture.make(name: "Paired VM")
        library.register(instance, storage: storage)
        let path = VMBundleLayout.usbPairingsRelativePath

        try library.updateUSBPairings(of: instance) { $0.upsert(self.pairing(key: "k")) }
        #expect(storage.files.pairings(at: instance.bundleURL)?.pairings.map(\.key) == ["k"])
        #expect(storage.files.replaceCount(of: path) == 1)

        // Removing a key the VM never held leaves the set as it was.
        try library.updateUSBPairings(of: instance) { $0.remove(key: "absent") }
        #expect(storage.files.replaceCount(of: path) == 1)
    }

    @Test("A pairing write that fails throws and leaves memory as the bundle holds it")
    func updateUSBPairingsThrowsOnAFailedWrite() {
        let (library, storage) = makePairingLibrary()
        let instance = VMInstanceFixture.make(name: "Paired VM")
        library.register(instance, storage: storage)
        storage.files.setReplaceError(
            VMStorageError.bundleNotFound(instance.bundleURL),
            for: VMBundleLayout.usbPairingsRelativePath)

        #expect(throws: VMStorageError.self) {
            try library.updateUSBPairings(of: instance) { $0.upsert(self.pairing(key: "k")) }
        }

        #expect(instance.usbPairings.isEmpty)
        #expect(storage.files.pairings(at: instance.bundleURL)?.isEmpty == true)
    }

    @Test("Pairing an accessory takes its key off every other virtual machine")
    func pairUSBAccessoryIsLibraryWide() throws {
        let (library, storage) = makePairingLibrary()
        let first = VMInstanceFixture.make(name: "First")
        let second = VMInstanceFixture.make(name: "Second")
        for instance in [first, second] {
            library.register(instance, storage: storage)
        }
        try library.updateUSBPairings(of: first) { $0.upsert(self.pairing(key: "k")) }

        try second.activity.edit(.pairingRules) {
            try library.pairUSBAccessory(pairing(key: "k"), $0)
        }

        #expect(first.usbPairings.isEmpty)
        #expect(second.usbPairings.pairings.map(\.key) == ["k"])
    }

    @Test("A pairing is not moved off a VM that takes no pairing edit, and lands nowhere")
    func pairUSBAccessoryRefusedByAHeldOtherVM() throws {
        let (library, storage) = makePairingLibrary()
        let first = VMInstanceFixture.make(name: "First")
        let second = VMInstanceFixture.make(name: "Second")
        for instance in [first, second] {
            library.register(instance, storage: storage)
        }
        try library.updateUSBPairings(of: first) { $0.upsert(self.pairing(key: "k")) }
        first.activity.placeForTesting(.operating(.deleting, from: .stopped))

        let refused = #expect(throws: VMLibrary.PairingMoveRefused.self) {
            try second.activity.edit(.pairingRules) {
                try library.pairUSBAccessory(pairing(key: "k"), $0)
            }
        }

        #expect(refused?.holder === first)
        #expect(refused?.refusal == VMAdmissionRefusal(refusal: .busy(.deleting)))
        #expect(first.usbPairings.pairings.map(\.key) == ["k"])
        #expect(second.usbPairings.isEmpty)
    }
}
