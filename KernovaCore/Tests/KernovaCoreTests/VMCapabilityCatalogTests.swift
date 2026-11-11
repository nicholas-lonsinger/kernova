import Foundation
import KernovaAgentCore
import KernovaAgentHost
import KernovaCommandModel
import KernovaTestSupport
import KernovaWire
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The catalog's own part of per-VM capability: which request each capability
/// asks admission for, how its three levels read that one decision, and the
/// surfaces derived from them. What admission decides for each request is
/// ``VMAdmissionTests``'.
@Suite("VMCapabilityCatalog Tests", .serialized, .caseScoped)
@MainActor
struct VMCapabilityCatalogTests {
    private let preferences = makeTestPreferences()

    private struct Harness {
        let catalog: VMCapabilityCatalog
        let library: VMLibrary
        let lifecycle: VMLifecycleCoordinator
        let storage: MockVMStorageService
    }

    private func makeHarness(
        virtualization: any VirtualizationProviding = MockVirtualizationService(),
        usbAccessoryPassthrough: USBAccessoryPassthrough = .unavailable(.needsEntitlement)
    ) -> Harness {
        let storage = MockVMStorageService()
        let lifecycle = makeTestLifecycle(
            virtualization: virtualization,
            usbAccessoryPassthrough: usbAccessoryPassthrough)
        let library = makeWiredLibrary(
            storage: storage,
            lifecycle: lifecycle,
            preferences: preferences)
        return Harness(
            catalog: VMCapabilityCatalog(library: library), library: library, lifecycle: lifecycle,
            storage: storage)
    }

    @discardableResult
    private func makeInstance(
        in harness: Harness, name: String = "Catalog VM", phase: VMLifecyclePhase = .stopped,
        guestOS: VMGuestOS = .linux, snapshots: [VMSnapshot] = [],
        hostState: VMHostState = VMHostState(),
        mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: phase, guestOS: guestOS, snapshots: snapshots,
            library: harness.library, preferences: preferences,
            hostState: hostState, mutate: mutate)
    }

    private static let coldBoot = VMOperationKind.bringUp(.guestStart(.starting(recovery: false)))

    // MARK: - The request each capability asks for

    /// Written out independently of ``VMCapability/request(on:)``; the revert
    /// and the USB edit name a snapshot and an accessory that do not change the
    /// decision, so those two rows are matched by shape below.
    private static let requests: [VMCapability: VMAdmission.Request] = [
        .info: .affordance(.inspect),
        .ipAddress: .affordance(.inspect),
        .snapshots: .affordance(.inspect),
        .start: .start(recovery: false),
        .startInRecovery: .start(recovery: true),
        .cancelGuestSetup: .cancel(.guestSetup),
        .stop: .sessionAction(.requestStop),
        .restart: .sessionAction(.requestStop),
        .forceStop: .sessionAction(.forceStop),
        .stopAnyway: .sessionAction(.requestStop),
        .discardSavedState: .operation(.discardingSavedState),
        .pause: .operation(.pausing),
        .resume: .resume,
        .suspend: .operation(.saving),
        .open: .affordance(.display),
        .reveal: .affordance(.inspect),
        .takeSnapshot: .operation(.capturingSnapshot(.stopped)),
        .deleteSnapshot: .operation(.deletingSnapshot),
        .renameSnapshot: .edit(.snapshotMetadata),
        .setSnapshotNotes: .edit(.snapshotMetadata),
        .editStorageDisks: .edit(.machineKeys),
        .createStorageDisk: .operation(.creatingStorageDisk),
        .trashStorageDisk: .operation(.removingStorageDisk),
        .editRemovableMedia: .edit(.hotPlugMedia),
        .removeRemovableMedia: .edit(.removableMediaRemoval),
        .createRemovableMedia: .operation(.creatingRemovableMedia),
        .editSharedDirectories: .edit(.machineKeys),
        .editLiveSharedDirectories: .edit(.liveShares),
        .forgetUSBPairing: .edit(.pairingRules),
        .editConfiguration: .edit(.machineKeys),
        .editLiveConfiguration: .edit(.liveKeys),
        .switchNetworkMode: .edit(.networkAttachment),
        .switchNetworkMembership: .edit(.networkMembership),
        .editPresentation: .edit(.hostPresentation),
        .clone: .operation(.copyingOut(.stopped)),
        .rename: .edit(.rename),
        .editTags: .edit(.hostPresentation),
        .delete: .operation(.deleting),
        .showInFinder: .affordance(.inspect),
        .togglePopOut: .affordance(.externalDisplay),
        .toggleFullscreen: .affordance(.externalDisplay),
        .copyGuestClipboardToMac: .affordance(.clipboard),
        .copyMacClipboardToGuest: .affordance(.clipboard),
        .showGuestAgentStatus: .affordance(.guestAgentStatus),
        .toggleGuestAgentDisk: .affordance(.guestAgentDisk),
        .toggleSettingsPane: .affordance(.display),
    ]

    @Test("Each capability asks admission for the request the table states")
    func requestPerCapability() {
        let harness = makeHarness()
        let instance = makeInstance(in: harness)
        // Stop Anyway names a request only where the guest's agents offer it.
        #expect(VMCapability.stopAnyway.request(on: instance) == nil)
        // The clipboard commands name one only while an agent carries the clipboard.
        #expect(VMCapability.copyGuestClipboardToMac.request(on: instance) == nil)
        #expect(VMCapability.copyMacClipboardToGuest.request(on: instance) == nil)
        Self.carryClipboard(on: instance, powerIgnoringApps: .agent(.systemPeer))
        for capability in VMCapability.allCases {
            let request = capability.request(on: instance)
            switch capability {
            case .revertToSnapshot:
                guard case .operation(.bringUp(.reverting(_, resumesAfter: false)))? = request else {
                    Issue.record("\(capability) asked for \(String(describing: request))")
                    continue
                }
            case .editUSBAccessories:
                guard case .operation(.attachingUSB)? = request else {
                    Issue.record("\(capability) asked for \(String(describing: request))")
                    continue
                }
            default:
                #expect(request == Self.requests[capability], "\(capability)")
            }
        }
        #expect(Self.requests.count == VMCapability.allCases.count - 2)
    }

    // MARK: - The three levels

    /// Everything a saved state pins, because VZ restores one only into the
    /// configuration it was written under.
    private static let pinnedBySavedState: Set<VMCapability> = [
        .editStorageDisks, .editRemovableMedia, .editSharedDirectories,
        .editConfiguration, .switchNetworkMode,
    ]

    @Test("A saved state pins an at-rest VM's settings and trades its Start for Resume")
    func aSavedStateRepinsWhatAnAtRestVMOffers() throws {
        for phase: VMLifecyclePhase in [.stopped, .failed(message: "Boot failed."), .suspended] {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)

            // With no slot on disk, every at-rest phase answers the same way.
            #expect(harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(!harness.catalog.isApplicable(.resume, to: instance), "\(phase)")
            #expect(!harness.catalog.isApplicable(.discardSavedState, to: instance), "\(phase)")
            for capability in Self.pinnedBySavedState {
                #expect(
                    harness.catalog.isApplicable(capability, to: instance),
                    "\(capability) with no slot, \(phase)")
            }
            #expect(harness.catalog.isApplicable(.delete, to: instance), "\(phase)")

            try VMInstanceFixture.writeSaveFile(for: instance)

            for capability in Self.pinnedBySavedState {
                #expect(
                    !harness.catalog.isApplicable(capability, to: instance),
                    "\(capability) with a slot, \(phase)")
            }
            #expect(!harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(harness.catalog.isApplicable(.resume, to: instance), "\(phase)")
            #expect(harness.catalog.isApplicable(.discardSavedState, to: instance), "\(phase)")
            // A saved state restores across a removal of removable media.
            #expect(
                harness.catalog.isApplicable(.removeRemovableMedia, to: instance), "\(phase)")
            // A clone carries the slot rather than being pinned out by it.
            #expect(harness.catalog.isApplicable(.clone, to: instance), "\(phase)")
            // Delete keeps working: the slot is a file inside the bundle and
            // goes with it.
            #expect(harness.catalog.isApplicable(.delete, to: instance), "\(phase)")
            // The offer names Resume; a start committed anyway restores rather
            // than being refused.
            #expect(harness.catalog.accepts(.start, on: instance), "\(phase)")
            #expect(harness.catalog.stopAction(for: instance) == .discardSavedState, "\(phase)")
        }
    }

    // MARK: - The stop slot

    @Test("The stop slot names a graceful stop, a discard, or an Ephemeral revert")
    func stopActionNamesWhatTheSlotDoes() throws {
        let harness = makeHarness()
        let running = makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        #expect(harness.catalog.stopAction(for: running) == .stop)

        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        #expect(harness.catalog.stopAction(for: suspended) == .discardSavedState)

        let baseline = VMSnapshot(name: "Ephemeral", macAddress: nil)
        let ephemeral = makeInstance(
            in: harness, name: "Ephemeral VM", phase: .suspended, snapshots: [baseline],
            hostState: VMHostState(ephemeralModeEnabled: true, ephemeralBaselineSnapshotID: baseline.id))
        try VMInstanceFixture.writeSaveFile(for: ephemeral)
        #expect(harness.catalog.stopAction(for: ephemeral) == .revertToBaseline)
    }

    @Test("The stop slot stands for both capabilities that can fill it")
    func stopActionAvailabilityCoversBothCapabilities() throws {
        let harness = makeHarness()
        let running = makeInstance(in: harness, name: "Running", phase: .running(sessionID: UUID()))
        #expect(harness.catalog.isAvailable(.stop, on: running))
        #expect(harness.catalog.isStopActionAvailable(on: running))

        let suspended = makeInstance(in: harness, name: "Suspended", phase: .suspended)
        try VMInstanceFixture.writeSaveFile(for: suspended)
        #expect(!harness.catalog.isAvailable(.stop, on: suspended))
        #expect(harness.catalog.isAvailable(.discardSavedState, on: suspended))
        #expect(harness.catalog.isStopActionAvailable(on: suspended))

        let stopped = makeInstance(in: harness, name: "Stopped", phase: .stopped)
        #expect(!harness.catalog.isStopActionAvailable(on: stopped))
    }

    @Test("Clone stays available while a different VM is being copied")
    func cloneIgnoresAnotherVMsCopy() async {
        let harness = makeHarness()
        let settled = makeInstance(in: harness, name: "Settled")
        let gate = GatedStep()
        let copying = harness.library.beginGatedArrival(named: "Copying", gate: gate)

        // Bundle destinations are reserved atomically and overlapping copies are
        // a supported case, so one VM's copy says nothing about another's.
        #expect(harness.library.arrivals.map(\.id) == [copying.id])
        #expect(harness.catalog.isAvailable(.clone, on: settled))

        gate.release()
        await copying.settle()
    }

    // MARK: - Bring-up: offer versus accept

    @Test("A start is taken during the bring-up it would begin, and offered during none")
    func startAcceptsAVMAlreadyComingUp() throws {
        // What lets the CLI verb that cold-launched the app join the boot the
        // launch auto-start pass began, in whichever order the two resumed. The
        // restore carries it too: a boot with a save file spends its whole
        // observable window there.
        let starting: [VMLifecyclePhase] = [
            .operating(Self.coldBoot, from: .stopped),
            .operating(Self.coldBoot, from: .stopped, boundSession: UUID()),
        ]
        for phase in starting {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)

            #expect(harness.catalog.accepts(.start, on: instance), "\(phase)")
            // Shown dimmed: the VM takes a Start once it rests again.
            #expect(harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(!harness.catalog.isAvailable(.start, on: instance), "\(phase)")
        }

        let restoring: [VMLifecyclePhase] = [
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended, boundSession: UUID()),
        ]
        for phase in restoring {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase)
            try VMInstanceFixture.writeSaveFile(for: instance)

            for capability: VMCapability in [.start, .resume] {
                #expect(harness.catalog.accepts(capability, on: instance), "\(capability) \(phase)")
                #expect(!harness.catalog.isAvailable(capability, on: instance), "\(capability) \(phase)")
            }
            // A VM holding a saved state is offered Resume, never Start.
            #expect(!harness.catalog.isApplicable(.start, to: instance), "\(phase)")
            #expect(harness.catalog.isApplicable(.resume, to: instance), "\(phase)")
        }
    }

    // MARK: - Guest-specific capabilities

    /// Has a console peer carry `instance`'s clipboard through its hub.
    private static func carryClipboard(
        on instance: VMInstance, powerIgnoringApps: PowerProvision = .absent(.noAgent)
    ) {
        let peer = PeerHandle(rawValue: 1)
        instance.publishAgentHubSnapshotForTesting(
            AgentHubSnapshot(
                peers: [], features: FeatureStatus.merge([]), powerIgnoringApps: powerIgnoringApps,
                consolePeers: [.clipboard: peer]))
        instance.hubClipboard.setConsolePeer(peer)
    }

    // MARK: - Reveal surface

    /// Which window a `reveal` — from the CLI, a `kernova:` link, AppleScript,
    /// the Open intent, or a click in the status-item dropdown — brings forward.
    ///
    /// The gate is ``VMCapability/open``'s, so a phase with a display to show
    /// opens the window showing it whatever that display currently holds: the
    /// paused poster of a suspended VM and the transition label of a VM being
    /// captured, as much as the live guest of a running one.
    @Test("The reveal surface follows the display a VM has and where that display lives")
    func revealSurfaceByPreferenceAndPhase() {
        // Where a pop-out or fullscreen VM reveals to, one per
        // ``VMLifecyclePhaseFixtures/all`` entry in its order. An inline VM
        // reveals into the library in every one of them, which the loop asserts
        // alongside.
        let library = VMCapabilityCatalog.RevealSurface.library
        let window = VMCapabilityCatalog.RevealSurface.displayWindow
        let detached: [VMCapabilityCatalog.RevealSurface] = [
            // stopped, initialBoot, failed, suspended, running, livePaused, removed
            library, library, library, window, window, window, library,
            // starting (unbound, bound), restoring, setting up, reverting
            library, library, window, library, window,
            // pausing, resuming, saving, capturing live, capturing disks
            window, window, window, window, window,
            // snapshot delete, USB attach, media reconcile, Force Stop, deleting
            window, window, window, window, library,
            // storage disk on a stopped VM, removable disk on a running one,
            // snapshot delete on a stopped one
            library, window, library,
        ]
        let phases = VMLifecyclePhaseFixtures.all
        #expect(detached.count == phases.count)

        for (index, (phase, expected)) in zip(phases, detached).enumerated() {
            let harness = makeHarness()
            for preference in [VMDisplayPreference.popOut, .fullscreen] {
                let instance = makeInstance(
                    in: harness, name: "VM \(index) \(preference)", phase: phase,
                    hostState: VMHostState(displayPreference: preference))
                #expect(
                    harness.catalog.revealSurface(for: instance) == expected,
                    "\(phase) \(preference)")
            }
            let inline = makeInstance(in: harness, name: "VM \(index) inline", phase: phase)
            #expect(harness.catalog.revealSurface(for: inline) == .library, "\(phase) inline")
        }
    }

    // MARK: - The guest account

    @available(macOS 27.0, *)
    @Test("The account state walks from nothing, through owed, to answered")
    func guestAccountStateWalksItsThreeStandings() {
        let harness = makeHarness()
        let intent = GuestAccountIntent(
            fullName: "Ada Lovelace", username: "ada", logsInAutomatically: false,
            enablesRemoteLogin: false)
        let without = makeInstance(in: harness, phase: .stopped, guestOS: .macOS)
        #expect(harness.catalog.guestAccountState(of: without) == .none)

        // An account is set only at creation.
        let instance = makeInstance(in: harness, phase: .stopped, guestOS: .macOS) {
            $0.pendingGuestAccount = intent
        }
        #expect(harness.catalog.guestAccountState(of: instance) == .owed(intent))

        harness.library.holdGuestAccountPassword(
            GuestAccountPassword("analytical-engine"), for: instance.id)
        #expect(
            harness.catalog.guestAccountState(of: instance)
                == .answered(intent, GuestAccountPassword("analytical-engine")))
    }

    // MARK: - Shared directories

    @Test(
        "A share-list edit is offered by the rule's capability and the phase the VM is in",
        arguments: VMGuestOS.allCases)
    func sharedDirectoriesOfferPerPhase(guestOS: VMGuestOS) throws {
        let phases: [(String, VMLifecyclePhase, slot: Bool)] = [
            ("stopped", .stopped, false),
            ("suspended", .suspended, true),
            ("running", .running(sessionID: UUID()), false),
            ("paused", .livePaused(sessionID: UUID()), false),
        ]
        for (label, phase, slot) in phases {
            let harness = makeHarness()
            let instance = makeInstance(in: harness, phase: phase, guestOS: guestOS) {
                $0.sharedDirectories = [SharedDirectory(path: "/Users/Shared/one")]
            }
            if slot { try VMInstanceFixture.writeSaveFile(for: instance) }
            let add = harness.catalog.sharedDirectoriesOffer(.add, on: instance)
            let change = harness.catalog.sharedDirectoriesOffer(.change, on: instance)
            let removeLast = harness.catalog.sharedDirectoriesOffer(.remove, on: instance)
            let oneDevice = guestOS.sharesDirectoriesThroughOneDevice
            let context = "\(label) \(guestOS)"
            switch label {
            case "stopped":
                #expect(add == .offered(.editSharedDirectories), "\(context)")
                #expect(removeLast == .offered(.editSharedDirectories), "\(context)")
            case "running" where oneDevice:
                #expect(add == .offered(.editLiveSharedDirectories), "\(context)")
                #expect(change == .offered(.editLiveSharedDirectories), "\(context)")
                #expect(removeLast == .changesSharingDevice, "\(context)")
            case "running", "paused":
                let capability: VMCapability =
                    oneDevice ? .editLiveSharedDirectories : .editSharedDirectories
                #expect(add == .unavailable(capability), "\(context)")
                #expect(!removeLast.isOffered, "\(context)")
            default:
                #expect(add == .unavailable(.editSharedDirectories), "\(context)")
                #expect(removeLast == .unavailable(.editSharedDirectories), "\(context)")
            }
            #expect(
                harness.catalog.isAvailable(.editLiveSharedDirectories, on: instance)
                    == (label == "running" && oneDevice), "\(context)")
        }
    }
}
