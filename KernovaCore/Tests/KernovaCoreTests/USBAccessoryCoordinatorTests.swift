import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// What the coordinator does with an assignment: reconcile the guests' records,
/// then route it — back to the VM it is paired with, to a prompt, or nowhere.
@Suite("USB Accessory Coordinator Tests", .caseScoped)
@MainActor
struct USBAccessoryCoordinatorTests {
    /// The coordinator under test, wired as the app wires it: over a library
    /// that is its roster, its holders and its pairing funnel.
    private struct Harness {
        let lifecycle: VMLifecycleCoordinator
        let library: VMLibrary
        let coordinator: USBAccessoryCoordinator
    }

    /// Nothing else holds the coordinator — the closures it installs on the
    /// service capture it weakly, as the one real owner is
    /// `VMLibraryViewModel` — so a test that discards it is testing a
    /// coordinator that answers nothing, and every "leaves it alone" assertion
    /// passes for the wrong reason. Callers keep the returned harness alive
    /// for the length of the test; the library's VMs reach it weakly too.
    private func makeHarness(_ service: MockUSBAccessoryService) throws -> Harness {
        let lifecycle = makeTestLifecycle(usbAccessoryPassthrough: .available(service))
        let library = makeWiredLibrary(lifecycle: lifecycle)
        let coordinator = try #require(
            USBAccessoryCoordinator(
                lifecycle: lifecycle, library: library))
        return Harness(lifecycle: lifecycle, library: library, coordinator: coordinator)
    }

    @discardableResult
    private func makeInstance(in h: Harness, sessionID: UUID, named name: String = "USB VM") -> VMInstance {
        let instance = makeStoppedInstance(in: h, named: name)
        instance.activity.placeForTesting(.running(sessionID: sessionID))
        instance.beginSessionContextForTesting()
        return instance
    }

    /// A VM with no session, for the tests that drive the edge onto one.
    @discardableResult
    private func makeStoppedInstance(in h: Harness, named name: String = "USB VM") -> VMInstance {
        h.library.registerFixture(name: name)
    }

    /// Records `accessory` against `instance`, the way an attach the user asked
    /// for would.
    @discardableResult
    private func pair(_ accessory: USBAccessoryInfo, with instance: VMInstance) throws
        -> USBAccessoryPairing
    {
        let pairing = try #require(USBAccessoryPairing.make(for: accessory))
        var pairings = instance.usbPairings
        pairings.upsert(pairing)
        instance.seedUSBPairings(pairings)
        return pairing
    }

    /// Whether every VM in the library is at rest with nothing queued on it.
    ///
    /// The coordinator's every attach is a follow-up, admitted or queued in
    /// the same turn as the assignment or edge that asks for it, so once this
    /// holds after that turn no attach is pending and none can start.
    private func nothingPending(in h: Harness) -> Bool {
        h.library.instances.allSatisfy {
            $0.phase.isSettled && $0.activity.queuedFollowUpCountForTesting == 0
        }
    }

    /// Collects the prompts a coordinator raises, leaving each unanswered.
    private final class PromptRecorder {
        var requests: [USBAccessoryPairingRequest] = []
    }

    @Test("Leaves a guest's record alone for a second unit reporting the same serial")
    func aDuplicateSerialElsewhereLeavesTheRecordAlone() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        defer { withExtendedLifetime(h) {} }
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "0373", receptacle: "hub/Port-A@1"))
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        service.accessories.removeAll()

        // A second stick of the same model, in another hole, whose vendor gave
        // it the serial the first one reports. Dropping the guest's record here
        // would leave it holding a device it could no longer detach.
        let second = service.assignComposing(
            registryID: 2, serial: "0373", receptacle: "hub/Port-A@2")

        #expect(second.identity?.form == .receptacle)
        #expect(instance.liveUSBAccessories.count == 1)
    }

    // MARK: - Routing a Fresh Arrival

    @Test("An accessory no rule names is offered to the running guests")
    func anUnpairedAccessoryRaisesAPrompt() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let first = makeInstance(in: h, sessionID: UUID(), named: "First")
        let second = makeInstance(in: h, sessionID: UUID(), named: "Second")
        makeStoppedInstance(in: h, named: "Stopped")
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }

        service.assign(
            MockUSBAccessoryService.accessory(
                registryID: 7, serial: "0373", vendorName: "Samsung", productName: "Type-C"))

        #expect(recorder.requests.count == 1)
        #expect(recorder.requests.first?.accessory.registryID == 7)
        #expect(recorder.requests.first?.accessory.name == "Samsung Type-C")
        // Only the guests that could take it right now, and nothing attached
        // until the user answers.
        #expect(recorder.requests.first?.candidates.map(\.id) == [first.id, second.id])
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    // MARK: - The Guards

    @Test("An accessory two virtual machines claim is held rather than guessed at")
    func twoClaimantsHoldTheAccessory() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let first = makeInstance(in: h, sessionID: UUID(), named: "First")
        let second = makeInstance(in: h, sessionID: UUID(), named: "Second")
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        let accessory = MockUSBAccessoryService.accessory(registryID: 1, serial: "0373")
        // Hand-edited files, or a bundle copied outside the app: which VM the
        // device belongs to is not decidable.
        try pair(accessory, with: first)
        try pair(accessory, with: second)

        service.assign(accessory)

        #expect(recorder.requests.isEmpty)
        #expect(nothingPending(in: h))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    @Test("A port-keyed rule holds while a second accessory of that model is around")
    func theWeakFormGuardHolds() throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeInstance(in: h, sessionID: UUID())
        defer { withExtendedLifetime(h) {} }
        // No serial to key on, so the rule names the port rather than the unit.
        let paired = MockUSBAccessoryService.accessory(
            registryID: 1, receptacle: "hub/Port-A@1", productName: "Drive")
        try #require(paired.identity?.form == .receptacle)
        try pair(paired, with: instance)
        // A second unit of the same model, already assigned: whichever one is
        // now in the port, the key cannot say which.
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 2, receptacle: "hub/Port-A@2", productName: "Drive"))

        service.assign(paired)

        #expect(nothingPending(in: h))
        #expect(service.attachedRegistryIDs.isEmpty)
    }

    // MARK: - Owed Returns

    /// Runs a warm capture's sweep on `instance`, and macOS withdraws each
    /// stick while the reset runs. Parks on `gate`, when given, before ending.
    private func capture(
        _ instance: VMInstance, service: MockUSBAccessoryService, gate: GatedStep? = nil
    ) async throws {
        try await instance.activity.launchedCapture(.live) { context in
            try await VMLiveStateCapture.captureLiveState(
                context, session: MockSnapshotSession(guestState: .running), wasRunning: false,
                saveFileURL: URL(filePath: "/var/empty/save.vzvmsave")
            ) {}
            service.accessories.removeAll()
            try await gate?.pass()
            return .rest(.asStarted, ())
        }
    }

    @Test("An owed return is spent by one arrival, so the next one is routed as fresh")
    func anOwedReturnIsSpentOnce() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let sessionID = UUID()
        let instance = makeInstance(in: h, sessionID: sessionID)
        let recorder = PromptRecorder()
        defer { withExtendedLifetime(h) {} }
        h.coordinator.onPairingNeeded = { recorder.requests.append($0) }
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "0373", receptacle: "hub/Port-A@1"))
        try await h.lifecycle.attachUSBAccessory(1, to: instance, for: sessionID)
        try await capture(instance, service: service)
        let returned = service.assignComposing(
            registryID: 2, serial: "0373", receptacle: "hub/Port-A@1")
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }

        // Taken off again by something other than a capture: its next arrival
        // owes nothing, and nothing pairs it, so the user is asked.
        let attached = try #require(instance.liveUSBAccessories.first)
        try await h.lifecycle.detachUSBAccessory(
            deviceID: attached.deviceID, from: instance, for: sessionID)
        service.accessories.removeAll { $0.registryID == returned.registryID }
        service.assignComposing(registryID: 3, serial: "0373", receptacle: "hub/Port-A@1")

        #expect(recorder.requests.map(\.accessory.registryID) == [3])
        #expect(service.attachedRegistryIDs == [1, 2])
    }

    // MARK: - VM Start

    @Test("A guest that becomes attachable takes back every accessory paired with it, one attach after another")
    func aStartTakesBackItsAccessories() async throws {
        let service = MockUSBAccessoryService()
        let h = try makeHarness(service)
        let instance = makeStoppedInstance(in: h)
        let other = makeStoppedInstance(in: h, named: "Other")
        defer { withExtendedLifetime(h) {} }
        instance.activity.onSessionBecameAttachable = { [weak coordinator = h.coordinator] in
            coordinator?.sessionBecameAttachable(instance) ?? []
        }
        let mine = MockUSBAccessoryService.accessory(registryID: 1, serial: "A")
        let theirs = MockUSBAccessoryService.accessory(registryID: 2, serial: "B")
        let alsoMine = MockUSBAccessoryService.accessory(registryID: 3, serial: "C")
        try pair(mine, with: instance)
        try pair(theirs, with: other)
        try pair(alsoMine, with: instance)
        service.accessories = [mine, theirs, alsoMine]

        instance.beginSessionContextForTesting()
        instance.activity.placeForTesting(.running(sessionID: UUID()))

        // The first attach holds the VM; the second waits behind it.
        #expect(instance.phase.operation?.kind == .attachingUSB(registryID: 1))
        #expect(instance.activity.queuedFollowUpCountForTesting == 1)
        try await waitForChange { instance.liveUSBAccessories.count == 2 }
        #expect(service.attachedRegistryIDs == [1, 3])
    }
}
