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
            snapshotStore: VMSnapshotStore(),
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

    /// Helper to mark an instance as preparing with a no-op task.
    private func markPreparing(
        _ instance: VMInstance,
        operation: VMInstance.PreparingOperation = .cloning(sourceID: UUID())
    ) {
        instance.preparingState = VMInstance.PreparingState(operation: operation, task: Task {})
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

    @Test("A VM registered while the read is in flight survives the load")
    func loadVMsKeepsInstancesAddedDuringTheRead() async {
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

        // Stands in for an import phantom or a wizard-created VM: registered
        // after the scan started, so the scan cannot know about it.
        let arrival = VMInstanceFixture.make(name: "Arrived Mid-Read")
        library.instances.append(arrival)

        await load.value

        // The scan's result must not delete it — its bundle copy may still be
        // running, and nothing else would put the row back.
        #expect(library.instances.contains { $0.id == arrival.id })
        #expect(library.instances.contains { $0.id == onDisk.id })
        #expect(library.instances.count == 2)
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
        library.instances.append(instance)

        library.selectedID = instance.id

        #expect(preferences.lastSelectedVMID == instance.id)
    }

    @Test("selectedID clears UserDefaults when set to nil")
    func selectedIDClearsUserDefaults() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()
        library.instances.append(instance)
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

    // MARK: - Save Configuration

    @Test("saveConfiguration persists via storage service")
    func saveConfigurationPersists() {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()

        library.saveConfiguration(for: instance)

        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("saveConfiguration presents error on failure")
    func saveConfigurationPresentsError() {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        library.saveConfiguration(for: instance)

        #expect(failures.showError == true)
        #expect(failures.errorMessage != nil)
    }

    // MARK: - Configuration Writes

    /// `instance`, live on a session no lifecycle call holds, registered in
    /// `library` over `storage`.
    private func registerRunning(
        _ instance: VMInstance, in library: VMLibrary, storage: MockVMStorageService
    ) -> UUID {
        library.register(instance, storage: storage)
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        return sessionID
    }

    @Test("A request whose save fails changes nothing, in memory or on the running VM")
    func discardedWriteLeavesTheOldValue() {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Before")
        _ = registerRunning(instance, in: library, storage: storage)
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        let saved = library.updateConfiguration(of: instance, ifNotSaved: .discard) {
            $0.name = "After"
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/A.iso", readOnly: true)]
        }

        #expect(saved.failedToSave)
        #expect(instance.name == "Before")
        #expect(instance.configuration.removableMedia == nil)
        #expect(storage.bundles[instance.bundleURL]?.name == "Before")
        // No pass was queued for a list that never became the configuration.
        #expect(!instance.hasRemovableMediaReconcileOwed)
        #expect(failures.showError)
    }

    @Test("A kept write stands in memory and reaches the running VM when its save fails")
    func keptWriteStandsWhenTheSaveFails() async {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Before")
        _ = registerRunning(instance, in: library, storage: storage)
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        let saved = library.updateConfiguration(of: instance, ifNotSaved: .keep) {
            $0.name = "After"
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/A.iso", readOnly: true)]
        }

        #expect(saved.failedToSave)
        #expect(instance.name == "After")
        #expect(storage.bundles[instance.bundleURL]?.name == "Before")
        #expect(instance.hasRemovableMediaReconcileOwed)
        #expect(failures.showError)
        await waitForObservedChange { !instance.hasRemovableMediaReconcileOwed }
        #expect(instance.liveRemovableMedia.map(\.path) == ["/tmp/A.iso"])
    }

    @Test("Settling on the live media list writes that field alone and tells the VM nothing")
    func settleRemovableMediaWritesOnlyTheList() {
        let (library, storage, _, _) = makeLibrary()
        let queued = RemovableMediaItem(path: "/tmp/queued.iso", readOnly: true)
        let live = RemovableMediaItem(path: "/tmp/live.iso", readOnly: true)
        let instance = VMInstanceFixture.make(name: "Mine") { $0.removableMedia = [queued] }
        let sessionID = registerRunning(instance, in: library, storage: storage)
        // A phase whose edits the write funnel refuses: the settle is not one.
        instance.enter(.saving(sessionID: sessionID))
        let before = instance.configuration

        library.settleRemovableMedia(of: instance, toLive: [live])

        var expected = before
        expected.removableMedia = [live]
        #expect(instance.configuration == expected)
        #expect(storage.bundles[instance.bundleURL] == expected)
        #expect(!instance.hasRemovableMediaReconcileOwed)
        #expect(!failures.showError)
    }

    @Test("Settling on the list the configuration already holds writes nothing")
    func settleRemovableMediaNoOpsWhenUnchanged() {
        let (library, storage, _, _) = makeLibrary()
        let live = RemovableMediaItem(path: "/tmp/live.iso", readOnly: true)
        let instance = VMInstanceFixture.make { $0.removableMedia = [live] }
        _ = registerRunning(instance, in: library, storage: storage)
        let saves = storage.saveConfigurationCallCount

        library.settleRemovableMedia(of: instance, toLive: [live])

        #expect(storage.saveConfigurationCallCount == saves)
    }

    @Test("A settled list stands in memory when its save fails")
    func settleRemovableMediaKeepsTheLiveListWhenTheSaveFails() {
        let (library, storage, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make {
            $0.removableMedia = [RemovableMediaItem(path: "/tmp/queued.iso", readOnly: true)]
        }
        _ = registerRunning(instance, in: library, storage: storage)
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        library.settleRemovableMedia(of: instance, toLive: nil)

        #expect(instance.configuration.removableMedia == nil)
        #expect(failures.showError)
    }

    @Test("A reverted configuration is taken on as written: nothing saved, nothing refused")
    func adoptRevertedConfigurationNeitherSavesNorRefuses() {
        let (library, storage, _, _) = makeLibrary()
        let other = VMInstanceFixture.make(name: "Other") {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:01"
        }
        let instance = VMInstanceFixture.make(name: "Mine") {
            $0.networkEnabled = true
            $0.macAddress = "aa:bb:cc:dd:ee:02"
        }
        library.register(other, storage: storage)
        library.register(instance, storage: storage)
        var written = instance.configuration
        written.macAddress = "aa:bb:cc:dd:ee:01"
        written.memorySizeInGB += 2
        let saves = storage.saveConfigurationCallCount

        library.adoptRevertedConfiguration(
            VMSnapshotRestorePlan(configuration: written, relativePaths: [], kind: .cold),
            on: instance)

        #expect(instance.configuration == written)
        #expect(storage.saveConfigurationCallCount == saves)
        #expect(!failures.showError)
    }

    @Test("A preparing row takes on the configuration its copy wrote when it publishes")
    func preparedRowAdoptsTheWrittenConfiguration() async {
        let (library, _, _, _) = makeLibrary()
        let phantom = VMInstanceFixture.make(name: "Copy")
        var written = phantom.configuration
        written.storageDisks = [
            StorageDisk(
                path: "AdditionalDisks/\(UUID().uuidString).asif", readOnly: false,
                label: "Remapped", isInternal: true, kind: .virtio)
        ]
        let published = written

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            library.prepareBundle(
                phantom, operation: .creating,
                copyWork: { _ in published },
                onSuccess: { done.resume() },
                onFailure: { error in
                    Issue.record(error)
                    done.resume()
                })
        }

        #expect(phantom.configuration == published)
        #expect(!phantom.isPreparing)
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
        library.instances.append(instance)
        library.guestAddresses.watch()
        // Bridged is nothing the table answers for, so nothing is read.
        #expect(library.guestAddresses.readTaskForTesting == nil)

        library.updateConfiguration(of: instance, ifNotSaved: .discard) { $0.networkMode = .shared }

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
        library.instances.append(instance)
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
        instance.enter(.stopped)
        library.instances.append(instance)

        // Storage has no bundles, so instance should be removed
        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
    }

    @Test("Evicting a VM whose bundle is gone drops its held guest-account password")
    func reconcileDropsTheHeldGuestAccountPassword() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Gone VM")
        instance.enter(.stopped)
        library.instances.append(instance)
        library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance)

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
        instance.enter(.running(sessionID: UUID()))
        library.instances.append(instance)

        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Running VM")
    }

    @Test("reconcileWithDisk preserves paused VMs even if bundle is missing")
    func reconcilePreservesPausedVMs() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Paused VM")
        instance.enter(.suspended)
        library.instances.append(instance)

        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Paused VM")
    }

    /// ``VMLifecyclePhase/suspended`` names a session on disk, so a slot removed
    /// out of band leaves the phase describing something that is not there —
    /// every predicate that asks the bundle has already moved on.
    @Test("reconcileWithDisk rests a suspension whose slot has left the bundle")
    func reconcileNormalizesAnEmptiedSuspension() throws {
        let (library, storage, _, _) = makeLibrary()
        let holding = VMInstanceFixture.make(name: "Still suspended")
        holding.enter(.suspended)
        defer { VMInstanceFixture.removeBundle(of: holding) }
        try VMInstanceFixture.writeSaveFile(for: holding)
        let emptied = VMInstanceFixture.make(name: "Slot gone")
        emptied.enter(.suspended)
        // Both bundles are on disk, so the pass has read them and what it found
        // inside them stands.
        storage.bundles[holding.bundleURL] = holding.configuration
        storage.bundles[emptied.bundleURL] = emptied.configuration
        library.instances.append(contentsOf: [holding, emptied])

        library.reconcileWithDisk()

        #expect(emptied.phase == .stopped)
        // The one whose slot is still there is left naming it.
        #expect(holding.phase == .suspended)
    }

    @Test("reconcileWithDisk leaves a suspension alone when it could not read the bundle")
    func reconcileLeavesAnUnreadBundlesSuspensionAlone() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(name: "Bundle out of sight")
        instance.enter(.suspended)
        library.instances.append(instance)

        library.reconcileWithDisk()

        // A bundle the scan never saw says nothing about the slot inside it,
        // and the eviction pass keeps such a VM.
        #expect(library.instances.count == 1)
        #expect(instance.phase == .suspended)
    }

    @Test("reconcileWithDisk updates selection when selected stopped VM is removed")
    func reconcileUpdatesSelection() {
        let (library, storage, _, _) = makeLibrary()
        let remaining = VMInstanceFixture.make(name: "Remaining")
        let removed = VMInstanceFixture.make(name: "Removed")
        removed.enter(.stopped)
        library.instances = [remaining, removed]
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
        library.instances.removeAll { $0.name == "Recoverable VM" }

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
        library.instances.append(instance)
        // Bundle is NOT in storage.bundles — simulating an on-disk deletion.

        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
        // Note: deleteVMBundle is NOT called — reconcile only evicts the in-memory entry.
        #expect(storage.deleteVMBundleCallCount == 0)
    }

    @Test("reconcileWithDisk cancels setupTask before evicting an orphaned VM")
    func reconcileCancelsSetupTaskBeforeEviction() async {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make(
            name: "Pending VM", guestOS: .macOS, phase: .initialBoot
        ) {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw")
        }

        // Spawn a long-running install task we can observe getting cancelled.
        let cancelStream = AsyncStream<Void>.makeStream()
        instance.setupTask = Task {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(60))
            } onCancel: {
                cancelStream.continuation.yield(())
                cancelStream.continuation.finish()
            }
        }
        library.instances.append(instance)
        // Bundle absent from storage → eligible for eviction.

        library.reconcileWithDisk()
        for await _ in cancelStream.stream { break }  // cancel propagated

        #expect(library.instances.isEmpty)
    }

    // MARK: - hasPreparing

    @Test("hasPreparing returns true when an instance is preparing")
    func hasPreparingTrue() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()
        markPreparing(instance)
        library.instances.append(instance)

        #expect(library.hasPreparing == true)
    }

    @Test("hasPreparing returns false when no instances are preparing")
    func hasPreparingFalse() {
        let (library, _, _, _) = makeLibrary()
        let instance = VMInstanceFixture.make()
        library.instances.append(instance)

        #expect(library.hasPreparing == false)
    }

    // MARK: - Reconcile With Disk (Preparing)

    @Test("reconcileWithDisk skips when instances are preparing")
    func reconcileSkipsWhenPreparing() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "New VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[bundleURL] = config

        let (library, _, _, _) = makeLibrary(storageService: storage)
        library.instances.removeAll()

        // Add a preparing instance
        let preparing = VMInstanceFixture.make(name: "Preparing")
        markPreparing(preparing)
        library.instances.append(preparing)

        library.reconcileWithDisk()

        // Should not have added the disk bundle because hasPreparing is true
        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Preparing")
    }

    @Test("reconcileWithDisk preserves preparing instances from removal")
    func reconcilePreservesPreparingInstances() {
        let (library, _, _, _) = makeLibrary()
        let preparing = VMInstanceFixture.make(name: "Preparing VM")
        markPreparing(preparing)
        preparing.enter(.stopped)
        library.instances.append(preparing)

        // Storage has no bundles — normally this instance would be removed
        // but hasPreparing guard should prevent reconcile from running
        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Preparing VM")
    }

    // MARK: - USB Accessory Pairings

    /// A library whose pairings live in memory, the store behind it, and the
    /// bundles it loads.
    private func makePairingLibrary() -> (VMLibrary, MockUSBAccessoryPairingStore) {
        let (library, store, _) = makePairingLibraryWithStorage()
        return (library, store)
    }

    private func makePairingLibraryWithStorage()
        -> (VMLibrary, MockUSBAccessoryPairingStore, MockVMStorageService)
    {
        let store = MockUSBAccessoryPairingStore()
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(
            storage: storage, snapshotStore: VMSnapshotStore(), fileSystem: fileSystem,
            preferences: preferences, usbPairingStore: store)
        library.onFailure = { [failures] title, message in
            failures.record(title: title, message: message)
        }
        return (library, store, storage)
    }

    private func pairing(key: String) -> USBAccessoryPairing {
        USBAccessoryPairing(
            key: key, form: .serialNumber, displayName: "Samsung Type-C",
            receptacleLabel: "Port-USB-C@2", pairedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test("A loaded VM mirrors the pairings its bundle holds")
    func loadMirrorsPairings() async {
        let (library, store, storage) = makePairingLibraryWithStorage()
        let config = VMConfiguration(name: "Paired VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = VMInstanceFixture.bundleURL(for: config.id)
        storage.bundles[bundleURL] = config
        store.setPairings(USBAccessoryPairingSet(pairings: [pairing(key: "k")]), for: bundleURL)

        await library.loadVMs()

        #expect(library.instances.first?.usbPairings.pairings.map(\.key) == ["k"])
    }

    @Test("A preparing row takes on its bundle's pairings when it publishes, and not before")
    func publicationMirrorsPairings() async {
        let (library, store) = makePairingLibrary()
        let phantom = VMInstanceFixture.make(name: "Fresh VM")
        store.setPairings(
            USBAccessoryPairingSet(pairings: [pairing(key: "k")]), for: phantom.bundleURL)
        let written = phantom.configuration

        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            library.prepareBundle(
                phantom, operation: .importing,
                copyWork: { _ in written },
                onSuccess: { done.resume() },
                onFailure: { error in
                    Issue.record(error)
                    done.resume()
                })
            // Registered, but its bundle does not exist yet.
            #expect(phantom.usbPairings.isEmpty)
        }

        #expect(phantom.usbPairings.pairings.map(\.key) == ["k"])
    }

    @Test("updateUSBPairings writes the bundle, and writes nothing when nothing changed")
    func updateUSBPairingsPersistsAndNoOps() {
        let (library, store) = makePairingLibrary()
        let instance = VMInstanceFixture.make(name: "Paired VM")
        library.wireHooks(for: instance)

        #expect(library.updateUSBPairings(of: instance) { $0.upsert(self.pairing(key: "k")) })
        #expect(store.pairings(for: instance.bundleURL)?.pairings.map(\.key) == ["k"])
        #expect(store.saveCount == 1)

        // Removing a key the VM never held leaves the set as it was.
        #expect(library.updateUSBPairings(of: instance) { $0.remove(key: "absent") })
        #expect(store.saveCount == 1)
    }

    @Test("A failed write leaves the new set in memory and reports the failure")
    func updateUSBPairingsReportsAFailedWrite() {
        let (library, store) = makePairingLibrary()
        let instance = VMInstanceFixture.make(name: "Paired VM")
        library.wireHooks(for: instance)
        store.saveError = VMStorageError.bundleNotFound(instance.bundleURL)

        let saved = library.updateUSBPairings(of: instance) { $0.upsert(self.pairing(key: "k")) }

        // The session it was made for still acts on it; only the remembering is
        // lost, so nothing is put in front of the user.
        #expect(!saved)
        #expect(instance.usbPairings.pairings.map(\.key) == ["k"])
        #expect(!failures.showError)
    }

    @Test("Pairing an accessory takes its key off every other virtual machine")
    func pairUSBAccessoryIsLibraryWide() {
        let (library, _) = makePairingLibrary()
        let first = VMInstanceFixture.make(name: "First")
        let second = VMInstanceFixture.make(name: "Second")
        for instance in [first, second] {
            library.wireHooks(for: instance)
            library.instances.append(instance)
        }
        library.updateUSBPairings(of: first) { $0.upsert(self.pairing(key: "k")) }

        library.pairUSBAccessory(pairing(key: "k"), with: second)

        #expect(first.usbPairings.isEmpty)
        #expect(second.usbPairings.pairings.map(\.key) == ["k"])
    }
}
