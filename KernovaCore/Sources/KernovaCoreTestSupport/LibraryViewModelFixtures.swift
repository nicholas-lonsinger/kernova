import Foundation
import KernovaKit

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

/// A ``VMLibraryViewModel`` over mocks and the fake engine, for a suite that
/// needs a whole one to build over.
@MainActor
func makeLibraryViewModel(
    preferences: AppPreferences,
    storageService: MockVMStorageService = MockVMStorageService(),
    fileSystem: MockFileSystem = MockFileSystem(),
    usbAccessoryService: (any USBAccessoryProviding)? = nil,
    diskImageService: MockDiskImageService = MockDiskImageService(),
    organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil),
    guestAgent: BundledGuestAgent = .testing
) -> VMLibraryViewModel {
    VMLibraryViewModel(
        storageService: storageService,
        diskImageService: diskImageService,
        machineFiles: VMBundleMachineFiles(fileSystem: fileSystem, platform: FakePlatformFiles()),
        virtualizationHost: FakeVirtualizationHost(),
        virtualizationService: MockVirtualizationService(),
        installService: MockMacOSInstallService(),
        ipswService: MockIPSWService(),
        localImageInspector: MockLocalRestoreImageInspector(),
        removableMediaDeviceService: MockRemovableMediaDeviceService(),
        bridgedInterfaces: MockBridgedInterfaceProvider(),
        usbAccessoryService: usbAccessoryService,
        fileSystem: fileSystem,
        downloadsDirectory: nil,
        preferences: preferences,
        vmnetNetworks: VmnetNetworkService.scripted(),
        arpTable: ScriptedARPTable(),
        entitlements: .entitled,
        organization: organization,
        hostNotifications: .isolated(),
        hostPasteboard: FakePasteboard(),
        guestAgent: guestAgent
    )
}

/// A VM in `viewModel`'s library, selected in its sidebar — the VM the library
/// window shows while it is the working window.
@MainActor
@discardableResult
func makeMenuInstance(
    in viewModel: VMLibraryViewModel,
    guestOS: VMGuestOS = .macOS, name: String = "Menu VM",
    phase: VMLifecyclePhase = .stopped, mutate: (inout VMConfiguration) -> Void = { _ in }
) -> VMInstance {
    let instance = viewModel.library.admitFixture(
        name: name, guestOS: guestOS, phase: phase, mutate: mutate)
    viewModel.library.selection = .library(instance.id)
    return instance
}
