import Testing
import Foundation
@testable import Kernova

@Suite("VMLibraryViewModel Tests")
@MainActor
struct VMLibraryViewModelTests {

    private func makeViewModel(
        storageService: MockVMStorageService = MockVMStorageService(),
        diskImageService: MockDiskImageService = MockDiskImageService(),
        virtualizationService: MockVirtualizationService = MockVirtualizationService()
    ) -> (VMLibraryViewModel, MockVMStorageService, MockDiskImageService, MockVirtualizationService) {
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
}
