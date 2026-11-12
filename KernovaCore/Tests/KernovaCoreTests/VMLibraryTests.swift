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

    @Test("loadVMs auto-selects the first VM")
    func loadVMsAutoSelectsFirst() async {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(
            name: "First VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let config2 = VMConfiguration(
            name: "Second VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let url1 = scratch.url
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = scratch.url
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.setConfiguration(config1, at: url1)
        storage.setConfiguration(config2, at: url2)

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.instances.count == 2)
        #expect(library.selectedID == library.instances.first?.id)
    }

    @Test("loadVMs preserves valid selection on reload")
    func loadVMsPreservesSelection() async {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(
            name: "First VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let config2 = VMConfiguration(
            name: "Second VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let url1 = scratch.url
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = scratch.url
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.setConfiguration(config1, at: url1)
        storage.setConfiguration(config2, at: url2)

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()
        let secondID = library.instances.last?.id
        if let secondID { library.selectRevealing(secondID) }

        await library.loadVMs()

        #expect(library.selectedID == secondID)
    }

    // MARK: - Configuration Writes

    /// Puts `instance` live on a session no lifecycle call holds.
    private func placeRunning(_ instance: VMInstance) {
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        instance.beginSessionContextForTesting()
    }

    @Test("A request whose save fails changes nothing, in memory or on the running VM")
    func discardedWriteLeavesTheOldValue() throws {
        let (library, storage, _, _) = makeLibrary()
        let instance = library.registerFixture(name: "Before")
        placeRunning(instance)
        storage.setSaveConfigurationError(NSError(domain: "test", code: 1))

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
        #expect(failures.errorSubject?.vm === instance)
        #expect(failures.errorMessage?.hasPrefix("The change to \u{201C}Before\u{201D} wasn\u{2019}t saved: ") == true)
    }

    @Test("A snapshot's whole configuration passes the MAC-address refusal only as the revert's own write")
    func onlyARevertCommitsPastTheMACAddressRefusal() async throws {
        let (library, _, _, _) = makeLibrary()
        let address = "02:11:22:33:44:55"
        let snapshot = VMSnapshot(name: "Baseline", macAddress: address)
        let reverting = library.registerFixture(
            name: "Reverting", snapshots: VMSnapshotManifest(snapshots: [snapshot])
        ) { $0.macAddress = "02:66:77:88:99:aa" }
        library.registerFixture(name: "Holder") { $0.macAddress = address }
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

        try await reverting.activity.launchBringUp(
            .reverting(snapshotID: snapshot.id, resumesAfter: false)
        ) { context in
            try install(context.operation.permit)
            return .rest(.atRest(.stopped), ())
        }.value()
        #expect(reverting.configuration.macAddress == address)
    }

    @Test("Settling on the live media list writes that field alone and tells the VM nothing")
    func settleRemovableMediaWritesOnlyTheList() async throws {
        let (library, storage, _, _) = makeLibrary()
        let queued = RemovableMediaItem(path: "/tmp/queued.iso", readOnly: true)
        let live = RemovableMediaItem(path: "/tmp/live.iso", readOnly: true)
        let instance = library.registerFixture(name: "Mine") { $0.removableMedia = [queued] }
        placeRunning(instance)
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

    @Test("A settle whose write fails is reported and memory stays as the bundle holds it")
    func settleRemovableMediaWhoseWriteFailsKeepsTheBundleList() async throws {
        let (library, storage, _, _) = makeLibrary()
        let queued = [RemovableMediaItem(path: "/tmp/queued.iso", readOnly: true)]
        let instance = library.registerFixture { $0.removableMedia = queued }
        placeRunning(instance)
        storage.setSaveConfigurationError(NSError(domain: "test", code: 1))

        try await withOperation(on: instance, .reconcilingMedia) { context in
            library.settleRemovableMedia(context.permit, toLive: nil)
        }

        #expect(instance.configuration.removableMedia == queued)
        #expect(storage.bundles[instance.bundleURL]?.removableMedia == queued)
        #expect(failures.showError)
    }

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

    @Test(
        "An updateSettings whose host-state write fails reports that the configuration landed, and memory equals both files"
    )
    func updateSettingsWhoseHostStateWriteFailsReportsTheConfigurationLanded() throws {
        let (library, storage, _, _) = makeLibrary()
        let instance = library.registerFixture()
        let memory = instance.configuration.memorySizeInGB
        storage.setSaveHostStateError(NSError(domain: "test", code: 1))

        let outcome = try library.updateSettings(
            of: instance, as: [.machineKeys, .liveKeys],
            configuration: { $0.memorySizeInGB = memory.adding(gibibytes: 2) },
            hostState: { $0.startsAutomaticallyOnLaunch = true })

        guard case .notSaved(let failure) = outcome else {
            Issue.record("expected a partial write, got \(outcome)")
            return
        }
        #expect(failure.failed == .hostState)
        #expect(failure.landed == [.configuration])
        #expect(instance.configuration.memorySizeInGB == memory.adding(gibibytes: 2))
        #expect(!instance.hostState.startsAutomaticallyOnLaunch)
        #expect(instance.configuration == storage.bundles[instance.bundleURL])
        #expect(instance.hostState == storage.hostStates[instance.bundleURL])
        #expect(failures.errorSubject?.vm === instance)
        #expect(
            failures.errorMessage?.hasPrefix("The change to \u{201C}\(instance.name)\u{201D} was saved only in part")
                == true)
    }

    // MARK: - Guest Addresses

    @Test("A running VM switched live onto NAT is watched until its address is seen")
    func liveSwitchOntoNATWatchesTheGuest() async throws {
        let vmnet = ScriptedVmnetNetworks()
        vmnet.join(.common(.nat), on: "192.168.64.0")
        let table = ScriptedARPTable([
            .scripted("192.168.64.4", mac: "aa:bb:cc:dd:ee:01", expiry: ARPEntry.freshExpiry)
        ])
        let (library, _, _, _) = makeLibrary(vmnetNetworks: vmnet.service, arpTable: table)
        let instance = library.admitFixture(phase: .running(sessionID: UUID())) {
            $0.networkEnabled = true
            $0.networkMode = .bridged
            $0.macAddress = "aa:bb:cc:dd:ee:01"
        }
        library.guestAddresses.watch()
        // Bridged is nothing the table answers for, so nothing is read.
        #expect(library.guestAddresses.readTaskForTesting == nil)

        try library.updateConfiguration(of: instance, as: .networkAttachment) {
            $0.networkMode = .nat
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
        let instance = library.admitFixture()
        library.selectRevealing(instance.id)

        #expect(library.selectedInstance?.id == instance.id)
    }

    // MARK: - Reconcile With Disk

    @Test("Becoming active adopts a bundle that arrived without a write to the VMs directory")
    func activationAdoptsBundleTheDirectoryNeverReported() async throws {
        let activation = HostNotifications.isolated().appDidBecomeActive
        let (library, storage, _, _) = makeLibrary(appActivation: activation)
        await library.startLibrary()
        #expect(library.instances.isEmpty)

        // Listed only once its configuration lands, which a hand copy writes
        // inside the bundle, where the directory watch sees nothing.
        let config = VMConfiguration(
            name: "Hand Copied", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        storage.setConfiguration(config, at: try storage.bundleURL(for: config))
        activation.post()

        try await waitForChange { library.instances.map(\.name) == ["Hand Copied"] }
    }

    @Test("Evicting a VM whose bundle is gone drops its held guest-account password")
    func reconcileDropsTheHeldGuestAccountPassword() {
        let (library, _, _, _) = makeLibrary()
        let instance = library.admitFixture(name: "Gone VM")
        instance.activity.placeForTesting(.stopped)
        library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance.id)

        // Storage has no bundles, so the VM is evicted — and eviction is where a
        // held answer goes, whichever way the VM left the library.
        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
        #expect(library.heldGuestAccountPassword(for: instance) == nil)
    }

    // MARK: - Eviction

    @Test("A cold-suspended VM whose bundle is removed is evicted")
    func aColdSuspendedVMWhoseBundleIsRemovedIsEvicted() {
        let storage = MockVMStorageService()
        let library = makeWiredLibrary(storage: storage)
        let instance = RegisteredVMInstanceFixture.register(
            name: "Suspended", phase: .suspended, guestOS: .linux, library: library,
            preferences: makeTestPreferences())

        storage.files.removeBundle(at: instance.bundleURL)
        library.reconcileWithDisk()

        #expect(library.instances.isEmpty)
    }

    @Test("reconcileWithDisk updates selection when selected stopped VM is removed")
    func reconcileUpdatesSelection() {
        let (library, storage, _, _) = makeLibrary()
        let remaining = library.admitFixture(name: "Remaining")
        let removed = library.admitFixture(name: "Removed")
        removed.activity.placeForTesting(.stopped)
        library.selectRevealing(removed.id)

        // Only keep the remaining instance's bundle on disk
        let bundleURL = scratch.url
            .appendingPathComponent("\(remaining.id.uuidString).kernova", isDirectory: true)
        storage.setConfiguration(remaining.configuration, at: bundleURL)

        library.reconcileWithDisk()

        #expect(library.selectedID == remaining.id || library.selectedID != removed.id)
    }

    @Test("reconcileWithDisk keeps a bundle it can't read as a row and asks for the check")
    func reconcilePresentsErrorForFailedConfigs() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(
            name: "Good VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let goodURL = scratch.url
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.setConfiguration(config, at: goodURL)

        // Create library first (no bad bundles yet)
        let (library, _, _, _) = makeLibrary(storageService: storage)

        // Introduce the bad bundle after construction so it is new to reconcileWithDisk
        let badURL = scratch.url
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.setConfiguration(
            VMConfiguration(
                name: "Bad VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize), at: badURL)
        storage.setConfigurationUnreadable(true, at: badURL)

        failures.reset()

        library.reconcileWithDisk()

        #expect(failures.checkRequests == 1)
        #expect(library.entries.compactMap(\.unreadable).map(\.name) == ["broken-vm.kernova"])
        #expect(library.instances.contains { $0.name == "Good VM" })
    }

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

    @Test("reconcileWithDisk suppression is maintained after full reload")
    func reconcileSuppressionMaintainedAfterReload() async {
        let storage = MockVMStorageService()
        let badURL = scratch.url
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.setConfiguration(
            VMConfiguration(
                name: "Bad VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
                memorySizeInGB: VMGuestOS.linux.hostMemorySize), at: badURL)
        storage.setConfigurationUnreadable(true, at: badURL)

        // The initial load reports the error and seeds unreadableReports
        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()
        #expect(failures.checkRequests == 1)

        // First reconcile after the load is suppressed
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.checkRequests == 0)

        // Full reload resets suppression, then re-seeds from its own failures
        await library.loadVMs()
        #expect(failures.checkRequests == 1)

        // Reconciliation should still be suppressed since loadVMs re-seeded the set
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.checkRequests == 0)
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

    /// Pairings are made again by attaching the device once, so an unreadable
    /// file costs the VM nothing more than them.
    @Test("A bundle whose pairings cannot be read loads with none, asks for the check once, and keeps the file")
    func unreadablePairingsLoadEmpty() async throws {
        let storage = MockVMStorageService()
        let config = VMConfiguration(
            name: "Paired VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        let bundleURL = try storage.bundleURL(for: config)
        storage.setConfiguration(config, at: bundleURL)
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
        // The check lists the file; no alert of its own.
        #expect(failures.errorMessage == nil)
        #expect(failures.checkRequests == 1)
        library.reconcileWithDisk()
        library.refreshFromOtherCopies()
        #expect(failures.checkRequests == 1)
    }

    @Test("reconcileWithDisk reports a bundle again after it read successfully in between")
    func reconcileReReportsAfterBundleRecovery() {
        let storage = MockVMStorageService()
        let (library, _, _, _) = makeLibrary(storageService: storage)

        // Introduce the bad bundle after construction so it is new to reconcileWithDisk
        let bundleURL = scratch.url
            .appendingPathComponent("recoverable.kernova", isDirectory: true)
        let config = VMConfiguration(
            name: "Recoverable VM", guestOS: .linux, bootMode: .efi, cpuCount: VMGuestOS.linux.hostCPUCount,
            memorySizeInGB: VMGuestOS.linux.hostMemorySize)
        storage.setConfiguration(config, at: bundleURL)
        storage.setConfigurationUnreadable(true, at: bundleURL)

        // First reconciliation reports the error
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.checkRequests == 1)

        // "Fix" the bundle by removing it from the fail set
        storage.setConfigurationUnreadable(false, at: bundleURL)

        // Reconciliation succeeds — no error, and the bundle is cleared from reported set
        failures.reset()
        library.reconcileWithDisk()
        #expect(failures.checkRequests == 0)

        // Re-corrupt it
        storage.setConfigurationUnreadable(true, at: bundleURL)
        // Remove the instance that was added on successful load so reconciliation tries again
        for instance in library.instances where instance.name == "Recoverable VM" {
            library.evict(instance)
        }

        // Should report the error again since it was cleared from the reported set
        library.reconcileWithDisk()
        #expect(failures.checkRequests == 1)
    }

    // MARK: - Initial Boot status assignment

    @Test("loadVMs assigns .initialBoot when config has installContext")
    func loadVMsAssignsInitialBoot() async {
        let storage = MockVMStorageService()
        var config = VMConfiguration(
            name: "Pending VM", guestOS: .macOS, bootMode: .macOS, cpuCount: VMGuestOS.macOS.hostCPUCount,
            memorySizeInGB: VMGuestOS.macOS.hostMemorySize)
        config.installContext = MacOSInstallContext(
            source: .downloadLatest,
            downloadDestinationPath: "/tmp/restore.ipsw"
        )
        let url = scratch.url
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.setConfiguration(config, at: url)

        let (library, _, _, _) = makeLibrary(storageService: storage)
        await library.loadVMs()

        #expect(library.instances.count == 1)
        #expect(library.instances[0].status == .initialBoot)
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

    @Test("A pairing write that fails throws and leaves memory as the bundle holds it")
    func updateUSBPairingsThrowsOnAFailedWrite() {
        let (library, storage) = makePairingLibrary()
        let instance = library.registerFixture(name: "Paired VM")
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
