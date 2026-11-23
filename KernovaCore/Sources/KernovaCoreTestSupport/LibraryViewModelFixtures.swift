import Foundation

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
    usbAccessoryPassthrough: USBAccessoryPassthrough = .unavailable(.needsEntitlement),
    diskImageService: MockDiskImageService = MockDiskImageService(),
    virtualizationService: MockVirtualizationService = MockVirtualizationService(),
    organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil),
    bundleProducts: AppBundleProducts = .testing
) -> VMLibraryViewModel {
    VMLibraryViewModel(
        storageService: storageService,
        diskImageService: diskImageService,
        machineFiles: VMBundleMachineFiles(fileSystem: fileSystem, platform: FakePlatformFiles()),
        virtualizationHost: FakeVirtualizationHost(),
        virtualizationService: virtualizationService,
        installService: MockMacOSInstallService(),
        ipswService: MockIPSWService(),
        localImageInspector: MockLocalRestoreImageInspector(),
        removableMediaDeviceService: MockRemovableMediaDeviceService(),
        bridgedInterfaces: MockBridgedInterfaceProvider(),
        usbAccessoryPassthrough: usbAccessoryPassthrough,
        fileSystem: fileSystem,
        downloadsDirectory: makeTestDownloadsDirectory(),
        preferences: preferences,
        vmnetNetworks: VmnetNetworkService.scripted(),
        arpTable: ScriptedARPTable(),
        entitlements: .entitled,
        organization: organization,
        hostNotifications: .isolated(),
        hostPasteboard: FakePasteboard(),
        bundleProducts: bundleProducts
    )
}
