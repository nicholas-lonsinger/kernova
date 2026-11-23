import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The USB accessory verbs, driven with no menu extra and no USB controller:
/// the vocabulary each failure comes back in, and the detach whose echo stays
/// with the Mac.
@Suite("VMCommandCore USB Accessory Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreUSBAccessoryTests {
    private let preferences = makeTestPreferences()

    private func makeHarness(
        _ passthrough: USBAccessoryPassthrough = .available(MockUSBAccessoryService())
    ) -> WiredCommandCore {
        WiredCommandCore(usbAccessoryPassthrough: passthrough, preferences: preferences)
    }

    /// A VM with a live session an accessory can be attached to.
    @discardableResult
    private func makeRunningInstance(in harness: WiredCommandCore, name: String = "Core VM") -> VMInstance {
        let instance = RegisteredVMInstanceFixture.register(
            name: name, phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences)
        instance.beginSessionContextForTesting()
        return instance
    }

    /// Attaches `accessory` to `instance` and answers the attachment's
    /// identifier — the setup every detach and every listing assertion needs.
    private func attach(
        _ accessory: USBAccessoryInfo, to instance: VMInstance, in harness: WiredCommandCore
    ) async throws -> UUID {
        let service = try #require(harness.usbAccessories)
        service.accessories.append(accessory)
        let deviceID = UUID()
        service.nextDeviceID = deviceID
        try await harness.core.attachUSBAccessory(
            .id(instance.id), accessory: accessory.registryID)
        return deviceID
    }

    // MARK: - Capability

    @Test("An accessory macOS has not assigned to Kernova is a miss, not a failed attach")
    func attachingAnUnassignedAccessoryIsRefusedAsAMiss() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let instance = makeRunningInstance(in: harness)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 7))

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 42)
        }

        // Host-scoped: the VM is not what is missing, and a script reads this
        // as the same kind of miss as a name nothing answers to.
        #expect(refusal == .itemNotFoundOnHost(item: "USB accessory with the identifier 42"))
        #expect(refusal.message == "Kernova has no USB accessory with the identifier 42.")
        #expect(service.attachedRegistryIDs.isEmpty)
        #expect(instance.liveUSBAccessories.isEmpty)
    }

    // MARK: - Failures

    @Test("A failed attach is refused in the vocabulary its cause names")
    func attachFailuresMapOntoTheCommandVocabulary() async throws {
        let cases: [(USBAccessoryError, (CommandError) -> Bool)] = [
            // The guest went away between the state gate and the controller.
            (.noVirtualMachine, \.isInvalidState),
            // A VM configured without a USB controller cannot hold one, and the
            // refusal names the VM, where a process without passthrough names
            // the host.
            (.noUSBController, { $0 == .unsupported(capability: "USB accessory passthrough") }),
            (.accessoryNotFound, \.isOperationFailure),
            (.deviceNotFound, \.isOperationFailure),
        ]

        for (thrown, matches) in cases {
            let harness = makeHarness()
            let service = try #require(harness.usbAccessories)
            let instance = makeRunningInstance(in: harness)
            service.accessories.append(MockUSBAccessoryService.accessory(registryID: 7))
            service.attachError = thrown

            let refusal = try await #require(throws: CommandError.self) {
                try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 7)
            }

            #expect(matches(refusal), "\(thrown)")
            #expect(instance.liveUSBAccessories.isEmpty, "\(thrown)")
        }
    }

    @Test("A detach naming a device the guest does not hold is refused, not quietly accepted")
    func detachOfAnUnknownDeviceIsRefused() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let instance = makeRunningInstance(in: harness)
        _ = try await attach(
            MockUSBAccessoryService.accessory(registryID: 11), to: instance, in: harness)
        let stranger = UUID()

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.detachUSBAccessory(.id(instance.id), device: stranger)
        }

        // "Already gone" is a success only for a device the guest was recorded
        // as holding; an identifier nothing answers to is a mistake, and
        // succeeding at it would tell a script the detach happened.
        #expect(refusal.isItemNotFound)
        #expect(
            refusal.message
                == "\u{201C}Core VM\u{201D} has no USB accessory with the device identifier \(stranger.uuidString)."
        )
        #expect(service.detachedDeviceIDs.isEmpty)
        #expect(instance.liveUSBAccessories.count == 1)
    }

    // MARK: - What the Edits Remember

    @Test(
        "A detach whose forget cannot be written still arms the echo token, so the device is not re-attached, and is reported"
    )
    func detachWhoseForgetFailsStillSuppressesTheEcho() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let instance = makeRunningInstance(in: harness)
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 7, serial: "0373", receptacle: "hub/Port-A@1")
        let deviceID = try await attach(accessory, to: instance, in: harness)
        let key = try #require(accessory.identity?.key)
        harness.storage.files.setReplaceError(
            CocoaError(.fileWriteNoPermission), for: VMBundleLayout.usbPairingsRelativePath)

        try await harness.core.detachUSBAccessory(.id(instance.id), device: deviceID)

        #expect(harness.failures.count == 1)
        #expect(
            harness.failures.first?.message.hasPrefix(
                "\(accessory.displayName) was detached from \u{201C}\(instance.name)\u{201D}, but Kernova could not forget it there. "
            ) == true)
        #expect(instance.usbPairings.pairing(forKey: key) != nil)
        // The detach's echo: macOS hands the same stick back under a new
        // registry ID, and the token keeps it with the Mac.
        service.accessories.removeAll()
        service.assignComposing(registryID: 8, serial: "0373", receptacle: "hub/Port-A@1")
        // The token is spent, so a later replug meets the pairing that stayed.
        service.accessories.removeAll()
        service.assignComposing(registryID: 9, serial: "0373", receptacle: "hub/Port-A@1")
        try await waitForChange { !instance.liveUSBAccessories.isEmpty }
        #expect(service.attachedRegistryIDs.contains(9))
        #expect(!service.attachedRegistryIDs.contains(8))
    }

    @Test("A detach's echo that arrives while the detach is in flight stays with the Mac")
    func echoDuringTheDetachIsNotReattached() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let instance = makeRunningInstance(in: harness)
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 7, serial: "0373", receptacle: "hub/Port-A@1")
        let deviceID = try await attach(accessory, to: instance, in: harness)
        let key = try #require(accessory.identity?.key)
        // A second accessory the guest takes back on its own: its automatic
        // attach, queued after the echo's would have been, marks the point by
        // which an echo that got through has been attached too.
        let marker = MockUSBAccessoryService.accessory(
            registryID: 20, serial: "MARKER", receptacle: "hub/Port-B@1")
        let markerPairing = try #require(USBAccessoryPairing.make(for: marker))
        try instance.activity.edit(.pairingRules) {
            try harness.library.pairUSBAccessory(markerPairing, $0)
        }
        // macOS hands the reset stick back under a new registry ID before the
        // detach has returned, while the pairing it ends is still in place.
        service.duringNextDetach = {
            service.accessories.removeAll { $0.registryID == accessory.registryID }
            service.assignComposing(registryID: 8, serial: "0373", receptacle: "hub/Port-A@1")
        }

        try await harness.core.detachUSBAccessory(.id(instance.id), device: deviceID)
        #expect(instance.usbPairings.pairing(forKey: key) == nil)

        service.assignComposing(registryID: 20, serial: "MARKER", receptacle: "hub/Port-B@1")
        try await waitForChange {
            instance.liveUSBAccessories.contains { $0.accessory.registryID == 20 }
        }
        #expect(!service.attachedRegistryIDs.contains(8))
    }
}

extension CommandError {
    fileprivate var isItemNotFound: Bool {
        if case .itemNotFound = self { return true }
        return false
    }

    fileprivate var isInvalidState: Bool {
        if case .invalidState = self { return true }
        return false
    }
}
