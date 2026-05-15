import Testing
import Foundation
@testable import Kernova

@Suite("VMLibraryViewModel Tests", .serialized)
@MainActor
struct VMLibraryViewModelTests {
    private func makeViewModel(
        storageService: MockVMStorageService = MockVMStorageService(),
        diskImageService: MockDiskImageService = MockDiskImageService(),
        virtualizationService: MockVirtualizationService = MockVirtualizationService(),
        usbDeviceService: any USBDeviceProviding = MockUSBDeviceService()
    ) -> (
        VMLibraryViewModel, MockVMStorageService, MockDiskImageService, MockVirtualizationService,
        any USBDeviceProviding
    ) {
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        UserDefaults.standard.removeObject(forKey: VMLibraryViewModel.vmOrderKey)
        let vm = VMLibraryViewModel(
            storageService: storageService,
            diskImageService: diskImageService,
            virtualizationService: virtualizationService,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: usbDeviceService
        )
        return (vm, storageService, diskImageService, virtualizationService, usbDeviceService)
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
        let (viewModel, _, _, _, _) = makeViewModel()
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

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

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

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let secondID = viewModel.instances.last?.id
        viewModel.selectedID = secondID

        viewModel.loadVMs()

        #expect(viewModel.selectedID == secondID)
    }

    // MARK: - Selection Persistence

    @Test("selectedID persists to UserDefaults on change")
    func selectedIDPersistsToUserDefaults() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.selectedID = instance.id

        let stored = UserDefaults.standard.string(forKey: VMLibraryViewModel.lastSelectedVMIDKey)
        #expect(stored == instance.id.uuidString)
    }

    @Test("selectedID clears UserDefaults when set to nil")
    func selectedIDClearsUserDefaults() {
        let (viewModel, _, _, _, _) = makeViewModel()
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

    @Test("loadVMs surfaces error when individual bundles fail to load")
    func loadVMsSurfacesErrorForFailedBundles() {
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

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        // Good VM loaded, bad VM skipped
        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Good VM")
        // Error surfaced to user about the failed bundle
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
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
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.confirmDelete(instance)

        #expect(viewModel.instanceToDelete?.id == instance.id)
        #expect(viewModel.showDeleteConfirmation == true)
    }

    @Test("deleteConfirmed removes instance and clears selection")
    func deleteConfirmed() {
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        await viewModel.start(instance)

        #expect(virtService.startCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("stop delegates to lifecycle coordinator")
    func stopDelegates() {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.stop(instance)

        #expect(virtService.stopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("forceStop delegates to lifecycle coordinator")
    func forceStopDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.forceStop(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(instance.status == .stopped)
    }

    @Test("pause delegates to lifecycle coordinator")
    func pauseDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        await viewModel.pause(instance)

        #expect(virtService.pauseCallCount == 1)
        #expect(instance.status == .paused)
    }

    @Test("resume delegates to lifecycle coordinator")
    func resumeDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)

        await viewModel.resume(instance)

        #expect(virtService.resumeCallCount == 1)
        #expect(instance.status == .running)
    }

    @Test("save delegates to lifecycle coordinator")
    func saveDelegates() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.start(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("forceStop presents error on service failure")
    func forceStopPresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.forceStopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.forceStop(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("stop presents error on service failure")
    func stopPresentsError() {
        let virtService = MockVirtualizationService()
        virtService.stopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        viewModel.stop(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    // MARK: - Stop Paused Confirmation

    // Note: the `stop()` branch that diverts a *live-paused* instance to the
    // confirmation sheet (status == .paused && virtualMachine != nil) is not
    // directly unit-tested here. Triggering it requires a non-nil
    // VZVirtualMachine, which the existing test infrastructure cannot
    // construct (matching VMInstanceTests.swift:82 / VMStatusSerialConsoleTests.swift:25).
    // The branch is exercised at integration time. Tests below cover the
    // surrounding behavior: resumeAndStop dispatch, error surfacing, and
    // confirming `.running` instances skip the confirmation flow.

    @Test("resumeAndStop dispatches resume then stop")
    func resumeAndStopDispatches() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)

        await viewModel.resumeAndStop(instance)

        #expect(virtService.resumeCallCount == 1)
        #expect(virtService.stopCallCount == 1)
    }

    @Test("resumeAndStop clears confirmation state after dispatch")
    func resumeAndStopClearsConfirmationState() async {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)
        viewModel.instanceToStopPaused = instance
        viewModel.showStopPausedConfirmation = true

        await viewModel.resumeAndStop(instance)

        #expect(viewModel.instanceToStopPaused == nil)
        #expect(viewModel.showStopPausedConfirmation == false)
    }

    @Test("forceStopFromPaused dispatches forceStop and clears state")
    func forceStopFromPausedDispatches() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .paused
        viewModel.instances.append(instance)
        viewModel.instanceToStopPaused = instance
        viewModel.showStopPausedConfirmation = true

        await viewModel.forceStopFromPaused(instance)

        #expect(virtService.forceStopCallCount == 1)
        #expect(viewModel.instanceToStopPaused == nil)
        #expect(viewModel.showStopPausedConfirmation == false)
    }

    @Test("resumeAndStop presents error if resume fails")
    func resumeAndStopPresentsErrorOnResumeFailure() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()
        instance.status = .paused

        await viewModel.resumeAndStop(instance)

        #expect(viewModel.showError == true)
        #expect(virtService.stopCallCount == 0)
    }

    @Test("stop on running VM still delegates directly without confirmation")
    func stopRunningSkipsConfirmation() {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.stop(instance)

        #expect(virtService.stopCallCount == 1)
        #expect(viewModel.showStopPausedConfirmation == false)
        #expect(viewModel.instanceToStopPaused == nil)
    }

    @Test("pause presents error on service failure")
    func pausePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.pauseError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.pause(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("resume presents error on service failure")
    func resumePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.resume(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("save presents error on service failure")
    func savePresentsError() async {
        let virtService = MockVirtualizationService()
        virtService.saveError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await viewModel.save(instance)

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
    }

    // MARK: - Save Configuration

    @Test("saveConfiguration persists via storage service")
    func saveConfigurationPersists() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance()

        viewModel.saveConfiguration(for: instance)

        #expect(storage.saveConfigurationCallCount == 1)
    }

    @Test("saveConfiguration presents error on failure")
    func saveConfigurationPresentsError() {
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await viewModel.trySave(instance)
        }
    }

    @Test("tryForceStop throws on failure")
    func tryForceStopThrows() async {
        let virtService = MockVirtualizationService()
        virtService.forceStopError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance()

        await #expect(throws: VirtualizationError.self) {
            try await viewModel.tryForceStop(instance)
        }
    }

    // MARK: - Selected Instance

    @Test("selectedInstance returns the instance matching selectedID")
    func selectedInstance() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)
        viewModel.selectedID = instance.id

        #expect(viewModel.selectedInstance?.id == instance.id)
    }

    @Test("selectedInstance returns nil when no match")
    func selectedInstanceNil() {
        let (viewModel, _, _, _, _) = makeViewModel()
        viewModel.selectedID = UUID()

        #expect(viewModel.selectedInstance == nil)
    }

    // MARK: - Create VM

    @Test("createVM creates bundle, disk image, and adds instance")
    func createVMAddsInstance() async {
        let (viewModel, storage, diskService, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
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
        let (viewModel, _, _, _, _) = makeViewModel(diskImageService: diskService)
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

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        // loadVMs already ran during init, so the instance should be loaded
        // But let's clear and reconcile manually to test the specific method
        viewModel.instances.removeAll()

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Discovered VM")
    }

    @Test("reconcileWithDisk removes stopped VMs whose bundles are gone")
    func reconcileRemovesStoppedVMs() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Gone VM")
        instance.status = .stopped
        viewModel.instances.append(instance)

        // Storage has no bundles, so instance should be removed
        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.isEmpty)
    }

    @Test("reconcileWithDisk preserves running VMs even if bundle is missing")
    func reconcilePreservesRunningVMs() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Running VM")
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Running VM")
    }

    @Test("reconcileWithDisk preserves paused VMs even if bundle is missing")
    func reconcilePreservesPausedVMs() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Paused VM")
        instance.status = .paused
        viewModel.instances.append(instance)

        viewModel.reconcileWithDisk()

        #expect(viewModel.instances.count == 1)
        #expect(viewModel.instances.first?.name == "Paused VM")
    }

    @Test("reconcileWithDisk updates selection when selected stopped VM is removed")
    func reconcileUpdatesSelection() {
        let (viewModel, storage, _, _, _) = makeViewModel()
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

    @Test("reconcileWithDisk presents error when config loading fails")
    func reconcilePresentsErrorForFailedConfigs() {
        let storage = MockVMStorageService()
        let config = VMConfiguration(name: "Good VM", guestOS: .linux, bootMode: .efi)
        let goodURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        storage.bundles[goodURL] = config

        // Create viewModel first (no bad bundles yet)
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        // Introduce the bad bundle after init so it's new to reconcileWithDisk
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        viewModel.showError = false
        viewModel.errorMessage = nil

        viewModel.reconcileWithDisk()

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("broken-vm") == true)
        #expect(viewModel.instances.contains { $0.name == "Good VM" })
    }

    @Test("reconcileWithDisk presents error when listing bundles fails")
    func reconcilePresentsErrorForFilesystemFailure() {
        let (viewModel, storage, _, _, _) = makeViewModel()
        viewModel.showError = false
        viewModel.errorMessage = nil

        storage.listVMBundlesError = VMStorageError.bundleNotFound(
            FileManager.default.temporaryDirectory
        )

        viewModel.reconcileWithDisk()

        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("VM bundle not found") == true)
    }

    @Test("reconcileWithDisk does not re-present error for already-reported corrupted bundles")
    func reconcileDeduplicatesFailedBundleErrors() {
        let storage = MockVMStorageService()
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        // Introduce the bad bundle after init so it's new to reconcileWithDisk
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // First reconciliation should present the error
        viewModel.showError = false
        viewModel.errorMessage = nil
        viewModel.reconcileWithDisk()
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("broken-vm") == true)

        // Second reconciliation should NOT re-present the same error
        viewModel.showError = false
        viewModel.errorMessage = nil
        viewModel.reconcileWithDisk()
        #expect(viewModel.showError == false)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("reconcileWithDisk suppression is maintained after full reload")
    func reconcileSuppressionMaintainedAfterReload() {
        let storage = MockVMStorageService()
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // loadVMs() in init reports the error and seeds reportedFailedBundles
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("broken-vm") == true)

        // First reconcile after init is suppressed
        viewModel.showError = false
        viewModel.errorMessage = nil
        viewModel.reconcileWithDisk()
        #expect(viewModel.showError == false)

        // Full reload resets suppression, then re-seeds from its own failures
        viewModel.loadVMs()
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("broken-vm") == true)

        // Reconciliation should still be suppressed since loadVMs re-seeded the set
        viewModel.showError = false
        viewModel.errorMessage = nil
        viewModel.reconcileWithDisk()
        #expect(viewModel.showError == false)
    }

    @Test("reconcileWithDisk does not re-present errors already reported by loadVMs")
    func reconcileDoesNotDuplicateLoadVMsErrors() {
        let storage = MockVMStorageService()
        let badURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("broken-vm.kernova", isDirectory: true)
        storage.bundles[badURL] = VMConfiguration(name: "Bad VM", guestOS: .linux, bootMode: .efi)
        storage.loadConfigurationFailURLs.insert(badURL)

        // loadVMs() runs in init and should report the error
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("broken-vm") == true)

        // Clear the alert state (simulating user dismissing the dialog)
        viewModel.showError = false
        viewModel.errorMessage = nil

        // First reconcileWithDisk should NOT re-present the same error
        viewModel.reconcileWithDisk()
        #expect(viewModel.showError == false)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("reconcileWithDisk re-presents error after previously-failed bundle loads successfully")
    func reconcileReReportsAfterBundleRecovery() {
        let storage = MockVMStorageService()
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        // Introduce the bad bundle after init so it's new to reconcileWithDisk
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("recoverable.kernova", isDirectory: true)
        let config = VMConfiguration(name: "Recoverable VM", guestOS: .linux, bootMode: .efi)
        storage.bundles[bundleURL] = config
        storage.loadConfigurationFailURLs.insert(bundleURL)

        // First reconciliation reports the error
        viewModel.showError = false
        viewModel.errorMessage = nil
        viewModel.reconcileWithDisk()
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("recoverable") == true)

        // "Fix" the bundle by removing it from the fail set
        storage.loadConfigurationFailURLs.remove(bundleURL)

        // Reconciliation succeeds — no error, and the bundle is cleared from reported set
        viewModel.showError = false
        viewModel.errorMessage = nil
        viewModel.reconcileWithDisk()
        #expect(viewModel.showError == false)

        // Re-corrupt it
        storage.loadConfigurationFailURLs.insert(bundleURL)
        // Remove the instance that was added on successful load so reconciliation tries again
        viewModel.instances.removeAll { $0.name == "Recoverable VM" }

        // Should report the error again since it was cleared from the reported set
        viewModel.reconcileWithDisk()
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("recoverable") == true)
    }

    // MARK: - Cancel Installation

    #if arch(arm64)
    @Test("cancelInstallation removes instance and deletes bundle")
    func cancelInstallationRemovesInstance() {
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, storage, _, _, _) = makeViewModel()
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

    @Test("cancelInstallation surfaces error when trash fails")
    func cancelInstallationSurfacesTrashError() {
        let storage = MockVMStorageService()
        storage.deleteVMBundleError = VMStorageError.bundleNotFound(
            FileManager.default.temporaryDirectory
        )
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        let instance = makeInstance(name: "Installing VM")
        instance.status = .installing
        viewModel.instances.append(instance)

        viewModel.cancelInstallation(instance)

        // Error surfaced to user
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage != nil)
        // Instance still removed from library despite trash failure
        #expect(viewModel.instances.isEmpty)
    }
    #endif

    // MARK: - Rename

    @Test("renameVM sets activeRename to detail target")
    func renameVMSetsDetailTarget() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.renameVM(instance)

        #expect(viewModel.activeRename == .detail(instance.id))
    }

    @Test("renameVMInSidebar sets activeRename to sidebar target")
    func renameVMInSidebarSetsSidebarTarget() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        viewModel.renameVMInSidebar(instance)

        #expect(viewModel.activeRename == .sidebar(instance.id))
    }

    @Test("commitRename updates name and persists")
    func commitRenameUpdatesName() {
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Original")
        viewModel.instances.append(instance)
        viewModel.activeRename = .detail(instance.id)

        viewModel.commitRename(for: instance, newName: "  Trimmed  ")

        #expect(instance.name == "Trimmed")
        #expect(viewModel.activeRename == nil)
    }

    @Test("commitRename rejects empty name and preserves original")
    func commitRenameRejectsEmpty() {
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, virtService, _) = makeViewModel()
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
        let (viewModel, _, _, virtService, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let running = makeInstance(name: "Running")
        running.status = .running
        viewModel.instances = [running]

        await viewModel.pauseAllForSleep()

        // Error is surfaced to the user
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("Running") == true)
        // Failed pause should not track the instance
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake clears tracking set even on failure")
    func resumeAllAfterWakeClearsOnError() async {
        let virtService = MockVirtualizationService()
        virtService.resumeError = VirtualizationError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(virtualizationService: virtService)
        let instance = makeInstance(name: "Sleep Paused")
        instance.status = .paused
        viewModel.instances = [instance]
        viewModel.sleepPausedInstanceIDs = Set([instance.id])

        await viewModel.resumeAllAfterWake()

        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
        // Error is surfaced to the user
        #expect(viewModel.showError == true)
        #expect(viewModel.errorMessage?.contains("Sleep Paused") == true)
    }

    @Test("pauseAllForSleep is no-op when no running VMs")
    func pauseAllForSleepNoOp() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let stopped = makeInstance(name: "Stopped")
        stopped.status = .stopped
        viewModel.instances = [stopped]

        await viewModel.pauseAllForSleep()

        #expect(virtService.pauseCallCount == 0)
        #expect(viewModel.sleepPausedInstanceIDs.isEmpty)
    }

    @Test("resumeAllAfterWake is no-op when no sleep-paused VMs")
    func resumeAllAfterWakeNoOp() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
        let paused = makeInstance(name: "User Paused")
        paused.status = .paused
        viewModel.instances = [paused]
        // sleepPausedInstanceIDs is empty

        await viewModel.resumeAllAfterWake()

        #expect(virtService.resumeCallCount == 0)
    }

    @Test("pauseAllForSleep skips non-running states")
    func pauseAllForSleepSkipsNonRunning() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
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
        let (viewModel, _, _, virtService, _) = makeViewModel()
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
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
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
        let (viewModel, storage, _, _, _) = makeViewModel()
        let instance = makeInstance(name: "Running VM")
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.cloneVM(instance)

        #expect(viewModel.instances.count == 1)
        #expect(storage.cloneVMBundleCallCount == 0)
    }

    @Test("cloneVM shows error when hasPreparing is true")
    func cloneVMShowsErrorWhenPreparing() {
        let (viewModel, _, _, _, _) = makeViewModel()
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
        let (viewModel, storage, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.confirmForceStop(instance)

        #expect(viewModel.instanceToForceStop?.id == instance.id)
        #expect(viewModel.showForceStopConfirmation == true)
    }

    @Test("forceStopConfirmed delegates to lifecycle")
    func forceStopConfirmed() async {
        let (viewModel, _, _, virtService, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        markPreparing(instance)
        viewModel.instances.append(instance)

        #expect(viewModel.hasPreparing == true)
    }

    @Test("hasPreparing returns false when no instances are preparing")
    func hasPreparingFalse() {
        let (viewModel, _, _, _, _) = makeViewModel()
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

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
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
        let (viewModel, _, _, _, _) = makeViewModel()
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
        let (viewModel, _, _, _, _) = makeViewModel()
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
        let config1 = VMConfiguration(
            name: "First", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
        let config2 = VMConfiguration(
            name: "Second", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let config3 = VMConfiguration(
            name: "Third", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 300))
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
        let config1 = VMConfiguration(
            name: "Older", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
        let config2 = VMConfiguration(
            name: "Newer", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        let url2 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config2.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1
        storage.bundles[url2] = config2

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)

        #expect(viewModel.instances.map(\.name) == ["Older", "Newer"])
    }

    @Test("reconcileWithDisk appends new VMs after custom-ordered ones")
    func reconcileAppendsNewVMs() {
        let storage = MockVMStorageService()
        let config1 = VMConfiguration(
            name: "Existing", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 200))
        let url1 = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config1.id.uuidString).kernova", isDirectory: true)
        storage.bundles[url1] = config1

        let (viewModel, _, _, _, _) = makeViewModel(storageService: storage)
        #expect(viewModel.instances.count == 1)

        // Simulate a new VM appearing on disk
        let config2 = VMConfiguration(
            name: "Discovered", guestOS: .linux, bootMode: .efi, createdAt: Date(timeIntervalSince1970: 100))
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
        let (viewModel, storage, _, _, _) = makeViewModel()
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

    // MARK: - Guest Agent Installer

    @Test("mountGuestAgentInstaller appends DMG to removableMedia and shows alert")
    func mountGuestAgentInstallerAppendsAndShowsAlert() async throws {
        let installerURL = try #require(KernovaGuestAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        viewModel.mountGuestAgentInstaller(on: instance)

        // Alert is set synchronously; reconcile attach is async.
        #expect(viewModel.showInstallerMountedAlert == true)
        #expect(viewModel.installerMountedVMName == instance.name)
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(instance.configuration.removableMedia?.first?.path == installerURL.path(percentEncoded: false))

        while instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedReadOnly == true)
    }

    @Test("mountGuestAgentInstaller is a no-op when DMG already in removableMedia, but still surfaces alert")
    func mountGuestAgentInstallerAlreadyMountedSurfacesAlert() throws {
        let installerURL = try #require(KernovaGuestAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.configuration.removableMedia = [
            RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
        ]
        viewModel.instances.append(instance)

        viewModel.mountGuestAgentInstaller(on: instance)

        #expect(mock.attachCallCount == 0)
        #expect(viewModel.showInstallerMountedAlert == true)
        #expect(viewModel.installerMountedVMName == instance.name)
        // List unchanged
        #expect(instance.configuration.removableMedia?.count == 1)
    }

    @Test("unmountGuestAgentInstaller is no-op when DMG not in removableMedia")
    func unmountGuestAgentInstallerNoOpWhenNotPresent() async throws {
        _ = try #require(KernovaGuestAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        // List has an unrelated item only
        let unrelated = RemovableMediaItem(path: "/some/other/disk.img", readOnly: false)
        instance.configuration.removableMedia = [unrelated]
        viewModel.instances.append(instance)

        viewModel.unmountGuestAgentInstaller(from: instance)
        await Task.yield()

        #expect(mock.detachCallCount == 0)
        #expect(instance.configuration.removableMedia?.count == 1)
        #expect(instance.configuration.removableMedia?.first?.path == unrelated.path)
    }

    @Test("unmountGuestAgentInstaller removes DMG entry and triggers detach")
    func unmountGuestAgentInstallerRemovesEntry() async throws {
        let installerURL = try #require(KernovaGuestAgentInfo.installerDiskImageURL)
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let installerItem = RemovableMediaItem(path: installerURL.path(percentEncoded: false), readOnly: true)
        instance.configuration.removableMedia = [installerItem]
        instance.liveRemovableMedia = [
            USBDeviceInfo(id: installerItem.id, path: installerItem.path, readOnly: installerItem.readOnly)
        ]
        viewModel.instances.append(instance)

        viewModel.unmountGuestAgentInstaller(from: instance)

        while !instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(instance.configuration.removableMedia == nil)
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
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let configuredUUID = UUID()
        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso", readOnly: true, id: configuredUUID)

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

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
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = nil

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while !instance.liveRemovableMedia.isEmpty { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("applyLivePolicy swaps the only item: detach old, attach new")
    func liveRemovableSwapDetachesThenAttaches() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let oldID = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        let newID = UUID()
        var new = old
        new.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

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
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: id, path: "/tmp/install.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(id: id, path: "/tmp/install.iso", readOnly: false)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while instance.liveRemovableMedia.first?.readOnly != false { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedReadOnly == false)
    }

    @Test("applyLivePolicy is a no-op when storageDisks change but removableMedia is unchanged")
    func liveRemovableNoopWhenOnlyStorageDisksChange() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let old = instance.configuration
        var new = old
        new.storageDisks = [
            StorageDisk(path: "Disk.asif", readOnly: false, label: "Main Disk", isInternal: true, kind: .virtio)
        ]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
    }

    @Test("applyLivePolicy is a no-op when VM is stopped, even with media change")
    func liveRemovableNoopWhenStopped() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .stopped
        viewModel.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.attachCallCount == 0)
        #expect(mock.detachCallCount == 0)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Live attach failure surfaces error")
    func liveRemovableAttachFailureSurfacesError() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.diskImageNotFound("/tmp/missing.iso")
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/missing.iso")

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while !viewModel.showError { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(viewModel.errorMessage != nil)
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
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let oldID = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        let newID = UUID()
        var new = old
        new.removableMedia = [RemovableMediaItem(id: newID, path: "/tmp/new.iso", readOnly: true)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

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
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let oldID = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)

        while !viewModel.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        // No attach attempted — preventing the device-leak.
        #expect(mock.attachCallCount == 0)
    }

    @Test("Detach noVirtualMachine error bails the reconcile silently")
    func liveRemovableDetachNoVMBails() async throws {
        let mock = MockUSBDeviceService()
        mock.detachError = USBDeviceError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let oldID = UUID()
        instance.liveRemovableMedia = [USBDeviceInfo(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        var old = instance.configuration
        old.removableMedia = [RemovableMediaItem(id: oldID, path: "/tmp/old.iso", readOnly: true)]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = [RemovableMediaItem(path: "/tmp/new.iso", readOnly: true)]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.detachCallCount == 1)
        #expect(mock.attachCallCount == 0)
        #expect(!viewModel.showError)
    }

    @Test("Attach noVirtualMachine error bails the reconcile silently")
    func liveRemovableAttachNoVMBails() async throws {
        let mock = MockUSBDeviceService()
        mock.attachError = USBDeviceError.noVirtualMachine
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let old = instance.configuration
        let new = configWithRemovable(old, path: "/tmp/install.iso")

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.detachCallCount == 0)
        #expect(!viewModel.showError)
        #expect(instance.liveRemovableMedia.isEmpty)
    }

    @Test("Reconcile loop bails out when VM stops mid-pass — no spurious error")
    func liveRemovableReconcileBailsOutOnVMStop() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")

        viewModel.applyLivePolicy(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        // Stop the VM before the suspended attach resolves.
        viewModel.applyLivePolicy(for: instance, old: configA, new: configB)
        instance.status = .stopped

        mock.resumeSuspended()
        for _ in 0..<10 { await Task.yield() }

        #expect(mock.attachCallCount == 1)
        #expect(mock.lastAttachedPath == "/tmp/A.iso")
        #expect(!viewModel.showError)
    }

    @Test("Rapid-fire media swaps coalesce — one Task drains to the latest target")
    func liveRemovableRapidFireCoalescesToLatest() async throws {
        let mock = SuspendingMockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        viewModel.instances.append(instance)

        let baseConfig = instance.configuration
        let configA = configWithRemovable(baseConfig, path: "/tmp/A.iso")
        let configB = configWithRemovable(baseConfig, path: "/tmp/B.iso")
        let configC = configWithRemovable(baseConfig, path: "/tmp/C.iso")

        // Three rapid edits before the first attach can complete.
        viewModel.applyLivePolicy(for: instance, old: baseConfig, new: configA)
        await mock.waitUntilSuspended()
        viewModel.applyLivePolicy(for: instance, old: configA, new: configB)
        viewModel.applyLivePolicy(for: instance, old: configB, new: configC)

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

    // MARK: - Storage Disk Helpers

    @Test("removeStorageDisk with trashFile=false removes the entry without touching the file")
    func removeStorageDiskKeepsFile() {
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let mainDisk = StorageDisk(
            path: "Disk.asif", readOnly: false, label: "Main Disk",
            isInternal: true, kind: .virtio
        )
        let extra = StorageDisk(
            path: "AdditionalDisks/\(UUID().uuidString).asif",
            readOnly: false, label: "Extra", isInternal: true, kind: .virtio
        )
        instance.configuration.storageDisks = [mainDisk, extra]
        viewModel.instances.append(instance)

        viewModel.removeStorageDisk(extra, from: instance, trashFile: false)

        let disks = instance.configuration.storageDisks ?? []
        #expect(disks.count == 1)
        #expect(disks.first?.id == mainDisk.id)
        // No presentError side effect — no file op was attempted.
        #expect(!viewModel.showError)
    }

    @Test("removeStorageDisk on external disk ignores trashFile flag")
    func removeStorageDiskExternalIgnoresTrashFlag() {
        // External disks aren't bundle-owned — the trashFile branch only
        // applies to `isInternal == true`. Passing `true` for an external
        // disk should be a no-op for file handling.
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        let external = StorageDisk(
            path: "/some/host/path/data.img",
            readOnly: false, label: "External", isInternal: false, kind: .virtio
        )
        instance.configuration.storageDisks = [external]
        viewModel.instances.append(instance)

        viewModel.removeStorageDisk(external, from: instance, trashFile: true)

        #expect(instance.configuration.storageDisks == nil)
        // No error from a missing-file trash attempt — the branch was skipped.
        #expect(!viewModel.showError)
    }

    @Test("createStorageDisk appends an internal virtio disk with the expected fields")
    func createStorageDiskAppends() async throws {
        let (viewModel, _, diskService, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        // The viewmodel creates a real directory inside `instance.bundleURL`,
        // so set up a unique scratch bundle and clean it up.
        try FileManager.default.createDirectory(at: instance.bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: instance.bundleURL) }

        viewModel.createStorageDisk(for: instance, sizeInGB: 32)

        // The disk-creation Task is async; spin until the config materializes.
        while instance.configuration.storageDisks == nil { await Task.yield() }

        let disks = instance.configuration.storageDisks ?? []
        // Pre-existing default main disk + the newly-created one.
        #expect(disks.count == 2)

        let newDisk = try #require(disks.last)
        #expect(newDisk.isInternal == true)
        #expect(newDisk.kind == .virtio)
        #expect(newDisk.readOnly == false)
        #expect(newDisk.path.hasPrefix("AdditionalDisks/"))
        #expect(newDisk.path.hasSuffix(".asif"))
        #expect(newDisk.label == "32 GB Disk")

        #expect(diskService.createDiskImageCallCount == 1)
        #expect(diskService.lastCreatedSizeInGB == 32)
        #expect(!viewModel.showError)
    }

    @Test("createRemovableMedia appends an external item with the chosen path and read-write default")
    func createRemovableMediaAppends() async throws {
        let (viewModel, _, diskService, _, _) = makeViewModel()
        let instance = makeInstance()
        viewModel.instances.append(instance)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString) Removable Disk.asif")

        viewModel.createRemovableMedia(for: instance, sizeInGB: 16, destinationURL: destination)

        while instance.configuration.removableMedia == nil { await Task.yield() }

        let media = instance.configuration.removableMedia ?? []
        #expect(media.count == 1)

        let item = try #require(media.first)
        // Removable media is always external — no `isInternal` flag exists on the
        // model. The stored path is the absolute host path the user picked.
        #expect(item.path == destination.path(percentEncoded: false))
        #expect(item.readOnly == false)
        #expect(item.label == destination.deletingPathExtension().lastPathComponent)

        #expect(diskService.createDiskImageCallCount == 1)
        #expect(diskService.lastCreatedSizeInGB == 16)
        #expect(!viewModel.showError)
    }

    @Test("createRemovableMedia surfaces errors and leaves the list unchanged")
    func createRemovableMediaErrorIsSurfaced() async throws {
        let diskService = MockDiskImageService()
        diskService.createDiskImageError = NSError(domain: "test", code: 1)
        let (viewModel, _, _, _, _) = makeViewModel(diskImageService: diskService)
        let instance = makeInstance()
        viewModel.instances.append(instance)

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).asif")

        viewModel.createRemovableMedia(for: instance, sizeInGB: 16, destinationURL: destination)

        while !viewModel.showError { await Task.yield() }

        #expect(instance.configuration.removableMedia == nil)
        #expect(diskService.createDiskImageCallCount == 1)
    }

    // MARK: - Reconcile Rollback

    @Test("Reorder-only removableMedia change triggers no detach/attach")
    func liveRemovableReorderIsNoOp() async throws {
        let mock = MockUSBDeviceService()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let idA = UUID()
        let idB = UUID()
        instance.liveRemovableMedia = [
            USBDeviceInfo(id: idA, path: "/tmp/a.iso", readOnly: true),
            USBDeviceInfo(id: idB, path: "/tmp/b.iso", readOnly: true),
        ]
        var old = instance.configuration
        old.removableMedia = [
            RemovableMediaItem(id: idA, path: "/tmp/a.iso", readOnly: true),
            RemovableMediaItem(id: idB, path: "/tmp/b.iso", readOnly: true),
        ]
        instance.configuration = old
        viewModel.instances.append(instance)

        var new = old
        new.removableMedia = [
            // Swapped order; identical items.
            RemovableMediaItem(id: idB, path: "/tmp/b.iso", readOnly: true),
            RemovableMediaItem(id: idA, path: "/tmp/a.iso", readOnly: true),
        ]

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        // Drain whatever the reconcile Task may have scheduled.
        for _ in 0..<20 { await Task.yield() }

        #expect(mock.detachCallCount == 0)
        #expect(mock.attachCallCount == 0)
        #expect(instance.liveRemovableMedia.count == 2)
        #expect(!viewModel.showError)
    }

    @Test("Failed detach rolls config back to live state (item stays attached)")
    func liveRemovableRollbackOnDetachFailure() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = [
            USBDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        var old = instance.configuration
        old.removableMedia = [
            RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        instance.configuration = old
        viewModel.instances.append(instance)

        // Simulate `updateConfiguration` having already persisted the
        // user's removal intent — config says "no media", live still has it.
        var new = old
        new.removableMedia = nil
        instance.configuration = new

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        while !viewModel.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        // Detach failed → device still mounted → config must reflect that.
        let rolled = try #require(instance.configuration.removableMedia)
        #expect(rolled.count == 1)
        #expect(rolled.first?.id == id)
        #expect(rolled.first?.path == "/tmp/old.iso")
        #expect(rolled.first?.readOnly == true)
    }

    @Test("Failed attach rolls config back to live state (entry strips from config)")
    func liveRemovableRollbackOnAttachFailure() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.attachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = []
        var old = instance.configuration
        old.removableMedia = nil
        instance.configuration = old
        viewModel.instances.append(instance)

        // The user added a removable item; updateConfiguration already
        // persisted it before applyLivePolicy fired.
        var new = old
        new.removableMedia = [
            RemovableMediaItem(id: id, path: "/tmp/missing.iso", readOnly: true)
        ]
        instance.configuration = new

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        while !viewModel.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        // Attach failed → device never mounted → config rolled back to nil.
        #expect(instance.configuration.removableMedia == nil)
    }

    @Test("Failed swap rollback restores the original entry, not the target")
    func liveRemovableRollbackOnSwapFailureRestoresOriginal() async throws {
        struct TransientError: Error {}
        let mock = MockUSBDeviceService()
        mock.detachError = TransientError()
        let (viewModel, _, _, _, _) = makeViewModel(usbDeviceService: mock)
        let instance = makeInstance()
        instance.status = .running
        let id = UUID()
        instance.liveRemovableMedia = [
            USBDeviceInfo(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        var old = instance.configuration
        old.removableMedia = [
            RemovableMediaItem(id: id, path: "/tmp/old.iso", readOnly: true)
        ]
        instance.configuration = old
        viewModel.instances.append(instance)

        // Same id, different path (path swap) — and `updateConfiguration`
        // has already persisted the target.
        var new = old
        new.removableMedia = [
            RemovableMediaItem(id: id, path: "/tmp/new.iso", readOnly: true)
        ]
        instance.configuration = new

        viewModel.applyLivePolicy(for: instance, old: old, new: new)
        while !viewModel.showError { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        let rolled = try #require(instance.configuration.removableMedia)
        #expect(rolled.count == 1)
        #expect(rolled.first?.id == id)
        // Critical: path is the ORIGINAL one, not the failed-swap target.
        #expect(rolled.first?.path == "/tmp/old.iso")
    }

    @Test("removeStorageDisk on synthetic main disk leaves storageDisks empty")
    func removeSyntheticMainDiskClearsList() {
        // Regression test: with a non-deterministic synthesized UUID, the
        // remove path would no-op the entry removal (UUID mismatch between
        // binding and removeStorageDisk's own re-synthesis) while still
        // trashing `Disk.asif` — bricking the VM.
        let (viewModel, _, _, _, _) = makeViewModel()
        let instance = makeInstance()
        instance.configuration.storageDisks = nil
        viewModel.instances.append(instance)

        let layout = VMBundleLayout(bundleURL: instance.bundleURL)
        let synthetic = ConfigurationBuilder.defaultMainDisk(layout: layout)

        viewModel.removeStorageDisk(synthetic, from: instance, trashFile: false)

        // Either nil (the empty-collapses-to-nil persistence) or empty.
        let surviving = instance.configuration.storageDisks ?? []
        #expect(surviving.isEmpty)
    }
}
