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
}
