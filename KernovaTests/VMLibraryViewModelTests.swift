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
}
