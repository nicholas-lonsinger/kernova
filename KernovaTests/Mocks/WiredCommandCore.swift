import Foundation
import KernovaKit

@testable import Kernova

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
    let vmnet: MockVmnetNetworkProvider
    let arpTable: ScriptedARPTable
    let authority: MockSandboxSourceAuthority
    let preferences: AppPreferences

    /// Present when the harness was given an accessory service: the core's
    /// three accessory hooks report user attaches and detaches to it, and it
    /// is held here because they reach it weakly. Nothing wires
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

    init(
        virtualization: any VirtualizationProviding = MockVirtualizationService(),
        installService: any MacOSInstallProviding = MockMacOSInstallService(),
        diskImages: any DiskImageProviding = MockDiskImageService(),
        usbAccessoryService: MockUSBAccessoryService? = nil,
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil),
        preferences: AppPreferences = makeTestPreferences(),
        clock: any EngineClock = makePlatformEngineClock()
    ) {
        let storage = MockVMStorageService()
        let machineFiles = MockVMBundleMachineFiles(files: storage.files)
        let fileSystem = MockFileSystem()
        let vmnet = MockVmnetNetworkProvider()
        let arpTable = ScriptedARPTable()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization,
            installService: installService,
            usbAccessoryService: usbAccessoryService,
            fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage,
            machineFiles: machineFiles,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: vmnet,
            arpTable: arpTable,
            networks: networks,
            organization: organization)
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

        if usbAccessoryService != nil {
            let pairingCoordinator = USBAccessoryCoordinator(
                lifecycle: lifecycle, roster: library, holders: library.accessoryHolders,
                pairings: library)
            core.onUserAttachedAccessory = { [weak pairingCoordinator] permit, accessory in
                try pairingCoordinator?.userAttached(accessory, permit)
            }
            core.onUserDetachingAccessory = { [weak pairingCoordinator] _, accessory in
                pairingCoordinator?.userDetaching(accessory)
            }
            core.onUserReleasedAccessory = { [weak pairingCoordinator] permit, accessory in
                try pairingCoordinator?.userReleased(accessory, permit)
            }
            self.pairingCoordinator = pairingCoordinator
        } else {
            self.pairingCoordinator = nil
        }

        core.surfaceDisplay = { [weak self] in self?.surfacedDisplays.append($0.id) }
        core.revealInLibrary = { [weak self] in self?.revealedInLibrary.append($0) }
        core.revealInFinder = { [weak self] in self?.revealedInFinder.append($0.id) }
        core.requestQuit = { [weak self] in
            self?.quitRequests += 1
            self?.quitRequested.notify()
        }
        core.onFailure = { [weak self] failure, _ in self?.failures.append(failure) }
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
