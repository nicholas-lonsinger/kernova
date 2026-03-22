import Testing
import Foundation
@testable import Kernova

@Suite("VMLibraryViewModel Tests", .serialized)
@MainActor
struct VMLibraryViewModelTests {

    private func makeViewModel(
        storageService: MockVMStorageService = MockVMStorageService(),
        diskImageService: MockDiskImageService = MockDiskImageService(),
        virtualizationService: MockVirtualizationService = MockVirtualizationService()
    ) -> (VMLibraryViewModel, MockVMStorageService, MockDiskImageService, MockVirtualizationService) {
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.vmOrderKey)
        let vm = VMLibraryViewModel(
            storageService: storageService,
            diskImageService: diskImageService,
            virtualizationService: virtualizationService,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService()
        )
        return (vm, storageService, diskImageService, virtualizationService)
    }

    private func makeInstance(name: String = "Test VM") -> VMInstance {
        let config = VMConfiguration(
            name: name,
            guestOS: .linux,
            bootMode: .efi
        )
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    // MARK: - Initial State

    @Test("ViewModel starts with empty instances when storage is empty")
    func initialStateEmpty() {
        let (viewModel, _, _, _) = makeViewModel()
        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        #expect(viewModel.showCreationWizard == false)
        #expect(viewModel.showError == false)
    }

    // MARK: - Load

    @Test("loadVMs auto-selects the first VM")
    func loadVMsAutoSelectsFirst() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (viewModel, _, _, _) = makeViewModel(storageService: storage)

        #expect(viewModel.instances.count == 2)
        #expect(viewModel.selectedID == viewModel.instances.first?.id)
    }

    @Test("loadVMs preserves valid selection on reload")
    func loadVMsPreservesSelection() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (viewModel, _, _, _) = makeViewModel(storageService: storage)
        let secondID = viewModel.instances.last?.id
        viewModel.selectedID = secondID

        viewModel.loadVMs()

        #expect(viewModel.selectedID == secondID)
    }

    // MARK: - Selection Persistence

    @Test("selectedID persists to UserDefaults on change")
    func selectedIDPersistsToUserDefaults() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.selectedID = instance.id

        let stored = UserDefaults.standard.string(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        #expect(stored == instance.id.uuidString)
    }

    @Test("selectedID clears UserDefaults when set to nil")
    func selectedIDClearsUserDefaults() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id

        viewModel.selectedID = nil

        let stored = UserDefaults.standard.string(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        #expect(stored == nil)
    }

    @Test("loadVMs restores selection from UserDefaults when VM still exists")
    func loadVMsRestoresFromUserDefaults() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First VM", guestOS: .linux, bootMode: .efi)
        let config2 = VMConfiguration(name: "Second VM", guestOS: .linux, bootMode: .efi)
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        // Clear then seed UserDefaults before ViewModel init triggers loadVMs()
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.set(config2.id.uuidString, forKey: VMLibraryViewModel.lastSelectedVMIDKey)

        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService()
        )

        #expect(viewModel.selectedID == config2.id)
    }

    @Test("loadVMs falls back to first VM when stored ID is invalid")
    func loadVMsFallsBackWhenStoredIDInvalid() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Only VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        // Clear then seed UserDefaults with a UUID that doesn't match any VM
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.set(UUID().uuidString, forKey: VMLibraryViewModel.lastSelectedVMIDKey)

        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService()
        )

        #expect(viewModel.selectedID == config.id)
    }

    // MARK: - Delete

    @Test("confirmDelete sets instance and shows confirmation")
    func confirmDelete() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.confirmDelete(instance)

        #expect(viewModel.instanceToDelete?.id == instance.id)
        #expect(viewModel.showDeleteConfirmation == true)
    }

    @Test("deleteConfirmed removes instance and clears selection")
    func deleteConfirmed() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id

        // Pre-populate mock storage so delete doesn't throw
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.deleteConfirmed(instance)

        #expect(viewModel.instances.isEmpty)
        #expect(viewModel.selectedID == nil)
        #expect(viewModel.showDeleteConfirmation == false)
        #expect(viewModel.instanceToDelete == nil)
        #expect(storage.deleteVMBundleCallCount == 1)
    }

    @Test("deleteConfirmed selects first remaining instance when deleting selected")
    func deleteConfirmedUpdatesSelection() {
        let (viewModel, storage, _, _) = makeViewModel()
        let first = makeInstance(name: "First")
        let second = makeInstance(name: "Second")
        viewModel.instances = [first, second]
        viewModel.selectedID = second.id

        storage.bundles[second.bundleURL] = second.configuration

        viewModel.deleteConfirmed(second)

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.selectedID == first.id)
    }

    // MARK: - Lifecycle Delegation

    @Test("start delegates to lifecycle coordinator")
    func startDelegates() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("stop delegates to lifecycle coordinator")
    func stopDelegates() {
        let (viewModel, _, _, virtService) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.stop(instance)

        #expect(virtService.stopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("forceStop delegates to lifecycle coordinator")
    func forceStopDelegates() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("pause delegates to lifecycle coordinator")
    func pauseDelegates() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.pause(instance)

        #expect(virtService.pauseCallCount == 1)
        #expect(instance.status == .paused)
    }

    @Test("resume delegates to lifecycle coordinator")
    func resumeDelegates() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)

        await viewModel.resume(instance)

        #expect(virtService.resumeCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("save delegates to lifecycle coordinator")
    func saveDelegates() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.save(instance)

        #expect(virtService.saveCallCount == 1)
        #expect(instance.status == .paused)
    }

    // MARK: - Error Handling

    @Test("start presents error on service failure")
    func startPresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.startError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.start(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("forceStop presents error on service failure")
    func forceStopPresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.forceStopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.forceStop(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("stop presents error on service failure")
    func stopPresentsError() {
        let virtService = MockVirtualizationService()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        viewModel.stop(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("pause presents error on service failure")
    func pausePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.pause(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("resume presents error on service failure")
    func resumePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.resume(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("save presents error on service failure")
    func savePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.save(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    // MARK: - Save Configuration

    @Test("saveConfiguration persists via storage service")
    func saveConfigurationPersists() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance()

        viewModel.saveConfiguration(for: instance)

        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("saveConfiguration presents error on failure")
    func saveConfigurationPresentsError() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance()
        storage.saveConfigurationError = NSError(domain: "test", code: 1)

        viewModel.saveConfiguration(for: instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    // MARK: - trySave / tryForceStop

    @Test("trySave throws on failure")
    func trySaveThrows() async {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await viewModel.trySave(instance)
        }
    }

    @Test("tryForceStop throws on failure")
    func tryForceStopThrows() async {
        let virtService = MockVirtualizationService()
        virtService.forceStopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await viewModel.tryForceStop(instance)
        }
    }

    // MARK: - Selected Instance

    @Test("selectedInstance returns the instance matching selectedID")
    func selectedInstance() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id

        #expect(viewModel.selectedInstance?.id == instance.id)
    }

    @Test("selectedInstance returns nil when no match")
    func selectedInstanceNil() {
        let (viewModel, _, _, _) = makeViewModel()
        viewModel.selectedID = UUID()

        #expect(viewModel.selectedInstance == nil)
    }

    // MARK: - Create VM

    @Test("createVM creates bundle, disk image, and adds instance")
    func createVMAddsInstance() async {
        let (viewModel, storage, diskService, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "New Linux VM"

        await viewModel.createVM(from: wizard)

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "New Linux VM")
        #expect(storage.createVMBundleCallCount == 1)
        #expect(diskService.createDiskImageCallCount == 1)
    }

    @Test("createVM selects newly created instance")
    func createVMSelectsInstance() async {
        let (viewModel, _, _, _) = makeViewModel()
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Selected VM"

        await viewModel.createVM(from: wizard)

        #expect(viewModel.selectedID == viewModel.instances.first?.id)
    }

    @Test("createVM presents error when bundle creation fails")
    func createVMBundleError() async {
        let storage = MockVMStorageService()
        storage.createVMBundleError = VMStorageError.bundleAlreadyExists(UUID())
        let (viewModel, _, _, _) = makeViewModel(storageService: storage)
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Fail VM"

        await viewModel.createVM(from: wizard)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.instances.isEmpty)
    }

    @Test("createVM presents error when disk image creation fails")
    func createVMDiskImageError() async {
        let diskService = MockDiskImageService()
        diskService.createDiskImageError = NSError(domain: "test", code: 1)
        let (viewModel, _, _, _) = makeViewModel(diskImageService: diskService)
        let wizard = VMCreationViewModel()
        wizard.selectedOS = .linux
        wizard.selectedBootMode = .efi
        wizard.vmName = "Disk Fail VM"

        await viewModel.createVM(from: wizard)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    // MARK: - Reconcile With Disk

    @Test("reconcileWithDisk adds discovered bundles not in memory")
    func reconcileAddsNewBundles() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Discovered VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[bundleURL] = config

        let (viewModel, _, _, _) = makeViewModel(storageService: storage)
        // loadVMs already ran during init, so the instance should be loaded
        // But let's clear and reconcile manually to test the specific method
        viewModel.instances.removeAll()

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Discovered VM")
    }

    @Test("reconcileWithDisk removes stopped VMs whose bundles are gone")
    func reconcileRemovesStoppedVMs() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Gone VM")
        instance.status = .stopped
        viewModel.instances.append(instance)

        // Storage has no bundles, so instance should be removed
        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.isEmpty)
    }

    @Test("reconcileWithDisk preserves running VMs even if bundle is missing")
    func reconcilePreservesRunningVMs() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Running VM")
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Running VM")
    }

    @Test("reconcileWithDisk preserves paused VMs even if bundle is missing")
    func reconcilePreservesPausedVMs() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Paused VM")
        instance.status = .paused
        viewModel.instances.append(instance)

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Paused VM")
    }

    @Test("reconcileWithDisk updates selection when selected stopped VM is removed")
    func reconcileUpdatesSelection() {
        let (viewModel, storage, _, _) = makeViewModel()
        let remaining = makeInstance(name: "Remaining")
        let removed = makeInstance(name: "Removed")
        removed.status = .stopped
        viewModel.instances = [remaining, removed]
        viewModel.selectedID = removed.id

        // Only keep the remaining instance's bundle on disk
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(remaining.id.uuidString).kernova", isDirectory: true)
        storage.bundles = [bundleURL: remaining.configuration]

        viewModel.reconcileWithDisk()

        #expect(viewModel.selectedID == remaining.id || viewModel.selectedID != removed.id)
    }

    // MARK: - Cancel Installation

    #if arch(arm64)
    @Test("cancelInstallation removes instance and deletes bundle")
    func cancelInstallationRemovesInstance() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance(name: "Installing VM")
        instance.status = .installing
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cancelInstallation(instance)

        #expect(viewModel.instances.isEmpty)
        #expect(storage.deleteVMBundleCallCount == 1)
    }

    @Test("cancelInstallation updates selection to first remaining instance")
    func cancelInstallationUpdatesSelection() {
        let (viewModel, storage, _, _) = makeViewModel()
        let first = makeInstance(name: "First")
        let installing = makeInstance(name: "Installing")
        installing.status = .installing
        viewModel.instances = [first, installing]
        viewModel.selectedID = installing.id
        storage.bundles[installing.bundleURL] = installing.configuration

        viewModel.cancelInstallation(installing)

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.selectedID == first.id)
    }
    #endif

    // MARK: - Rename

    @Test("renameVM sets activeRename to detail target")
    func renameVMSetsDetailTarget() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.renameVM(instance)

        #expect(viewModel.activeRename == .detail(instance.id))
    }

    @Test("renameVMInSidebar sets activeRename to sidebar target")
    func renameVMInSidebarSetsSidebarTarget() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.renameVMInSidebar(instance)

        #expect(viewModel.activeRename == .sidebar(instance.id))
    }

    @Test("commitRename updates name and persists")
    func commitRenameUpdatesName() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance(name: "Old Name")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "New Name")

        #expect(instance.name == "New Name")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("commitRename trims whitespace")
    func commitRenameTrimWhitespace() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Original")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "  Trimmed  ")

        #expect(instance.name == "Trimmed")
        #expect(viewModel.activeRename == nil)
    }

    @Test("commitRename rejects empty name and preserves original")
    func commitRenameRejectsEmpty() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance(name: "Keep Me")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "")

        #expect(instance.name == "Keep Me")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("commitRename rejects whitespace-only name and preserves original")
    func commitRenameRejectsWhitespace() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance(name: "Keep Me")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "   ")

        #expect(instance.name == "Keep Me")
        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    @Test("cancelRename clears state without saving")
    func cancelRenameClearsState() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.activeRename = .sidebar(instance.id)

        viewModel.cancelRename()

        #expect(viewModel.activeRename == nil)
        #expect(storage.saveConfigurationCallCount == 0)
    }

    // MARK: - Sleep/Wake

    @Test("pauseAllForSleep pauses only running VMs")
    func pauseAllForSleepPausesRunning() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let running1 = makeInstance(name: "Running 1")
        running1.status = .running
        let running2 = makeInstance(name: "Running 2")
        running2.status = .running
        let stopped = makeInstance(name: "Stopped")
        stopped.status = .stopped
        let paused = makeInstance(name: "User Paused")
        paused.status = .paused
        viewModel.instances = [running1, running2, stopped, paused]

        await viewModel.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 2)
        #expect(viewModel.sleepPausedInstanceIDs == Set([running1.id, running2.id]))
        #expect(running1.status == .paused)
        #expect(running2.status == .paused)
        #expect(stopped.status == .stopped)
        #expect(paused.status == .paused)
    }

    @Test("resumeAllAfterWake resumes only sleep-paused VMs")
    func resumeAllAfterWakeResumesOnlySleepPaused() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let sleepPaused = makeInstance(name: "Sleep Paused")
        sleepPaused.status = .paused
        let userPaused = makeInstance(name: "User Paused")
        userPaused.status = .paused
        viewModel.instances = [sleepPaused, userPaused]
        viewModel.sleepPausedInstanceIDs = Set([sleepPaused.id])

        await viewModel.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 1)
        #expect(sleepPaused.status == .running)
        #expect(userPaused.status == .paused)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("pauseAllForSleep handles pause failure gracefully")
    func pauseAllForSleepHandlesError() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let running = makeInstance(name: "Running")
        running.status = .running
        viewModel.instances = [running]

        await viewModel.pauseAllForSleep()

        // Error is logged, not presented to user
        #expect(viewModel.showError == false)
        // Failed pause should not track the instance
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake clears tracking set even on failure")
    func resumeAllAfterWakeClearsOnError() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance(name: "Sleep Paused")
        instance.status = .paused
        viewModel.instances = [instance]
        viewModel.sleepPausedInstanceIDs = Set([instance.id])

        await viewModel.resumeAllAfterWake()

        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
        #expect(viewModel.showError == false)
    }

    @Test("pauseAllForSleep is no-op when no running VMs")
    func pauseAllForSleepNoOp() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let stopped = makeInstance(name: "Stopped")
        stopped.status = .stopped
        viewModel.instances = [stopped]

        await viewModel.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake is no-op when no sleep-paused VMs")
    func resumeAllAfterWakeNoOp() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let paused = makeInstance(name: "User Paused")
        paused.status = .paused
        viewModel.instances = [paused]
        // sleepPausedInstanceIDs is empty

        await viewModel.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
    }

    @Test("pauseAllForSleep skips non-running states")
    func pauseAllForSleepSkipsNonRunning() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let starting = makeInstance(name: "Starting")
        starting.status = .starting
        let saving = makeInstance(name: "Saving")
        saving.status = .saving
        let error = makeInstance(name: "Error")
        error.status = .error
        viewModel.instances = [starting, saving, error]

        await viewModel.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake skips VMs no longer paused")
    func resumeAllAfterWakeSkipsNonPaused() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let instance = makeInstance(name: "Was Paused")
        instance.status = .stopped  // Status changed between sleep and wake
        viewModel.instances = [instance]
        viewModel.sleepPausedInstanceIDs = Set([instance.id])

        await viewModel.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    // MARK: - Clone

    /// Helper to mark an instance as preparing with a no-op task.
    private func markPreparing(_ instance: VMInstance, operation: VMInstance.PreparingOperation = .cloning) {
        instance.preparingState = VMInstance.PreparingState(operation: operation, task: Task {})
    }

    @Test("cloneVM creates phantom row immediately with preparingState")
    func cloneVMCreatesPhantomRow() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance(name: "Original")
        instance.status = .stopped
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        #expect(viewModel.instances.count == 2)
        let phantom = viewModel.instances.first { $0.id != instance.id }
        #expect(phantom != nil)
        #expect(phantom?.isPreparing == true)
        #expect(phantom?.preparingState?.operation == .cloning)
        #expect(phantom?.name == "Original Copy")
        #expect(viewModel.selectedID == phantom?.id)
    }

    @Test("cloneVM transitions phantom to real on success")
    func cloneVMTransitionsPhantom() async {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance(name: "Original")
        instance.status = .stopped
        viewModel.instances.append(instance)
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        let phantom = viewModel.instances.first { $0.id != instance.id }
        #expect(phantom != nil)

        // Wait for the preparing task to complete
        await phantom?.preparingState?.task.value

        #expect(phantom?.isPreparing == false)
        #expect(phantom?.preparingState == nil)
        #expect(viewModel.instances.count == 2)
        #expect(storage.cloneVMBundleCallCount == 1)
    }

    @Test("cloneVM removes phantom on storage error and selects remaining instance")
    func cloneVMRemovesPhantomOnError() async {
        let storage = MockVMStorageService()
        storage.cloneVMBundleError = VMStorageError.bundleAlreadyExists(UUID())
        let (viewModel, _, _, _) = makeViewModel(storageService: storage)
        let instance = makeInstance(name: "Fail Clone")
        instance.status = .stopped
        viewModel.instances.append(instance)

        viewModel.cloneVM(instance)

        // Phantom was created
        let phantom = viewModel.instances.first { $0.id != instance.id }
        #expect(phantom != nil)

        // Wait for the task to complete (and fail)
        await phantom?.preparingState?.task.value

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.id == instance.id)
        #expect(viewModel.selectedID == instance.id)
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("cloneVM is skipped when VM is running")
    func cloneVMSkippedWhenRunning() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance(name: "Running VM")
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.cloneVM(instance)

        #expect(viewModel.instances.count == 1)
        #expect(storage.cloneVMBundleCallCount == 0)
    }

    @Test("cloneVM shows error when hasPreparing is true")
    func cloneVMShowsErrorWhenPreparing() {
        let (viewModel, _, _, _) = makeViewModel()
        let existing = makeInstance(name: "Existing")
        markPreparing(existing)
        let instance = makeInstance(name: "Source")
        instance.status = .stopped
        viewModel.instances = [existing, instance]

        viewModel.cloneVM(instance)

        // No new instance added, error shown
        #expect(viewModel.instances.count == 2)
        #expect(viewModel.showError == true)
    }

    @Test("cloneVM increments name when Copy already exists")
    func cloneVMIncrementsName() {
        let (viewModel, storage, _, _) = makeViewModel()
        let instance = makeInstance(name: "VM")
        instance.status = .stopped
        let copyInstance = makeInstance(name: "VM Copy")
        viewModel.instances = [instance, copyInstance]
        storage.bundles[instance.bundleURL] = instance.configuration

        viewModel.cloneVM(instance)

        let cloned = viewModel.instances.first { $0.id != instance.id && $0.id != copyInstance.id }
        #expect(cloned?.name == "VM Copy 2")
    }

    // MARK: - Cancel Preparing

    @Test("cancelPreparingConfirmed removes phantom instance and cancels task")
    func cancelPreparingConfirmedRemovesPhantom() {
        let (viewModel, _, _, _) = makeViewModel()
        let phantom = makeInstance(name: "Cloning VM")
        markPreparing(phantom)
        viewModel.instances.append(phantom)
        viewModel.selectedID = phantom.id

        viewModel.cancelPreparingConfirmed(phantom)

        #expect(viewModel.instances.isEmpty)
        #expect(phantom.preparingState == nil)
        #expect(viewModel.showCancelPreparingConfirmation == false)
        #expect(viewModel.preparingInstanceToCancel == nil)
    }

    @Test("cancelPreparingConfirmed selects remaining instance")
    func cancelPreparingConfirmedSelectsRemaining() {
        let (viewModel, _, _, _) = makeViewModel()
        let other = makeInstance(name: "Other VM")
        let phantom = makeInstance(name: "Cloning VM")
        markPreparing(phantom)
        viewModel.instances = [other, phantom]
        viewModel.selectedID = phantom.id

        viewModel.cancelPreparingConfirmed(phantom)

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.selectedID == other.id)
    }

    @Test("confirmCancelPreparing sets state for alert")
    func confirmCancelPreparingSetsState() {
        let (viewModel, _, _, _) = makeViewModel()
        let phantom = makeInstance(name: "Cloning VM")
        markPreparing(phantom)
        viewModel.instances.append(phantom)

        viewModel.confirmCancelPreparing(phantom)

        #expect(viewModel.showCancelPreparingConfirmation == true)
        #expect(viewModel.preparingInstanceToCancel?.id == phantom.id)
    }

    // MARK: - Force Stop Confirmation

    @Test("confirmForceStop sets instance and shows confirmation")
    func confirmForceStop() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.confirmForceStop(instance)

        #expect(viewModel.instanceToForceStop?.id == instance.id)
        #expect(viewModel.showForceStopConfirmation == true)
    }

    @Test("forceStopConfirmed delegates to lifecycle")
    func forceStopConfirmed() async {
        let (viewModel, _, _, virtService) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.forceStopConfirmed(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    // MARK: - hasPreparing

    @Test("hasPreparing returns true when an instance is preparing")
    func hasPreparingTrue() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        markPreparing(instance)
        viewModel.instances.append(instance)

        #expect(viewModel.hasPreparing == true)
    }

    @Test("hasPreparing returns false when no instances are preparing")
    func hasPreparingFalse() {
        let (viewModel, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        #expect(viewModel.hasPreparing == false)
    }

    // MARK: - Reconcile With Disk (Preparing)

    @Test("reconcileWithDisk skips when instances are preparing")
    func reconcileSkipsWhenPreparing() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "New VM", guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[bundleURL] = config

        let (viewModel, _, _, _) = makeViewModel(storageService: storage)
        viewModel.instances.removeAll()

        // Add a preparing instance
        let preparing = makeInstance(name: "Preparing")
        markPreparing(preparing)
        viewModel.instances.append(preparing)

        viewModel.reconcileWithDisk()

        // Should not have added the disk bundle because hasPreparing is true
        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Preparing")
    }

    @Test("reconcileWithDisk preserves preparing instances from removal")
    func reconcilePreservesPreparingInstances() {
        let (viewModel, _, _, _) = makeViewModel()
        let preparing = makeInstance(name: "Preparing VM")
        markPreparing(preparing)
        preparing.status = .stopped
        viewModel.instances.append(preparing)

        // Storage has no bundles — normally this instance would be removed
        // but hasPreparing guard should prevent reconcile from running
        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Preparing VM")
    }

    // MARK: - Reorder

    @Test("moveVM reorders instances and persists order to UserDefaults")
    func moveVMReordersAndPersists() {
        let (viewModel, _, _, _) = makeViewModel()
        let a = makeInstance(name: "A")
        let b = makeInstance(name: "B")
        let c = makeInstance(name: "C")
        viewModel.instances = [a, b, c]

        viewModel.moveVM(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        #expect(viewModel.instances.map(\.name) == ["C", "A", "B"])
        let stored = UserDefaults.standard.stringArray(forKey: VMLibraryViewModel.vmOrderKey)
        #expect(stored == [c.id.uuidString, a.id.uuidString, b.id.uuidString])
    }

    @Test("loadVMs applies custom order from UserDefaults")
    func loadVMsAppliesCustomOrder() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "First", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
        let config2 = VMConfiguration(name: "Second", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let config3 = VMConfiguration(name: "Third", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 300))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        let url3 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config3.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2
        storage.bundles[url3] = config3

        // Set custom order: Third, First, Second
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.set(
            [config3.id.uuidString, config1.id.uuidString, config2.id.uuidString],
            forKey: VMLibraryViewModel.vmOrderKey
        )

        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService()
        )

        #expect(viewModel.instances.map(\.name) == ["Third", "First", "Second"])
    }

    @Test("loadVMs falls back to createdAt when no custom order exists")
    func loadVMsFallsBackToCreatedAt() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "Older", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
        let config2 = VMConfiguration(name: "Newer", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (viewModel, _, _, _) = makeViewModel(storageService: storage)

        #expect(viewModel.instances.map(\.name) == ["Older", "Newer"])
    }

    @Test("reconcileWithDisk appends new VMs after custom-ordered ones")
    func reconcileAppendsNewVMs() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(name: "Existing", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1

        let (viewModel, _, _, _) = makeViewModel(storageService: storage)
        #expect(viewModel.instances.count == 1)

        // Simulate a new VM appearing on disk
        let config2 = VMConfiguration(name: "Discovered", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url2] = config2

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 2)
        // Existing VM should stay first (it's in customOrder), Discovered appends at end
        #expect(viewModel.instances.first?.name == "Existing")
        #expect(viewModel.instances.last?.name == "Discovered")
    }

    @Test("deleteConfirmed removes VM from persisted order")
    func deleteRemovesFromOrder() {
        let (viewModel, storage, _, _) = makeViewModel()
        let a = makeInstance(name: "A")
        let b = makeInstance(name: "B")
        viewModel.instances = [a, b]
        viewModel.selectedID = b.id
        storage.bundles[b.bundleURL] = b.configuration

        viewModel.deleteConfirmed(b)

        let stored = UserDefaults.standard.stringArray(forKey: VMLibraryViewModel.vmOrderKey)
        #expect(stored == [a.id.uuidString])
    }

    @Test("custom order ignores stale UUIDs not present in loaded VMs")
    func customOrderIgnoresStaleUUIDs() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Only VM", guestOS: .linux, bootMode: .efi)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url] = config

        // Set custom order with a stale UUID followed by the real one
        let staleID = UUID()
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.set(
            [staleID.uuidString, config.id.uuidString],
            forKey: VMLibraryViewModel.vmOrderKey
        )

        let viewModel = VMLibraryViewModel(
            storageService: storage,
            diskImageService: MockDiskImageService(),
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService()
        )

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Only VM")
    }
}
