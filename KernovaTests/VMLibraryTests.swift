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
    /// Isolated, pre-cleaned preferences so selection/order persistence never
    /// touches the real `.standard` domain.
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.vmlibrary.core")
    /// Records trash/remove requests so nothing ever lands in the user's Trash.
    private let fileSystem = MockFileSystem()

    private func makeLibrary(
        storageService: MockVMStorageService = MockVMStorageService(),
        virtualizationService: MockVirtualizationService = MockVirtualizationService(),
        usbDeviceService: any USBDeviceProviding = MockUSBDeviceService(),
        linuxImageResolveService: MockLinuxImageResolveService = MockLinuxImageResolveService(),
        downloadService: MockDownloadService = MockDownloadService(),
        downloadsDirectory: URL? = FileManager.default.urls(
            for: .downloadsDirectory, in: .userDomainMask
        ).first,
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        isVMNetworkingEntitled: Bool = true
    ) -> (VMLibrary, MockVMStorageService, MockVirtualizationService, any USBDeviceProviding) {
        let library = VMLibrary(
            storageService: storageService,
            snapshotStore: VMSnapshotStore(),
            lifecycle: VMLifecycleCoordinator(
                virtualizationService: virtualizationService,
                installService: MockMacOSInstallService(),
                ipswService: MockIPSWService(),
                usbDeviceService: usbDeviceService,
                linuxImageResolveService: linuxImageResolveService,
                downloadService: downloadService,
                fileSystem: fileSystem,
                downloadsDirectory: downloadsDirectory
            ),
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: vmnetNetworks,
            isVMNetworkingEntitled: isVMNetworkingEntitled
        )
        library.onFailure = { [failures] title, message in
            failures.record(title: title, message: message)
        }
        return (library, storageService, virtualizationService, usbDeviceService)
    }

    /// Helper to mark an instance as preparing with a no-op task.
    private func markPreparing(_ instance: VMInstance, operation: VMInstance.PreparingOperation = .cloning) {
        instance.preparingState = VMInstance.PreparingState(operation: operation, task: Task {})
    }

    private func makeInstance(name: String = "Test VM", guestOS: VMGuestOS = .linux) -> VMInstance {
        let config = VMConfiguration(
            name: name,
            guestOS: guestOS,
            bootMode: guestOS == .macOS ? .macOS : .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
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
        let arrival = makeInstance(name: "Arrived Mid-Read")
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
        let instance = makeInstance()
        library.instances.append(instance)

        library.selectedID = instance.id

        #expect(preferences.lastSelectedVMID == instance.id)
    }

    @Test("selectedID clears UserDefaults when set to nil")
    func selectedIDClearsUserDefaults() {
        let (library, _, _, _) = makeLibrary()
        let instance = makeInstance()
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
        let instance = makeInstance()

        library.saveConfiguration(for: instance)

        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("saveConfiguration presents error on failure")
    func saveConfigurationPresentsError() {
        let (library, storage, _, _) = makeLibrary()
        let instance = makeInstance()
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        library.saveConfiguration(for: instance)

        #expect(failures.showError == true)
        #expect(failures.errorMessage != nil)
    }

    // MARK: - Selected Instance

    @Test("selectedInstance returns the instance matching selectedID")
    func selectedInstance() {
        let (library, _, _, _) = makeLibrary()
        let instance = makeInstance()
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

    // MARK: - Eviction

    @Test("evict announces the id, so app-level state keyed on it is released")
    func evictAnnouncesTheID() {
        let (library, _, _, _) = makeLibrary()
        let instance = makeInstance()
        library.instances.append(instance)
        var evicted: [UUID] = []
        library.onEvicted = { evicted.append($0) }

        library.evict(instance)

        #expect(evicted == [instance.id])
    }

    @Test("A reconcile-driven eviction announces the id too")
    func reconcileEvictionAnnouncesTheID() {
        let (library, _, _, _) = makeLibrary()
        let instance = makeInstance()
        instance.enter(.stopped)
        library.instances.append(instance)
        var evicted: [UUID] = []
        library.onEvicted = { evicted.append($0) }

        // Storage holds no bundles, so the resting VM is no longer on disk.
        library.reconcileWithDisk()

        #expect(evicted == [instance.id])
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
        let instance = makeInstance(name: "Gone VM")
        instance.enter(.stopped)
        library.instances.append(instance)

        // Storage has no bundles, so instance should be removed
        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
    }

    @Test("reconcileWithDisk preserves running VMs even if bundle is missing")
    func reconcilePreservesRunningVMs() {
        let (library, _, _, _) = makeLibrary()
        let instance = makeInstance(name: "Running VM")
        instance.enter(.running(sessionID: UUID()))
        library.instances.append(instance)

        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Running VM")
    }

    @Test("reconcileWithDisk preserves paused VMs even if bundle is missing")
    func reconcilePreservesPausedVMs() {
        let (library, _, _, _) = makeLibrary()
        let instance = makeInstance(name: "Paused VM")
        instance.enter(.suspended)
        library.instances.append(instance)

        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Paused VM")
    }

    @Test("reconcileWithDisk updates selection when selected stopped VM is removed")
    func reconcileUpdatesSelection() {
        let (library, storage, _, _) = makeLibrary()
        let remaining = makeInstance(name: "Remaining")
        let removed = makeInstance(name: "Removed")
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
        var config = VMConfiguration(name: "Pending VM", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, phase: .initialBoot)
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
        var config = VMConfiguration(name: "Pending VM", guestOS: .macOS, bootMode: .macOS)
        config.installContext = MacOSInstallContext(
            source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(configuration: config, bundleURL: bundleURL, phase: .initialBoot)

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
        let instance = makeInstance()
        markPreparing(instance)
        library.instances.append(instance)

        #expect(library.hasPreparing == true)
    }

    @Test("hasPreparing returns false when no instances are preparing")
    func hasPreparingFalse() {
        let (library, _, _, _) = makeLibrary()
        let instance = makeInstance()
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
        let preparing = makeInstance(name: "Preparing")
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
        let preparing = makeInstance(name: "Preparing VM")
        markPreparing(preparing)
        preparing.enter(.stopped)
        library.instances.append(preparing)

        // Storage has no bundles — normally this instance would be removed
        // but hasPreparing guard should prevent reconcile from running
        library.reconcileWithDisk()

        #expect(library.instances.count == 1)
        #expect(library.instances.first?.name == "Preparing VM")
    }
}
