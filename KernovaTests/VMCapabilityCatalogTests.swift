import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The one place per-VM command capability is derived: what each state admits,
/// what a transient blocker takes away, and the one capability whose commit is
/// deliberately wider than its offer.
@Suite("VMCapabilityCatalog Tests", .serialized, .admissionGated)
@MainActor
struct VMCapabilityCatalogTests {
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.capabilities")

    private struct Harness {
        let catalog: VMCapabilityCatalog
        let library: VMLibrary
        let lifecycle: VMLifecycleCoordinator
        let storage: MockVMStorageService
    }

    private func makeHarness(
        virtualization: any VirtualizationProviding = MockVirtualizationService()
    ) -> Harness {
        let storage = MockVMStorageService()
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualization,
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            usbDeviceService: MockUSBDeviceService(),
            linuxImageResolveService: MockLinuxImageResolveService(),
            downloadService: MockDownloadService(),
            fileSystem: MockFileSystem()
        )
        let library = VMLibrary(
            storageService: storage,
            snapshotStore: MockVMSnapshotStore(),
            lifecycle: lifecycle,
            fileSystem: MockFileSystem(),
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(),
            isVMNetworkingEntitled: true
        )
        return Harness(
            catalog: VMCapabilityCatalog(library: library), library: library, lifecycle: lifecycle,
            storage: storage)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Catalog VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux
    ) -> VMInstance {
        var config = VMConfiguration(
            name: name, guestOS: guestOS, bootMode: guestOS == .macOS ? .macOS : .efi)
        config.networkEnabled = false
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(config.id.uuidString).kernova", isDirectory: true)
        let instance = VMInstance(
            configuration: config, bundleURL: bundleURL, phase: phase, preferences: preferences)
        harness.storage.bundles[bundleURL] = config
        harness.library.instances.append(instance)
        return instance
    }

    /// Every phase, each with the session identity its own case admits.
    private static var everyPhase: [VMLifecyclePhase] {
        let id = UUID()
        return [
            .stopped, .initialBoot, .failed(message: "Boot failed."), .suspended,
            .capturingAtRest, .revertingToSnapshot,
            .starting(sessionID: nil), .installing(sessionID: nil),
            .restoringSavedState(sessionID: nil),
            .starting(sessionID: id), .installing(sessionID: id), .running(sessionID: id),
            .livePaused(sessionID: id), .saving(sessionID: id), .capturingLive(sessionID: id),
            .restoringSavedState(sessionID: id),
        ]
    }

    /// Applicable in every state, so each case below names only what its state
    /// adds.
    private static let universal: Set<VMCapability> = [
        .info, .ipAddress, .snapshots, .showInFinder, .deleteSnapshot, .renameSnapshot,
        .setSnapshotNotes,
    ]

    // MARK: - Applicability by state

    @Test("Each phase admits exactly the capabilities its own predicates allow")
    func applicabilityByPhase() {
        let id = UUID()
        let display: Set<VMCapability> = [.open, .toggleSettingsPane]
        let cases: [(label: String, phase: VMLifecyclePhase, added: Set<VMCapability>)] = [
            ("stopped", .stopped, [.start, .takeSnapshot, .clone, .rename, .delete]),
            (
                "running", .running(sessionID: id),
                [
                    .stop, .restart, .forceStop, .pause, .suspend, .open, .takeSnapshot,
                    .rename, .togglePopOut, .toggleFullscreen, .toggleSettingsPane,
                ]
            ),
            (
                "live-paused", .livePaused(sessionID: id),
                [
                    .stop, .restart, .forceStop, .resume, .suspend, .open, .takeSnapshot,
                    .rename, .togglePopOut, .toggleFullscreen, .toggleSettingsPane,
                ]
            ),
            // No save file on disk, so a suspended VM has no suspend slot to
            // capture.
            (
                "suspended", .suspended,
                [.discardSavedState, .resume, .open, .rename, .delete, .toggleSettingsPane]
            ),
            ("starting, no VM yet", .starting(sessionID: nil), []),
            ("starting", .starting(sessionID: id), [.forceStop]),
            ("saving", .saving(sessionID: id), display.union([.forceStop])),
            ("capturing live", .capturingLive(sessionID: id), display.union([.forceStop])),
            ("capturing at rest", .capturingAtRest, display),
            (
                "restoring a saved state", .restoringSavedState(sessionID: id),
                display.union([.forceStop])
            ),
            ("restoring, no VM yet", .restoringSavedState(sessionID: nil), display),
            ("reverting to a snapshot", .revertingToSnapshot, display),
            ("installing", .installing(sessionID: id), []),
            ("installing, no VM yet", .installing(sessionID: nil), []),
            ("failed", .failed(message: "Boot failed."), [.start, .clone, .rename, .delete]),
            ("initialBoot", .initialBoot, [.start, .clone, .rename, .delete]),
        ]

        for testCase in cases {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: testCase.phase)
            let applicable = Set(
                VMCapability.allCases.filter { harness.catalog.isApplicable($0, to: instance) })

            #expect(applicable == Self.universal.union(testCase.added), "\(testCase.label)")
        }
    }

    @Test("Nothing is available that is not applicable")
    func availabilityImpliesApplicability() {
        for phase in Self.everyPhase {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)
            for capability in VMCapability.allCases
            where harness.catalog.isAvailable(capability, on: instance) {
                #expect(
                    harness.catalog.isApplicable(capability, to: instance),
                    "\(capability) on \(phase)")
            }
        }
    }

    // MARK: - Preparing

    @Test("A bundle still being copied offers only its reads, its cancel, and Show in Finder")
    func preparingLeavesOnlyTheReadsAndItsCancel() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)

        let available = Set(
            VMCapability.allCases.filter { harness.catalog.isAvailable($0, on: instance) })

        #expect(
            available == [.info, .ipAddress, .snapshots, .cancelPreparing, .showInFinder])
    }

    @Test("Clone stays available while a different VM is being copied")
    func cloneIgnoresAnotherVMsCopy() {
        let harness = makeHarness()
        let settled = makeInstance(in: harness, name: "Settled")
        let copying = makeInstance(in: harness, name: "Copying")
        let task = Task {}
        defer { task.cancel() }
        copying.preparingState = VMInstance.PreparingState(operation: .cloning, task: task)

        // Bundle destinations are reserved atomically and overlapping copies are
        // a supported case, so one VM's copy says nothing about another's.
        #expect(harness.library.hasPreparing)
        #expect(harness.catalog.isAvailable(.clone, on: settled))
        #expect(!harness.catalog.isAvailable(.clone, on: copying))
    }

    // MARK: - Settling

    @Test("Take Snapshot stays applicable but goes unavailable while an operation settles")
    func takeSnapshotWaitsForTheOperationToSettle() async throws {
        let suspending = SuspendingMockVirtualizationService()
        suspending.shouldSuspendOnResume = true
        let harness = makeHarness(virtualization: suspending)
        let instance = makeInstance(in: harness, phase: .livePaused(sessionID: UUID()))

        #expect(harness.catalog.isAvailable(.takeSnapshot, on: instance))

        let resume = Task { @MainActor in try await harness.lifecycle.resume(instance) }
        await suspending.waitUntilSuspended()

        #expect(harness.catalog.isApplicable(.takeSnapshot, to: instance))
        #expect(!harness.catalog.isAvailable(.takeSnapshot, on: instance))
        #expect(!harness.catalog.isAvailable(.revertToSnapshot, on: instance))
        #expect(!harness.catalog.isAvailable(.deleteSnapshot, on: instance))
        // The lifecycle verbs carry no settle term — a stop has to be able to
        // interrupt an operation that is still running.
        #expect(harness.catalog.isAvailable(.stop, on: instance))
        // Nor do a snapshot's name and note: `VMCommandCore` writes both while
        // the VM is busy, so refusing them here would make `accepts` disagree
        // with the verb whose guard it is meant to be.
        #expect(harness.catalog.accepts(.renameSnapshot, on: instance))
        #expect(harness.catalog.accepts(.setSnapshotNotes, on: instance))

        suspending.resumeSuspended()
        try await resume.value
    }

    // MARK: - Rename: offer versus accept

    @Test("A rename typed while the VM began a transient is offered no longer but still taken")
    func renameAcceptsWiderThanItOffers() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .saving(sessionID: UUID()))

        #expect(!harness.catalog.isApplicable(.rename, to: instance))
        #expect(!harness.catalog.isAvailable(.rename, on: instance))
        #expect(harness.catalog.accepts(.rename, on: instance))
    }

    @Test("A revert refuses the rename it would assign back over")
    func renameRefusedDuringARevert() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .revertingToSnapshot)

        #expect(!harness.catalog.accepts(.rename, on: instance))
    }

    @Test("A bundle still being copied takes no rename either")
    func renameRefusedWhilePreparing() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        let task = Task {}
        defer { task.cancel() }
        instance.preparingState = VMInstance.PreparingState(operation: .importing, task: task)

        #expect(!harness.catalog.accepts(.rename, on: instance))
    }

    @Test("Every capability but rename accepts exactly what it makes available")
    func acceptanceMatchesAvailabilityElsewhere() {
        for phase in Self.everyPhase {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)
            for capability in VMCapability.allCases where capability != .rename {
                #expect(
                    harness.catalog.accepts(capability, on: instance)
                        == harness.catalog.isAvailable(capability, on: instance),
                    "\(capability) on \(phase)")
            }
        }
    }

    // MARK: - Guest-specific capabilities

    @Test("Recovery and the guest-agent disk are macOS-guest capabilities")
    func macOSOnlyCapabilities() {
        let harness = makeHarness()
        let linux = makeInstance(in: harness, name: "Linux", phase: .stopped)
        let mac = makeInstance(in: harness, name: "macOS", phase: .stopped, guestOS: .macOS)

        #expect(!harness.catalog.isApplicable(.startInRecovery, to: linux))
        #expect(harness.catalog.isApplicable(.startInRecovery, to: mac))

        // The agent disk additionally needs a live session to look inside, which
        // neither stopped VM has.
        #expect(!harness.catalog.isApplicable(.toggleGuestAgentDisk, to: mac))
        let running = makeInstance(
            in: harness, name: "Running macOS", phase: .running(sessionID: UUID()),
            guestOS: .macOS)
        #expect(harness.catalog.isApplicable(.toggleGuestAgentDisk, to: running))
    }

    @Test("The clipboard window follows the VM's own sharing toggle")
    func clipboardFollowsTheSharingToggle() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness, phase: .running(sessionID: UUID()))

        #expect(!harness.catalog.isApplicable(.showClipboard, to: instance))

        instance.configuration.clipboardSharingEnabled = true
        #expect(harness.catalog.isApplicable(.showClipboard, to: instance))
    }
}
