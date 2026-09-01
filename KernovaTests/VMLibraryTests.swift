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

    // MARK: - Address Reservation Sync

    @Test("A configuration change syncs the VM's DHCP reservation slot for its mode's network")
    func updateConfigurationSyncsAddressReservation() {
        let vmnet = MockVmnetNetworkProvider()
        let (library, _, _, _) = makeLibrary(vmnetNetworks: vmnet)
        let instance = makeInstance()

        library.updateConfiguration(of: instance) {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = "AA:BB:CC:DD:EE:0F"
        }

        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
        #expect(vmnet.reservedMACs.map(\.kind) == [.shared])
    }

    @Test("A bridged or MAC-less configuration takes no reservation slot")
    func bridgedConfigurationTakesNoReservationSlot() {
        let vmnet = MockVmnetNetworkProvider()
        let (library, _, _, _) = makeLibrary(vmnetNetworks: vmnet)
        let instance = makeInstance()

        library.updateConfiguration(of: instance) {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.macAddress = "aa:bb:cc:dd:ee:0f"
        }
        library.updateConfiguration(of: instance) {
            $0.networkMode = .shared
            $0.macAddress = nil
        }

        #expect(vmnet.reservedMACs.isEmpty)
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

    // MARK: - Sleep/Wake

    @Test("pauseAllForSleep pauses only running VMs")
    func pauseAllForSleepPausesRunning() async {
        let (library, _, virtService, _) = makeLibrary()
        let running1 = makeInstance(name: "Running 1")
        running1.enter(.running(sessionID: UUID()))
        let running2 = makeInstance(name: "Running 2")
        running2.enter(.running(sessionID: UUID()))
        let stopped = makeInstance(name: "Stopped")
        stopped.enter(.stopped)
        let paused = makeInstance(name: "User Paused")
        paused.enter(.suspended)
        library.instances = [running1, running2, stopped, paused]

        await library.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 2)
        #expect(library.sleepPausedInstanceIDs == Set([running1.id, running2.id]))
        #expect(running1.status == .paused)
        #expect(running2.status == .paused)
        #expect(stopped.status == .stopped)
        #expect(paused.status == .paused)
    }

    @Test("resumeAllAfterWake resumes only sleep-paused VMs")
    func resumeAllAfterWakeResumesOnlySleepPaused() async {
        let (library, _, virtService, _) = makeLibrary()
        let sleepPaused = makeInstance(name: "Sleep Paused")
        sleepPaused.enter(.suspended)
        let userPaused = makeInstance(name: "User Paused")
        userPaused.enter(.suspended)
        library.instances = [sleepPaused, userPaused]
        library.sleepPausedInstanceIDs = Set([sleepPaused.id])

        await library.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 1)
        #expect(sleepPaused.status == .running)
        #expect(userPaused.status == .paused)
        #expect(library.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("pauseAllForSleep handles pause failure gracefully")
    func pauseAllForSleepHandlesError() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (library, _, _, _) = makeLibrary(virtualizationService: virtService)
        let running = makeInstance(name: "Running")
        running.enter(.running(sessionID: UUID()))
        library.instances = [running]

        await library.pauseAllForSleep()

        // Error is surfaced to the user
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("Running") == true)
        // Failed pause should not track the instance
        #expect(library.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake clears tracking set even on failure")
    func resumeAllAfterWakeClearsOnError() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (library, _, _, _) = makeLibrary(virtualizationService: virtService)
        let instance = makeInstance(name: "Sleep Paused")
        instance.enter(.suspended)
        library.instances = [instance]
        library.sleepPausedInstanceIDs = Set([instance.id])

        await library.resumeAllAfterWake()

        #expect(library.sleepPausedInstanceIDs.isEmpty)
        // Error is surfaced to the user
        #expect(failures.showError == true)
        #expect(failures.errorMessage?.contains("Sleep Paused") == true)
    }

    @Test("pauseAllForSleep is no-op when no running VMs")
    func pauseAllForSleepNoOp() async {
        let (library, _, virtService, _) = makeLibrary()
        let stopped = makeInstance(name: "Stopped")
        stopped.enter(.stopped)
        library.instances = [stopped]

        await library.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(library.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake is no-op when no sleep-paused VMs")
    func resumeAllAfterWakeNoOp() async {
        let (library, _, virtService, _) = makeLibrary()
        let paused = makeInstance(name: "User Paused")
        paused.enter(.suspended)
        library.instances = [paused]
        // sleepPausedInstanceIDs is empty

        await library.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
    }

    @Test("pauseAllForSleep skips non-running states")
    func pauseAllForSleepSkipsNonRunning() async {
        let (library, _, virtService, _) = makeLibrary()
        let starting = makeInstance(name: "Starting")
        starting.enter(.starting(sessionID: nil))
        let saving = makeInstance(name: "Saving")
        saving.enter(.saving(sessionID: UUID()))
        let error = makeInstance(name: "Error")
        error.enter(.failed(message: "Test failure"))
        library.instances = [starting, saving, error]

        await library.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(library.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake skips VMs no longer paused")
    func resumeAllAfterWakeSkipsNonPaused() async {
        let (library, _, virtService, _) = makeLibrary()
        let instance = makeInstance(name: "Was Paused")
        instance.enter(.stopped)  // Status changed between sleep and wake
        library.instances = [instance]
        library.sleepPausedInstanceIDs = Set([instance.id])

        await library.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
        #expect(library.sleepPausedInstanceIDs.isEmpty)
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

    // MARK: - Live Removable Media Hot-Config

    /// Helper: build a config with a single removable media item.
    private func configWithRemovable(
        _ base: VMConfiguration,
        path: String,
        readOnly: Bool = true,
        id: UUID = UUID()
    ) -> VMConfiguration {
        var c = base
        c.removableMedia = [RemovableMediaItem(id: id, path: path, readOnly: readOnly)]
        return c
    }

    @Test("applyLivePolicy attaches a new removable item when added to the list")
    func liveRemovableAddAttaches() async throws {
        let mock = MockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        library.instances.append(instance)

        let configuredUUID = UUID()
        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso", readOnly: true, id: configuredUUID)

        library.applyLivePolicy(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(mock.lastAttachedPath == "/tmp/install.iso")
        #expect(mock.lastAttachedReadOnly == true)
        #expect(mock.lastAttachedDesiredUUID == configuredUUID)
        #expect(instance.liveRemovableMedia.count == 1)
        #expect(instance.liveRemovableMedia.first?.id == configuredUUID)
        #expect(instance.liveRemovableMedia.first?.path == "/tmp/install.iso")
    }

    @Test("applyLivePolicy detaches and clears tracking when the only item is removed")
    func liveRemovableRemoveDetaches() async throws {
        let mock = MockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let id = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        instance.configuration = old
        library.instances.append(instance)

        var new = old
        new.removableMedia = nil

        library.applyLivePolicy(for: instance, old: old, new: new)

        while !instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("applyLivePolicy swaps the only item: detach old, attach new")
    func liveRemovableSwapDetachesThenAttaches() async throws {
        let mock = MockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        library.instances.append(instance)

        let newID = UUID()
        var new = old
        new.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]

        library.applyLivePolicy(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.path != "/tmp/new.iso" { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/new.iso")
        #expect(instance.liveRemovableMedia.count == 1)
        #expect(instance.liveRemovableMedia.first?.id == newID)
    }

    @Test("applyLivePolicy detaches and reattaches on readOnly flip (same id)")
    func liveRemovableReadOnlyFlipReattaches() async throws {
        let mock = MockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let id = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        instance.configuration = old
        library.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]

        library.applyLivePolicy(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.readOnly != false { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedReadOnly == false)
    }

    @Test("applyLivePolicy is a no-op when storageDisks change but removableMedia is unchanged")
    func liveRemovableNoopWhenOnlyStorageDisksChange() async throws {
        let mock = MockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        library.instances.append(instance)

        let old = instance.configuration
        var new = old
        new.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        ]

        library.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
    }

    @Test("applyLivePolicy is a no-op when VM is stopped, even with media change")
    func liveRemovableNoopWhenStopped() async throws {
        let mock = MockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.stopped)
        library.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        library.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("applyLivePolicy is a no-op for a cold-paused VM, which has no session to attach to")
    func liveRemovableNoopWhenColdPaused() async throws {
        let mock = MockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.suspended)
        library.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        library.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(!failures.showError)
    }

    @Test("Live attach failure surfaces error")
    func liveRemovableAttachFailureSurfacesError() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.diskImageNotFound("/tmp/missing.iso")
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        library.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/missing.iso")

        library.applyLivePolicy(for: instance, old: old, new: new)

        while !failures.showError { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(failures.errorMessage != nil)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("deviceNotFound on detach is treated as confirmed-gone — reconcile continues with attach")
    func liveRemovableDetachDeviceNotFoundContinues() async throws {
        // deviceNotFound means the guest (or framework) already removed the
        // device — for example, the user ejected it from inside the guest.
        // The reconcile must clear tracking and proceed with the next
        // operation in the diff.
        let mock = MockUSBDeviceService()
        mock.detachError = USBDeviceError.deviceNotFound
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        library.instances.append(instance)

        let newID = UUID()
        var new = old
        new.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]

        library.applyLivePolicy(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.path != "/tmp/new.iso" { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(instance.liveRemovableMedia.first?.path == "/tmp/new.iso")
    }

    @Test("Transient detach error fails fast — reconcile aborts before attach")
    func liveRemovableTransientDetachErrorFailsFast() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.detachError = TransientError()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        library.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        library.applyLivePolicy(for: instance, old: old, new: new)

        while !failures.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        // No attach attempted — preventing the device-leak.
        #expect(mock.attachCallCount == 0)
    }

    @Test("Detach noVirtualMachine error bails the reconcile silently")
    func liveRemovableDetachNoVMBails() async throws {
        let mock = MockUSBDeviceService()
        mock.detachError = USBDeviceError.noVirtualMachine
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        let sessionID = UUID()
        instance.enter(.running(sessionID: sessionID))
        instance.beginSessionContext()
        let oldID = UUID()
        instance.recordAttachedMedia(
            USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true), for: sessionID)
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        library.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        library.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(!failures.showError)
    }

    @Test("Attach noVirtualMachine error bails the reconcile silently")
    func liveRemovableAttachNoVMBails() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.noVirtualMachine
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        library.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        library.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(!failures.showError)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Reconcile loop bails out when VM stops mid-pass — no spurious error")
    func liveRemovableReconcileBailsOutOnVMStop() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        library.instances.append(instance)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")

        library.applyLivePolicy(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        // Stop the VM before the suspended attach resolves.
        library.applyLivePolicy(for: instance, old: configA, new: configB)
        instance.enter(.stopped)

        mock.resumeSuspended()
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/A.iso")
        #expect(!failures.showError)
    }

    @Test("A pass overtaken by a force stop and restart records nothing on the successor")
    func liveRemovableOvertakenPassLeavesTheSuccessorAlone() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        library.instances.append(instance)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        instance.configuration = configA
        library.applyLivePolicy(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()

        // Force Stop, then Start: the suspended attach now answers for a
        // session two transitions old.
        instance.tearDownSession(restingAt: .stopped)
        instance.beginSessionContext()
        instance.enter(.running(sessionID: UUID()))

        mock.resumeSuspended()
        try await mock.operationCompleted.wait { mock.completedOperationCount == 1 }
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
        #expect(!failures.showError)
        #expect(instance.configuration == configA)
    }

    @Test("An overtaken pass's failure neither alerts nor rolls the config back")
    func liveRemovableOvertakenPassFailureIsDropped() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        library.instances.append(instance)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        instance.configuration = configA
        library.applyLivePolicy(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()

        // The force stop is what makes the attach fail, so the alert would name
        // an error the user caused and the rollback would describe the
        // successor's — here empty — live media.
        mock.attachError = USBDeviceError.diskImageNotFound("/tmp/A.iso")
        instance.tearDownSession(restingAt: .stopped)
        instance.beginSessionContext()
        instance.enter(.running(sessionID: UUID()))

        mock.resumeSuspended()
        try await mock.operationCompleted.wait { mock.completedOperationCount == 1 }
        for _ in 0..<5 { await Task.yield() }

        #expect(!failures.showError)
        #expect(failures.errorMessage == nil)
        #expect(instance.configuration == configA)
    }

    @Test("Rapid-fire media swaps coalesce — one Task drains to the latest target")
    func liveRemovableRapidFireCoalescesToLatest() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let (library, _, _, _) = makeLibrary(usbDeviceService: mock)
        let instance = makeInstance()
        instance.enter(.running(sessionID: UUID()))
        instance.beginSessionContext()
        library.instances.append(instance)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")
        let configC = configWithRemovable(baseConfig, path: "/tmp/C.iso")

        // Three rapid edits before the first attach can complete.
        library.applyLivePolicy(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        library.applyLivePolicy(for: instance, old: configA, new: configB)
        library.applyLivePolicy(for: instance, old: configB, new: configC)

        // Release the suspended attach (A); the loop should then detach A,
        // attach C (B was overwritten before any attach started for it).
        mock.resumeSuspended()
        await mock.waitUntilSuspended()
        mock.resumeSuspended()

        while instance.liveRemovableMedia.first?.path != "/tmp/C.iso" { await Task.yield() }

        // Final state: A then C attached; A detached. B was skipped entirely.
        #expect(mock.attachCallCount == 2)
        #expect(mock.detachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/C.iso")
        #expect(instance.liveRemovableMedia.first?.path == "/tmp/C.iso")
        #expect(instance.liveRemovableMedia.first?.id == configC.removableMedia?.first?.id)
    }
}
