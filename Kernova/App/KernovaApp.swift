import Cocoa
import KernovaCore
import KernovaKit
import KernovaLogging
import KernovaVirtualization

/// The app's entry point and composition root: the one place that claims this
/// copy of Kernova, reads `Bundle.main`, and builds the production services
/// `AppDelegate` is handed.
@main
@MainActor
enum KernovaApp {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "KernovaApp")

    /// Makes an ObjC exception raised on the main thread take the test host
    /// down with a crash report, instead of AppKit reporting it and swallowing
    /// it — which leaves the process alive with its main dispatch queue never
    /// drained again, so every `@MainActor` test after it hangs silently.
    private static func crashOnObjCExceptions() {
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
    }

    static func main() {
        let isTestHost = ProcessInfo.processInfo.isRunningXCTests
        if isTestHost {
            crashOnObjCExceptions()
        }
        let products: AppBundleProducts? = isTestHost ? nil : AppBundleProducts(bundle: .main)
        // Ahead of `NSApplication.shared`, so a second process of a running
        // copy exits before it connects to the window server.
        let copyClaim = products.map { claimThisCopy(at: $0.bundleURL) }
        let app = NSApplication.shared

        // `NSApplication.delegate` is weak, so the local binding retains the
        // delegate for the process lifetime (`run()` never returns).
        let delegate: any NSApplicationDelegate
        if let products, let copyClaim {
            let presence = SystemAppPresence()
            delegate = AppDelegate(
                viewModel: makeLibrary(products: products), copyClaim: copyClaim, presence: presence)
        } else {
            // Before `run()`, so the test host has no Dock or ⌘-Tab presence
            // while the tests run.
            SystemAppPresence().setActivationPolicy(.accessory)
            delegate = TestHostDelegate()
        }
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
            #log(
                logger, .notice,
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
                vmnetNetworks: vmnetNetworks, vmnetAttachments: vmnetOperator,
                bridgedInterfaces: bridgedInterfaces, entitlements: entitlements, guestAgent: guestAgent,
                isProtectedDataAvailable: { NSApplication.shared.isProtectedDataAvailable }),
            installService: MacOSInstallService(
                vmnetNetworks: vmnetNetworks, vmnetAttachments: vmnetOperator,
                bridgedInterfaces: bridgedInterfaces, entitlements: entitlements, guestAgent: guestAgent),
            ipswService: IPSWService(),
            localImageInspector: LocalRestoreImageInspector(),
            removableMediaDeviceService: RemovableMediaDeviceService(),
            bridgedInterfaces: bridgedInterfaces,
            usbAccessoryService: USBAccessorySupport.makeService(entitlements: entitlements),
            systemSleep: SystemSleepWatcher(
                systemWillSleep: hostNotifications.systemWillSleep,
                systemDidWake: hostNotifications.systemDidWake),
            fileSystem: FileManager.default,
            downloadsDirectory: FileManager.default.urls(
                for: .downloadsDirectory, in: .userDomainMask
            ).first,
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

// MARK: - Test Host

/// The unit-test host's delegate: this bundle's `NSApplication`, with none of
/// the app behind it.
///
/// XCTest owns the process — it starts the tests once the app finishes
/// launching and ends the process when they finish — and every window, view
/// model and service a test needs, the test builds itself. So a test run claims
/// nothing the copy of Kernova the developer is running holds: no copy claim,
/// library read, staging reclaim, USB accessory, command socket, status item or
/// Spotlight entry.
@MainActor
private final class TestHostDelegate: NSObject, NSApplicationDelegate {
    /// Takes Launch Services' request for the app's default surface without
    /// opening anything.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    /// Never: a test that closes the last window it made leaves the host up for
    /// the tests after it.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `Kernova.sdef` ships in this bundle, so the process is scriptable however
    /// it was launched, and Cocoa resolves the application's elements through
    /// whichever delegate is installed. A key no delegate claims
    /// reaches `NSApplication`'s own KVC and raises `NSUnknownKeyException`.
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        AppDelegate.scriptingKeys.contains(key)
    }

    /// No VM: the test host reads no library.
    @objc var virtualMachines: [VMScriptObject] { [] }

    /// No network, for the same reason.
    @objc var networks: [VMNetworkScriptObject] { [] }
}
