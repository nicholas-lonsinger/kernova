import CryptoKit
import Foundation
import KernovaAgentHost
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMLibraryViewModel Tests", .serialized, .caseScoped)
@MainActor
struct VMLibraryViewModelTests {
    private let scratch = TestScratchDirectory(prefix: "VMLibraryViewModelTests")
    private let presenter = MockVMLibraryPresenting()
    /// Fresh per test (the struct is re-instantiated), so each test starts from
    /// an empty store.
    private let preferences = makeTestPreferences()
    /// Fresh per test (the struct is re-instantiated).
    ///
    /// Records trash/remove requests so delete flows are asserted on the
    /// recorded URLs instead of real fixture files — nothing ever lands in
    /// the user's Trash.
    private let fileSystem = MockFileSystem()
    private func makeViewModel(
        storageService: MockVMStorageService = MockVMStorageService(),
        diskImageService: MockDiskImageService = MockDiskImageService(),
        virtualizationService: MockVirtualizationService = MockVirtualizationService(),
        removableMediaDeviceService: any RemovableMediaAttaching = MockRemovableMediaDeviceService(),
        linuxImageResolveService: MockLinuxImageResolveService = MockLinuxImageResolveService(),
        downloadService: MockDownloadService = MockDownloadService(),
        downloadsDirectory: URL = makeTestDownloadsDirectory()
    ) -> (
        VMLibraryViewModel, MockVMStorageService, MockDiskImageService, MockVirtualizationService,
        any RemovableMediaAttaching
    ) {
        let vm = VMLibraryViewModel(
            storageService: storageService,
            diskImageService: diskImageService,
            machineFiles: VMBundleMachineFiles(fileSystem: fileSystem, platform: FakePlatformFiles()),
            virtualizationHost: FakeVirtualizationHost(),
            virtualizationService: virtualizationService,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            localImageInspector: MockLocalRestoreImageInspector(),
            removableMediaDeviceService: removableMediaDeviceService,
            bridgedInterfaces: MockBridgedInterfaceProvider(),
            linuxImageResolveService: linuxImageResolveService,
            downloadService: downloadService,
            fileSystem: fileSystem,
            downloadsDirectory: downloadsDirectory,
            preferences: preferences,
            vmnetNetworks: .scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
        )
        vm.presenter = presenter
        vm.libraryWindowPresenter = presenter
        return (vm, storageService, diskImageService, virtualizationService, removableMediaDeviceService)
    }

    // MARK: - Delete

    @Test("externalAttachments never offers a shared directory")
    func externalAttachmentsExcludeSharedDirectories() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let target = viewModel.library.admitFixture(name: "Sharer") {
            $0.sharedDirectories = [SharedDirectory(path: "/Users/me/Projects")]
        }

        #expect(await viewModel.externalAttachments(for: target).isEmpty)
    }

    // MARK: - Delete Externals

    @Test("deleteVM trashes only the selected external and keeps the rest")
    func deleteVMTrashesOnlySelectedExternal() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let trashedDisk = scratch.url
            .appendingPathComponent("\(UUID().uuidString)-trash.img")
        let keptDisk = scratch.url
            .appendingPathComponent("\(UUID().uuidString)-keep.img")

        let trashedID = UUID()
        let keptID = UUID()
        let instance = viewModel.library.admitFixture {
            $0.storageDisks = [
                StorageDisk(
                    id: trashedID, path: trashedDisk.path(percentEncoded: false),
                    readOnly: false, label: "Trashed", isInternal: false, kind: .virtio
                ),
                StorageDisk(
                    id: keptID, path: keptDisk.path(percentEncoded: false),
                    readOnly: false, label: "Kept", isInternal: false, kind: .virtio
                ),
            ]
        }
        storage.setConfiguration(instance.configuration, at: instance.bundleURL)

        await viewModel.delete(instance, deletingExternalIDs: [trashedID])

        // Only the selected disk is trashed; the unselected one stays put.
        #expect(fileSystem.trashedURLs == [trashedDisk])
        #expect(!presenter.showError)
    }

    @Test("deleteVM never trashes a file a sibling names in a different path form")
    func deleteVMNeverTrashesSharedExternalAcrossPathForms() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let sharedDisk = scratch.url
            .appendingPathComponent(
                "\(UUID().uuidString)-Cafe\u{0301}.img".precomposedStringWithCanonicalMapping)

        let sharedID = UUID()
        let sharedPath = sharedDisk.path(percentEncoded: false)
        let target = viewModel.library.admitFixture(name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    id: sharedID, path: sharedPath,
                    readOnly: false, label: "Shared", isInternal: false, kind: .virtio
                )
            ]
        }
        // The sibling stores the decomposed form APFS reports for the same
        // name — a divergence a boot's path healing writes on its own.
        viewModel.library.admitFixture(name: "Other") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath.decomposedStringWithCanonicalMapping, readOnly: false,
                    label: "Shared", isInternal: false, kind: .virtio
                )
            ]
        }
        storage.setConfiguration(target.configuration, at: target.bundleURL)

        await viewModel.delete(target, deletingExternalIDs: [sharedID])

        // One file, two spellings: the hard-block still holds.
        #expect(fileSystem.trashedURLs.isEmpty)
        #expect(!presenter.showError)
    }

    @Test(
        "deleteVM discards the IPSW resume-data sidecar",
        arguments: [
            MacOSInstallContext.Source.downloadLatest, .catalogVersion, .customURL,
        ]
    )
    func deleteVMDiscardsResumeData(source: MacOSInstallContext.Source) async {
        // Every source that downloads its image leaves a partial bundle at
        // `downloadDestinationPath`, so deleting the VM has to discard it.
        let downloadService = MockDownloadService()
        let storage = MockVMStorageService()
        let (viewModel, _, _, _, _) = makeViewModel(
            storageService: storage, downloadService: downloadService)

        let destination = scratch.url
            .appendingPathComponent("\(UUID().uuidString)-RestoreImage.ipsw")
        let instance = viewModel.library.registerFixture {
            $0.installContext = MacOSInstallContext(
                source: source,
                downloadDestinationPath: destination.path(percentEncoded: false)
            )
        }
        storage.setConfiguration(instance.configuration, at: instance.bundleURL)

        await viewModel.delete(instance)

        #expect(downloadService.discardResumeDataCallCount == 1)
        #expect(
            downloadService.discardedResumeDataURLs.last?.path(percentEncoded: false)
                == destination.path(percentEncoded: false)
        )
        // A move-to-Trash delete discards the partial download to the Trash too.
        #expect(downloadService.lastDiscardResumeDataPermanently == false)
        #expect(viewModel.instances.isEmpty)
    }

    @Test(
        "Deleting one of two VMs whose setups share a destination keeps the bundle",
        arguments: [false, true]
    )
    func deleteVMKeepsSharedResumeData(permanently: Bool) async {
        // Two VMs installing one build share one destination and one bundle:
        // the other VM is streaming into it, or will resume from it.
        let downloadService = MockDownloadService()
        let storage = MockVMStorageService()
        let (viewModel, _, _, _, _) = makeViewModel(
            storageService: storage, downloadService: downloadService)

        let directory = scratch.url.appendingPathComponent(UUID().uuidString)
        let destination = directory.appendingPathComponent("RestoreImage.ipsw")
        let deleted = viewModel.library.registerFixture(name: "First") {
            $0.installContext = MacOSInstallContext(
                source: .downloadLatest,
                downloadDestinationPath: destination.path(percentEncoded: false))
        }
        // Spelled differently, as a hand-edited config might: the download's
        // own destination key is what decides they are one file.
        viewModel.library.registerFixture(name: "Second") {
            $0.installContext = MacOSInstallContext(
                source: .catalogVersion,
                downloadDestinationPath: directory.path(percentEncoded: false)
                    + "/./RestoreImage.ipsw")
        }

        await viewModel.delete(deleted, permanently: permanently)

        #expect(downloadService.discardResumeDataCallCount == 0)
        #expect(viewModel.instances.map(\.name) == ["Second"])
    }

    @Test("A removable-media removal whose file stayed alerts once, naming the file")
    func removeRemovableMediaAlertsOnceForAFileThatStayed() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        fileSystem.setTrashError(CocoaError(.fileWriteNoPermission))
        let lockedPath = scratch.url
            .appendingPathComponent("kernova-locked.img")
            .path(percentEncoded: false)
        let item = RemovableMediaItem(path: lockedPath, readOnly: true)
        let instance = viewModel.library.admitFixture { $0.removableMedia = [item] }

        await viewModel.removeRemovableMedia(item.id, from: instance, trashFile: true)

        #expect(instance.configuration.removableMedia == nil)
        #expect(presenter.errors.count == 1)
        #expect(presenter.errorMessage?.contains("\u{201C}\(lockedPath)\u{201D}") == true)
    }

    // MARK: - Duplicate Machine ID Boot Guard

    /// Wires `instances` to `viewModel`'s library, as a load would — the
    /// identity refusal every bring-up passes reads its peers through that
    /// wiring, and an unwired VM has none.
    private func wire(_ instances: [VMInstance], into viewModel: VMLibraryViewModel) {
        for instance in instances { viewModel.library.wireHooks(for: instance) }
    }

    /// Two VMs carrying the given machine identifiers in whichever identity
    /// field `guestOS` uses, and MAC addresses of their own unless
    /// `exactCopies`, both appended to `viewModel`.
    ///
    /// `other` is the one the tests park in a live status; `starting` is the one
    /// they try to boot.
    private func appendMachineIDPair(
        to viewModel: VMLibraryViewModel,
        guestOS: VMGuestOS = .macOS,
        startingID: Data = Data([1, 2, 3]),
        otherID: Data = Data([1, 2, 3]),
        exactCopies: Bool = false
    ) -> (starting: VMInstance, other: VMInstance) {
        func makeTwin(_ name: String, identifier: Data) -> VMInstance {
            viewModel.library.admitFixture(name: name, guestOS: guestOS) {
                $0.macAddress = exactCopies || name == "Starting" ? "02:4b:4e:56:02:01" : "02:4b:4e:56:02:02"
                if exactCopies { $0.networkEnabled = true }
                if guestOS == .macOS {
                    $0.machineIdentifierData = identifier
                } else {
                    $0.genericMachineIdentifierData = identifier
                }
            }
        }
        let starting = makeTwin("Starting", identifier: startingID)
        let other = makeTwin("Twin", identifier: otherID)
        wire([starting, other], into: viewModel)
        return (starting, other)
    }

    @Test("start is refused while another VM with the same machine ID is running")
    func startBlockedByRunningMachineIDTwin() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.activity.placeForTesting(.running(sessionID: UUID()))

        await viewModel.start(starting)

        // Refused at admission, before the service was reached.
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(presenter.errorMessage?.hasSuffix(" You can change this in Settings \u{25B8} Advanced.") == true)
        #expect(presenter.errorSettingsDestination == .pane(.advanced))
        #expect(starting.status == .stopped)
    }

    @Test("start beside a machine ID twin it could not ask about shows the refusal as an error")
    func startUnaskedShowsTheRefusal() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.activity.placeForTesting(.running(sessionID: UUID()))
        preferences.allowsDuplicateMachineIDOverride = true
        presenter.confirmationAnswer = .unasked

        await viewModel.start(starting)

        #expect(presenter.confirmationRequests.count == 1)
        #expect(virtService.startCallCount == 0)
        #expect(presenter.errorTitle == "Duplicate Machine ID")
        #expect(presenter.errorSubject?.vm === starting)
        // The setting is on, so the refusal offers no way to it.
        #expect(presenter.errorSettingsDestination == nil)
        #expect(
            presenter.errorMessage?.hasPrefix(
                "\u{201C}Starting\u{201D} has the same machine ID as \u{201C}Twin\u{201D}, which is active.")
                == true)
    }

    @Test("Confirming without Don't ask again, or declining, saves nothing")
    func answersWithoutTheCheckboxSaveNothing() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let (starting, other) = appendMachineIDPair(to: viewModel)
        other.activity.placeForTesting(.running(sessionID: UUID()))
        preferences.allowsDuplicateMachineIDOverride = true

        presenter.confirmationAnswer = .answered(.decline)
        await viewModel.start(starting)
        #expect(viewModel.duplicateMachineIDQuestionDismissed == false)

        presenter.confirmationAnswer = .answered(.confirm(dontAskAgain: false))
        await viewModel.start(starting)
        #expect(viewModel.duplicateMachineIDQuestionDismissed == false)
        #expect(preferences.duplicateMachineIDQuestionDismissed == false)
        #expect(presenter.confirmationRequests.count == 2)
    }

    // MARK: - Match-Window Boot Resolution

    /// A VM whose display is sized to its window at every cold start, at the
    /// screen's scale — both defaults.
    private func makeMatchWindowInstance(
        in library: VMLibrary,
        guestOS: VMGuestOS = .macOS, files: InMemoryVMBundleFiles = InMemoryVMBundleFiles(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        library.admitFixture(guestOS: guestOS, files: files, mutate: mutate)
    }

    private static let retinaSurface = DisplayBootSurface(
        pointSize: CGSize(width: 1400, height: 880), backingScaleFactor: 2)

    @Test("A saved-state VM keeps its resolution so the restore stays valid")
    func matchWindowSkippedWhenSaveFileExists() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        var measured: [VMOperationKind?] = []
        viewModel.displayBootSurface = {
            measured.append($0.phase.operation?.kind)
            return Self.retinaSurface
        }
        let instance = makeMatchWindowInstance(in: viewModel.library)
        try FileManager.default.createDirectory(
            at: instance.bundleURL, withIntermediateDirectories: true)
        try Data().write(to: instance.bundleLayout.saveFileURL)

        await viewModel.start(instance)

        // The surface is never even measured — the save file settles it.
        #expect(measured.isEmpty)
        #expect(virtService.configurationAtStart?.displayWidth == 1920)
        #expect(virtService.configurationAtStart?.displayHeight == 1200)
    }

    // MARK: - Error Handling

    /// A fixture VM whose storage list `storageDisks` builds against the bundle
    /// the VM will own.
    private func makeInstanceWithDisks(
        in library: VMLibrary,
        phase: VMLifecyclePhase = .stopped,
        storageDisks: (VMBundleLayout) -> [StorageDisk]
    ) -> VMInstance {
        library.admitFixture(phase: phase) { config in
            config.storageDisks = storageDisks(
                VMBundleLayout(bundleURL: VMInstanceFixture.bundleURL(for: config.id)))
        }
    }

    /// The ways one entry can be unusable that are not a refused attach. A file
    /// deleted or a volume ejected is the likeliest of them, and the VM it
    /// leaves behind is the same one, with the same entry to remove.
    enum UnusableAttachment: CaseIterable, Sendable {
        case notFound
        case pathIsDirectory
        case notWritable

        func removableMedia(id: UUID, path: String, label: String) -> ConfigurationBuilderError {
            switch self {
            case .notFound: .removableMediaNotFound(id: id, path: path, label: label)
            case .pathIsDirectory:
                .removableMediaPathIsDirectory(id: id, path: path, label: label)
            case .notWritable: .removableMediaNotWritable(id: id, path: path, label: label)
            }
        }

        /// What the alert says was found, which is each error's own words rather
        /// than a guess at a cause.
        var statedInTheMessage: String {
            switch self {
            case .notFound: "not found at"
            case .pathIsDirectory: "is a directory, not a file"
            case .notWritable: "is not writable"
            }
        }
    }

    @Test(
        "A resume offers the removal however the medium turned out to be unusable",
        arguments: UnusableAttachment.allCases)
    func resumeOffersRemovalForEveryUnusableMedium(way: UnusableAttachment) async throws {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let item = RemovableMediaItem(path: "/tmp/stale.iso", readOnly: true, label: "Stale ISO")
        let instance = viewModel.library.admitFixture(phase: .suspended) { $0.removableMedia = [item] }
        try VMInstanceFixture.writeSaveFile(for: instance)
        // A resume restoring a saved state assembles the same configuration a
        // boot does, so it fails over the same entry.
        virtService.restoreError = way.removableMedia(
            id: item.id, path: item.path, label: item.label)

        await viewModel.resume(instance)

        #expect(presenter.startFailedAttachments.count == 1, "\(way)")
        #expect(presenter.startFailedAttachments.first?.kind == .removableMedia, "\(way)")
        #expect(presenter.startFailedAttachments.first?.id == item.id, "\(way)")
        #expect(presenter.startFailedAttachments.first?.verb == .resume, "\(way)")
        #expect(
            presenter.startFailedAttachments.first?.message.contains(way.statedInTheMessage) == true,
            "\(way)")
        #expect(presenter.errors.isEmpty, "\(way)")
    }

    /// The same rule reaches an in-bundle disk the user created: `createStorageDisk`
    /// writes a new file under a new identity rather than re-adopting this one,
    /// so its entry is no more recoverable than `Disk.asif`'s.
    @Test("An internal disk the user added is not offered either")
    func internalAdditionalDiskIsNotOffered() async {
        let virtService = MockVirtualizationService()
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let extra = StorageDisk(
            id: UUID(), path: "AdditionalDisks/\(UUID().uuidString).asif", readOnly: false,
            label: "20 GB Disk", isInternal: true, kind: .virtio)
        let instance = makeInstanceWithDisks(in: viewModel.library) { [StorageDisk.mainDisk(layout: $0), extra] }
        virtService.startError = ConfigurationBuilderError.storageDiskNotFound(
            id: extra.id, path: extra.path, label: extra.label)

        await viewModel.start(instance)

        #expect(presenter.startFailedAttachments.isEmpty)
        #expect(presenter.showError == true)
    }

    // MARK: - saveForTermination / tryForceStop

    @Test("Once the termination has begun, its own suspend is admitted and a user's is refused")
    func terminationSuspendIsItsOwn() async throws {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let user = viewModel.library.admitFixture(name: "User")
        let quit = viewModel.library.admitFixture(name: "Quit")
        for instance in [user, quit] {
            instance.activity.placeForTesting(.running(sessionID: UUID()))
            instance.peers = viewModel.library
        }

        viewModel.beginTermination()

        await #expect(throws: CommandError.terminating) {
            try await viewModel.commandsLeavingEditsOpen.suspend(.id(user.id))
        }
        #expect(user.status == .running)
        try await viewModel.saveForTermination(quit)
        #expect(virtService.saveCallCount == 1)
        #expect(quit.status == .suspended)
    }

    // MARK: - Create VM

    /// A wizard filled in for the simplest Linux EFI VM, which every create
    /// test varies from.
    private func makeCreationWizard(
        name: String, startAfterCreate: Bool = true
    ) -> VMCreationViewModel {
        let wizard = VMCreationViewModel.overFakeEngine()
        wizard.selectedOS = .linux
        wizard.linuxBootMode = .efi
        wizard.vmName = name
        wizard.startAfterCreate = startAfterCreate
        return wizard
    }

    @Test("createVM leaves nothing at the bundle URL when publication fails")
    func createVMPublishFailureLeavesNothingBehind() async throws {
        let storage = MockVMStorageService()
        storage.setPublishBundleError(
            VMStorageError.bundleAlreadyExists(
                URL(filePath: "/tmp/occupied.kernova")))
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let wizard = makeCreationWizard(name: "Unpublishable VM", startAfterCreate: false)

        try viewModel.createVM(from: wizard)
        let destination = try #require(viewModel.arrivals.first).destinationURL
        try await viewModel.awaitArrivals()

        #expect(viewModel.entries.isEmpty)
        #expect(storage.bundles[destination] == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)))
        #expect(presenter.showError == true)
        let staged = try #require(storage.stagedBundleURLs.last)
        #expect(storage.discardedStagedURLs == [staged])
    }

    // MARK: - Cancel Installation

    @Test(
        "Install cancel that races a non-CancellationError still returns VM to .initialBoot"
    )
    func cancelRaceWithNonCancelErrorReturnsToInitialBoot() async throws {
        // Production scenario from the same PR as the IPSW size-check fix:
        // the user clicks Cancel during download, but a non-cancel error
        // (e.g. network failure or `.downloadFailed`) reaches the catch
        // before the cancellation propagates. Before this fix, the generic
        // `catch {}` branch saw `Task.isCancelled == true` and silently
        // suppressed the error — leaving the VM in `.error` with no dialog
        // and no path back to `.initialBoot`. The fix normalizes that case
        // to the cancel outcome.
        let raceInstaller = SuspendingMockMacOSInstallService(
            terminalError: DownloadError.downloadFailed(URLError(.badServerResponse)))
        let storage = MockVMStorageService()
        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            machineFiles: VMBundleMachineFiles(fileSystem: MockFileSystem(), platform: FakePlatformFiles()),
            virtualizationHost: FakeVirtualizationHost(),
            virtualizationService: MockVirtualizationService(),
            installService: raceInstaller,
            ipswService: MockIPSWService(),
            localImageInspector: MockLocalRestoreImageInspector(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            bridgedInterfaces: MockBridgedInterfaceProvider(),
            fileSystem: MockFileSystem(),
            downloadsDirectory: makeTestDownloadsDirectory(),
            preferences: preferences,
            vmnetNetworks: VmnetNetworkService.scripted(),
            arpTable: ScriptedARPTable(),
            entitlements: .entitled,
            hostNotifications: .isolated(),
            hostPasteboard: FakePasteboard(),
            bundleProducts: .testing
        )
        viewModel.presenter = presenter
        viewModel.libraryWindowPresenter = presenter
        let instance = viewModel.library.registerFixture(name: "Race VM") {
            $0.installContext = MacOSInstallContext(
                source: .localFile, localIPSWPath: "/tmp/foo.ipsw"
            )
        }
        instance.activity.placeForTesting(.initialBoot)

        // Spawn the install + auto-boot pipeline; returns immediately after
        // launching the setup operation.
        await viewModel.start(instance)

        // Wait until the mock install has parked, so the cancel below
        // actually races a running install rather than a not-yet-started one.
        _ = try await awaitFirst(raceInstaller.installStartedStream)

        viewModel.cancelGuestSetup(instance)

        // Drain the install task to completion so post-conditions are
        // observable (the catch block runs synchronously after await).
        try await instance.setupOperationTask?.joined()

        // The fix routes this case through the cancel outcome: VM is back
        // to .initialBoot, no error dialog, error message cleared.
        #expect(instance.status == .initialBoot)
        #expect(instance.errorMessage == nil)
        #expect(presenter.showError == false)
    }

    // MARK: - Agent Install Nudge

    @Test("dismissAgentInstallNudge still sets the flag to true")
    func dismissAgentInstallNudgeSetsTrue() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = viewModel.library.admitFixture(guestOS: .macOS, files: storage.files)

        viewModel.dismissAgentInstallNudge(for: instance)

        #expect(instance.hostState.agentInstallNudgeDismissed == true)
        #expect(storage.saveHostStateCallCount == 1)
    }

    @Test(
        "resetAllReminders re-arms the install reminder everywhere, the quit reminder, the machine ID question and the Ephemeral settings banner"
    )
    func resetAllRemindersReArmsEveryReminder() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let first = viewModel.library.admitFixture(
            name: "First", guestOS: .macOS,
            hostState: VMHostState(agentInstallNudgeDismissed: true))
        let second = viewModel.library.admitFixture(
            name: "Second", guestOS: .macOS,
            hostState: VMHostState(agentInstallNudgeDismissed: true))
        let third = viewModel.library.admitFixture(name: "Third", guestOS: .macOS)
        // `third` stays armed to confirm the reset no-ops on already-armed VMs.
        viewModel.agentInstallPromptDisabled = true
        viewModel.duplicateMachineIDQuestionDismissed = true
        viewModel.menuBarQuitReminderDismissed = true
        viewModel.ephemeralSettingsBannerDismissed = true

        viewModel.resetAllReminders()

        #expect(first.hostState.agentInstallNudgeDismissed == false)
        #expect(second.hostState.agentInstallNudgeDismissed == false)
        #expect(third.hostState.agentInstallNudgeDismissed == false)
        #expect(viewModel.agentInstallPromptDisabled == false)
        #expect(preferences.agentInstallPromptDisabled == false)
        #expect(viewModel.duplicateMachineIDQuestionDismissed == false)
        #expect(preferences.duplicateMachineIDQuestionDismissed == false)
        #expect(viewModel.menuBarQuitReminderDismissed == false)
        #expect(preferences.menuBarQuitReminderDismissed == false)
        #expect(viewModel.ephemeralSettingsBannerDismissed == false)
        #expect(preferences.ephemeralSettingsBannerDismissed == false)
    }

    @Test("hasUninterruptibleWork covers transitioning VMs but not settled ones")
    func hasUninterruptibleWorkCoversTransitions() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = viewModel.library.admitFixture()

        for phase in Self.transitionalPhases {
            instance.activity.placeForTesting(phase)
            #expect(viewModel.hasUninterruptibleWork, "\(phase)")
        }
        // Termination save-suspends these, so they must not hold a quit back.
        for phase in [
            VMLifecyclePhase.running(sessionID: UUID()), .livePaused(sessionID: UUID()),
            .suspended, .stopped,
        ] {
            instance.activity.placeForTesting(phase)
            #expect(!viewModel.hasUninterruptibleWork, "\(phase)")
        }
    }

    @Test("quitMustWaitOut covers exactly the operations that declare a quit waits them out")
    func quitMustWaitOutCoversWaitOutKinds() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = viewModel.library.admitFixture()

        for phase in VMLifecyclePhaseFixtures.all {
            instance.activity.placeForTesting(phase)
            let waitsOut = phase.operation?.kind.declaration.quit == .waitOut
            #expect(viewModel.quitMustWaitOut == waitsOut, "\(phase)")
        }
        // Spelled out, so the declarations above cannot drift unnoticed: a
        // quit exits through a bring-up, a copy out and a Force Stop — whose
        // process the exit ends — and waits out the writes a snapshot trash,
        // a delete and a revert make.
        let live = VMLifecyclePhase.running(sessionID: UUID())
        for phase in [
            VMLifecyclePhase.operating(.saving, from: live),
            .operating(.capturingSnapshot(.live), from: live),
            .operating(.deletingSnapshot, from: live),
            .operating(.deleting, from: .stopped),
            .operating(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped),
            .operating(.creatingStorageDisk, from: .stopped),
            .operating(.removingStorageDisk, from: .stopped),
            .operating(.creatingRemovableMedia, from: live),
        ] {
            instance.activity.placeForTesting(phase)
            #expect(viewModel.quitMustWaitOut, "\(phase)")
        }
        for phase in [
            VMLifecyclePhase.operating(
                .bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
            .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot),
            .operating(.copyingOut(.stopped), from: .stopped),
            .operating(.forceStopping, from: live),
            live, .suspended, .stopped,
        ] {
            instance.activity.placeForTesting(phase)
            #expect(!viewModel.quitMustWaitOut, "\(phase)")
        }
    }

    // MARK: - Rename

    @Test("commitRename updates name and persists")
    func commitRenameUpdatesName() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = viewModel.library.admitFixture(name: "Old Name", files: storage.files)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "New Name", from: .detail)

        #expect(instance.name == "New Name")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 1)
    }

    // MARK: - Launch Auto-Start

    /// Every mid-operation phase, each with the session identity its own case
    /// admits.
    /// An operation of every kind that shows a status of its own.
    private static var transitionalPhases: [VMLifecyclePhase] {
        let live = VMLifecyclePhase.running(sessionID: UUID())
        return [
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: UUID()),
            .operating(.saving, from: live),
            .operating(.capturingSnapshot(.live), from: live),
            .operating(.capturingSnapshot(.stopped), from: .stopped),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
            .operating(
                .bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)), from: .stopped),
            .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot),
        ]
    }

    // MARK: - Import

    /// `importVM` copies real files, so a test whose copy succeeds needs the bundle on disk;
    /// one modeling a never-copied source passes `createOnDisk: false`, which seeds `storage`.
    private func makeImportSource(
        name: String, storage: MockVMStorageService, createOnDisk: Bool = true
    ) throws -> (url: URL, config: VMConfiguration) {
        let source = try scratch.importSource(name: name, onDisk: createOnDisk)
        if !createOnDisk {
            // Nothing is copied, so the source only has to read.
            storage.setConfiguration(source.config, at: source.url)
        }
        return source
    }

    /// Auto-start runs a guest with no user action, so it is local intent rather
    /// than something a bundle carries in from elsewhere.
    @Test("Importing a bundle pre-marked to start automatically clears the flag")
    func importClearsAutoStartFlag() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let source = try makeImportSource(name: "Pre-marked VM", storage: storage)
        // A real file, since the import copies the source directory itself.
        try VMStagedBundle.fixtureForTesting(at: source.url, access: CoordinatedBundleFileAccess()).update(.hostState) {
            $0 = VMHostState(startsAutomaticallyOnLaunch: true, displayPreference: .popOut)
        }

        _ = viewModel.importVMs(fromDroppedURLs: [source.url])
        try await viewModel.awaitArrivals()

        let imported = try #require(viewModel.instances.first)
        #expect(imported.hostState.startsAutomaticallyOnLaunch == false)
        // …and the cleared flag reached the imported bundle, not just the row.
        let importedFiles = VMBundleFiles(url: imported.bundleURL, access: CoordinatedBundleFileAccess())
        #expect(try importedFiles.read().hostState.startsAutomaticallyOnLaunch == false)
        // The rest of the host state arrives with the bundle: the row reads the
        // published bundle rather than keeping the defaults it was built with.
        #expect(imported.hostState.displayPreference == .popOut)
    }

    @Test("A dropped batch's imports hold the drop's grants until they have copied, then give each back once")
    func droppedImportsHoldTheDropsGrants() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let sources = try [
            makeImportSource(name: "Dropped VM 1", storage: storage),
            makeImportSource(name: "Dropped VM 2", storage: storage),
        ]
        let pasteboard = FakePasteboard()
        pasteboard.setFiles(sources.map(\.url))
        let sandbox = pasteboard.sandbox

        var read: (urls: [URL], access: PasteboardFileAccess)? = PasteboardFileAccess.readFileURLs(from: pasteboard)
        #expect(viewModel.importVMs(fromDroppedURLs: read?.urls ?? [], holding: read?.access))
        read = nil
        #expect(sources.map { sandbox.grants(of: $0.url) } == [1, 1])

        try await viewModel.awaitArrivals()
        #expect(viewModel.instances.count == 2)
        try await sandbox.changed.wait { sources.allSatisfy { sandbox.grants(of: $0.url) == 0 } }
        #expect(sandbox.unheldGiveBacks.isEmpty)
    }

    // MARK: - Clone

    @Test("An Exact Copy carries its source's snapshots and host state, but not start at launch")
    func exactCopyCarriesSnapshotsAndHostState() async throws {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let baseline = UUID()
        let later = UUID()
        var sourceHostState = VMHostState(
            startsAutomaticallyOnLaunch: true, displayPreference: .fullscreen,
            lastFullscreenDisplayID: 4_280_803_137, agentInstallNudgeDismissed: true)
        sourceHostState.applyEphemeralMode(enabled: true, baseline: baseline)
        let manifest = VMSnapshotManifest(
            snapshots: [
                VMSnapshot(id: baseline, name: "Baseline", macAddress: nil),
                VMSnapshot(id: later, name: "Later", macAddress: nil),
            ],
            currentID: later)
        let instance = viewModel.library.registerFixture(
            name: "Original", hostState: sourceHostState, snapshots: manifest)
        instance.activity.placeForTesting(.stopped)

        // Each listed snapshot's directory, plus a revert's staging directory
        // and a directory no manifest entry names — neither of which is a
        // snapshot the copy holds.
        let layout = instance.bundleLayout
        let fm = FileManager.default
        for id in [baseline, later] {
            let directory = layout.snapshotDirectoryURL(id: id)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(id.uuidString.utf8).write(to: directory.appendingPathComponent("marker"))
        }
        let orphan = UUID()
        try fm.createDirectory(
            at: layout.snapshotDirectoryURL(id: orphan), withIntermediateDirectories: true)
        try fm.createDirectory(at: layout.restoreStagingURL, withIntermediateDirectories: true)

        viewModel.cloneVM(instance, as: .exactCopy)
        try await viewModel.awaitArrivals()
        let clone = try #require(viewModel.instances.first { $0.id != instance.id })

        var expectedHostState = sourceHostState
        expectedHostState.startsAutomaticallyOnLaunch = false
        #expect(clone.hostState == expectedHostState)
        #expect(clone.snapshotManifest.snapshots.map(\.id) == [baseline, later])
        #expect(clone.snapshotManifest.currentID == later)
        // The Ephemeral baseline names a snapshot the copy itself holds.
        #expect(clone.snapshotManifest.snapshot(id: baseline) != nil)

        let cloneLayout = clone.bundleLayout
        for id in [baseline, later] {
            let marker = cloneLayout.snapshotDirectoryURL(id: id).appendingPathComponent("marker")
            #expect(try Data(contentsOf: marker) == Data(id.uuidString.utf8))
        }
        #expect(
            !fm.fileExists(
                atPath: cloneLayout.snapshotDirectoryURL(id: orphan).path(percentEncoded: false)))
        #expect(!fm.fileExists(atPath: cloneLayout.restoreStagingURL.path(percentEncoded: false)))
        #expect(storage.lastCloneRelativePaths?.contains(VMBundleLayout.usbPairingsRelativePath) == false)
        #expect(instance.hostState == sourceHostState)
    }

    // MARK: - Force Stop Confirmation

    @Test("requestForceStop sets instance and shows confirmation")
    func requestForceStop() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = viewModel.library.admitFixture()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        viewModel.requestForceStop(instance)

        #expect(presenter.instanceToForceStop?.id == instance.id)
        #expect(presenter.showForceStopConfirmation == true)
    }

    // MARK: - Reorder

    @Test("moveEntries reorders instances and persists order to UserDefaults")
    func moveEntriesReordersAndPersists() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let a = viewModel.library.admitFixture(name: "A")
        let b = viewModel.library.admitFixture(name: "B")
        let c = viewModel.library.admitFixture(name: "C")

        viewModel.moveEntries(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(viewModel.instances.map(\.name) == ["C", "A", "B"])
        #expect(preferences.vmOrder == [c.id, a.id, b.id])
    }

    // MARK: - Storage Disk Helpers

    @Test("sharingVMNames lists other VMs referencing a path and excludes the instance")
    func sharingVMNamesDetectsAndExcludes() async throws {
        let (viewModel, _, _, _, _) = makeViewModel()
        let sharedPath = "/Volumes/External/shared.img"
        let target = viewModel.library.admitFixture(name: "Target") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "S", isInternal: false, kind: .virtio)
            ]
        }
        viewModel.library.admitFixture(name: "DiskSharer") {
            $0.storageDisks = [
                StorageDisk(
                    path: sharedPath, readOnly: false, label: "S", isInternal: false, kind: .virtio)
            ]
        }
        viewModel.library.admitFixture(name: "MediaSharer") {
            $0.removableMedia = [RemovableMediaItem(path: sharedPath, readOnly: true)]
        }
        viewModel.library.admitFixture(name: "Unrelated")

        let names = await viewModel.sharingVMNames(forPath: sharedPath, bookmark: nil, excluding: target)
        #expect(Set(names) == ["DiskSharer", "MediaSharer"])

        // A unique path is shared with no one.
        let unique = await viewModel.sharingVMNames(
            forPath: "/Volumes/External/unique.img", bookmark: nil, excluding: target)
        #expect(unique.isEmpty)
    }

    // MARK: - Reconcile Rollback

    @Test("Failed swap rollback preserves the entry's label and note")
    func liveRemovableRollbackOnSwapFailurePreservesLabelAndNotes() async throws {
        struct TransientError: Error {}
        let mock = MockRemovableMediaDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(removableMediaDeviceService: mock)
        let id = UUID()
        var oldItem = RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true, label: "Installer")
        oldItem.notes = "from the Ubuntu mirror"
        let instance = viewModel.library.admitFixture { $0.removableMedia = [oldItem] }
        let sessionID = UUID()
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        instance.recordAttachedMedia(
            RemovableMediaDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true), for: sessionID)

        // Same id, different path (path swap) — the target persists, carrying
        // the label and note forward since only the path/readOnly changed.
        var newItem = oldItem
        newItem.path = "/tmp/new.iso"
        viewModel.library.editConfiguration(of: instance, as: .hotPlugMedia) { $0.removableMedia = [newItem] }
        try await instance.waitUntilIdle()
        #expect(presenter.showError)

        // Swap failed → the rolled-back entry must still carry the persisted
        // label and note, not a bare reconstruction from path/readOnly alone.
        let rolled = try #require(instance.configuration.removableMedia)
        #expect(rolled.first?.label == "Installer")
        #expect(rolled.first?.notes == "from the Ubuntu mirror")
    }
}
