import Cocoa
import KernovaCore
import KernovaKit
import KernovaLogging
import KernovaUI
import KernovaVirtualization

/// The app's entry point and composition root: the one place that claims this
/// copy of Kernova, reads `Bundle.main`, and builds the production services
/// `AppDelegate` is handed.
@main
@MainActor
enum KernovaApp {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "KernovaApp")

    static func main() {
        let products = AppBundleProducts(bundle: .main)
        // Ahead of `NSApplication.shared`, so a second process of a running
        // copy exits before it connects to the window server.
        let copyClaim = claimThisCopy(at: products.bundleURL)
        let app = NSApplication.shared
        let presence = SystemAppPresence()

        // `NSApplication.delegate` is weak, so the local binding retains the
        // delegate for the process lifetime (`run()` never returns).
        let delegate = AppDelegate(
            viewModel: makeLibrary(products: products), copyClaim: copyClaim, presence: presence)
        app.delegate = delegate
        app.run()
    }

    /// Claims the copy of Kernova at `appBundle` for this process, and exits
    /// when another process of the copy already holds the claim: that process
    /// is the copy, and this one is a second launch of it.
    private static func claimThisCopy(at appBundle: URL) -> Result<AppCopyClaim, AppCopyClaim.Unavailable> {
        switch AppCopyClaim.acquire(forAppBundle: appBundle) {
        case .claimed(let claim):
            return .success(claim)
        case .unavailable(let reason):
            return .failure(reason)
        case .alreadyHeld:
            logger.log(
                .notice,
                "Another process of this copy of Kernova is already running; this launch exits")
            exit(0)
        }
    }

    /// The library over the production services: the Virtualization engine,
    /// the user's library, network and organization stores, the signature's
    /// entitlements, the host's notifications and pasteboard, and `products`.
    private static func makeLibrary(products: AppBundleProducts) -> VMLibraryViewModel {
        let entitlements = EntitlementService.readFromProcess()
        let vmnetOperator = HostVmnetNetworkOperator()
        let vmnetNetworks = VmnetNetworkService(operations: vmnetOperator)
        let bridgedInterfaces = HostBridgedInterfaceProvider()
        let hostNotifications = HostNotifications.appKit()
        let guestAgent = products.guestAgent
        return VMLibraryViewModel(
            storageService: VMStorageService(libraryDirectory: VMStorageService.productionLibraryDirectory),
            diskImageService: DiskImageService(products: products),
            machineFiles: VMBundleMachineFiles(
                fileSystem: FileManager.default, platform: VirtualizationPlatformFiles()),
            virtualizationHost: VirtualizationHost(),
            virtualizationService: VirtualizationService(
                vmnetNetworks: vmnetNetworks, vmnetAttachments: .host,
                bridgedInterfaces: bridgedInterfaces, entitlements: entitlements, guestAgent: guestAgent,
                isProtectedDataAvailable: { NSApplication.shared.isProtectedDataAvailable }),
            installService: MacOSInstallService(
                vmnetNetworks: vmnetNetworks, vmnetAttachments: .host,
                bridgedInterfaces: bridgedInterfaces, entitlements: entitlements, guestAgent: guestAgent),
            ipswService: IPSWService(),
            localImageInspector: LocalRestoreImageInspector(),
            removableMediaDeviceService: RemovableMediaDeviceService(),
            bridgedInterfaces: bridgedInterfaces,
            usbAccessoryPassthrough: USBAccessorySupport.passthrough(entitlements: entitlements),
            systemSleep: SystemSleepWatcher(
                systemWillSleep: hostNotifications.systemWillSleep,
                systemDidWake: hostNotifications.systemDidWake),
            fileSystem: FileManager.default,
            downloadsDirectory: UserDownloads.url,
            preferences: .shared,
            vmnetNetworks: vmnetNetworks,
            arpTable: HostARPTableReader(),
            entitlements: entitlements,
            networks: VMNetworkDirectory(fileURL: VMNetworkDirectory.productionFileURL),
            organization: VMOrganizationDirectory(fileURL: VMOrganizationDirectory.productionFileURL),
            hostNotifications: hostNotifications,
            hostPasteboard: NSPasteboard.general,
            bundleProducts: products)
    }
}
