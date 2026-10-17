import Foundation
import KernovaKit

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

/// A real ``VMCommandCore`` over a wired library and mock services, with the
/// adapter hooks that put things in front of the user recorded rather than
/// presented — what a front door's tests drive in place of the AppKit adapter.
///
/// A test overriding one of those hooks replaces its recording.
@MainActor
final class WiredCommandCore {
    let core: VMCommandCore
    let library: VMLibrary
    let lifecycle: VMLifecycleCoordinator
    let storage: MockVMStorageService
    let machineFiles: MockVMBundleMachineFiles
    let fileSystem: MockFileSystem
    let vmnet: ScriptedVmnetNetworks
    let arpTable: ScriptedARPTable
    let authority: MockSandboxSourceAuthority
    let preferences: AppPreferences
    /// The library's password store, read by identifier — the one way to ask
    /// about an arrival that never became a VM.
    let passwords: InMemoryGuestAccountPasswordStore

    let diskImages: MockDiskImageService
    let removableMedia: MockRemovableMediaDeviceService
    /// The accessory service the harness was given, if any.
    let usbAccessories: MockUSBAccessoryService?

    /// Present when the harness was given an accessory service: the core
    /// reports user attaches and detaches to it, and it is held here because
    /// the core reaches it weakly. Nothing wires
    /// `library.onSessionBecameAttachable`, so a session coming up takes no
    /// paired accessory back.
    let pairingCoordinator: USBAccessoryCoordinator?

    /// Each VM ``VMCommandCore/surfaceDisplay`` put in front of the user.
    private(set) var surfacedDisplays: [UUID] = []
    /// Each row ``VMCommandCore/revealInLibrary`` put in front of the user.
    private(set) var revealedInLibrary: [UUID] = []
    /// Each VM ``VMCommandCore/revealInFinder`` selected in the Finder.
    private(set) var revealedInFinder: [UUID] = []
    /// How many times ``VMCommandCore/requestQuit`` fired.
    private(set) var quitRequests = 0
    /// Fires each time ``quitRequests`` rises: the core requests the quit from
    /// a later main-actor turn, so a test awaits it.
    let quitRequested = AsyncGate()
    /// Each failure ``VMCommandCore/onFailure`` received.
    private(set) var failures: [CommandError] = []
    /// Fires each time ``failures`` grows: an unattended failure is reported
    /// from the task that ran it, so a test awaits it.
    let failureReported = AsyncGate()

    init(
        virtualization: any VirtualizationProviding = MockVirtualizationService(),
        installService: any MacOSInstallProviding = MockMacOSInstallService(),
        diskImages: MockDiskImageService = MockDiskImageService(),
        usbAccessoryService: MockUSBAccessoryService? = nil,
        removableMedia: MockRemovableMediaDeviceService = MockRemovableMediaDeviceService(),
        storage: MockVMStorageService = MockVMStorageService(),
        fileSystem: MockFileSystem = MockFileSystem(),
        entitlements: EntitlementService = .entitled,
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil),
        preferences: AppPreferences = makeTestPreferences(),
        virtualizationHost: any VirtualizationHostProviding = FakeVirtualizationHost(),
        clock: any EngineClock = makePlatformEngineClock()
    ) {
        let machineFiles = MockVMBundleMachineFiles(files: storage.files, fileSystem: fileSystem)
        let vmnet = ScriptedVmnetNetworks()
        let arpTable = ScriptedARPTable()
        let passwords = InMemoryGuestAccountPasswordStore()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization,
            installService: installService,
            removableMedia: removableMedia,
            usbAccessoryService: usbAccessoryService,
            fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage,
            machineFiles: machineFiles,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: vmnet.service,
            arpTable: arpTable,
            entitlements: entitlements,
            networks: networks,
            organization: organization,
            guestAccountPasswords: passwords,
            virtualizationHost: virtualizationHost)
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            diskImageService: diskImages,
            fileSystem: fileSystem,
            preferences: preferences,
            clock: clock)
        let authority = MockSandboxSourceAuthority()
        core.sourceAuthority = authority

        self.core = core
        self.library = library
        self.lifecycle = lifecycle
        self.storage = storage
        self.machineFiles = machineFiles
        self.fileSystem = fileSystem
        self.vmnet = vmnet
        self.arpTable = arpTable
        self.authority = authority
        self.preferences = preferences
        self.passwords = passwords
        self.usbAccessories = usbAccessoryService
        self.diskImages = diskImages
        self.removableMedia = removableMedia

        let pairingCoordinator = USBAccessoryCoordinator(lifecycle: lifecycle, library: library)
        core.usbAccessoryPairings = pairingCoordinator
        self.pairingCoordinator = pairingCoordinator

        core.surfaceDisplay = { [weak self] in self?.surfacedDisplays.append($0.id) }
        core.revealInLibrary = { [weak self] in self?.revealedInLibrary.append($0) }
        core.revealInFinder = { [weak self] in self?.revealedInFinder.append($0.id) }
        core.requestQuit = { [weak self] in
            self?.quitRequests += 1
            self?.quitRequested.notify()
        }
        core.onFailure = { [weak self] failure, _ in
            self?.failures.append(failure)
            self?.failureReported.notify()
        }
    }

    /// Registers a fixture VM in the library, wired as a load would have left
    /// it — ``RegisteredVMInstanceFixture/register(name:phase:guestOS:snapshots:library:preferences:hostState:mutate:)``'s
    /// defaults, networking off unless `mutate` turns it back on.
    @discardableResult
    func register(
        name: String = "Wired", phase: VMLifecyclePhase = .stopped, guestOS: VMGuestOS = .linux,
        snapshots: [VMSnapshot] = [], hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots, library: library,
            preferences: preferences, hostState: hostState, mutate: mutate)
    }
}

extension WiredCommandCore {
    /// A wired core with the virtualization service it runs on kept at its own
    /// type, for a test that scripts that service; every other member reads
    /// through to the harness.
    @MainActor
    @dynamicMemberLookup
    struct Scripted<Virtualization: VirtualizationProviding> {
        let wired: WiredCommandCore
        let virtualization: Virtualization

        /// `wired`, with the service its lifecycle runs on read back at
        /// `Virtualization`; a harness built over another service is a
        /// mistake in the test.
        init(_ wired: WiredCommandCore) {
            guard let virtualization = wired.lifecycle.virtualizationService as? Virtualization else {
                preconditionFailure("The harness runs on \(type(of: wired.lifecycle.virtualizationService))")
            }
            self.wired = wired
            self.virtualization = virtualization
        }

        subscript<Value>(dynamicMember keyPath: KeyPath<WiredCommandCore, Value>) -> Value {
            wired[keyPath: keyPath]
        }
    }
}
