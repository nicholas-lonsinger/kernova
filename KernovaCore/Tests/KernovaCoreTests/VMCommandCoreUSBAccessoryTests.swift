import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The USB accessory verbs, driven with no menu extra and no USB controller:
/// the capability refusal a process without passthrough owes, the two listings,
/// the state gate an edit is admitted by, and the vocabulary each failure comes
/// back in.
@Suite("VMCommandCore USB Accessory Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreUSBAccessoryTests {
    private let preferences = makeTestPreferences()

    /// Each cause that keeps passthrough from a process, with the refusal
    /// every verb owes it and that refusal's message. The cause is the host,
    /// never a VM, so no refusal names one.
    nonisolated private static let unavailable: [(USBAccessoryPassthrough.Gap, CommandError, String)] = [
        (
            .needsEntitlement,
            .unsupportedByBuild(capability: "USB accessory passthrough"),
            "This build of Kernova does not support USB accessory passthrough."
        ),
        (
            .needsMacOS(27),
            .unsupportedByMacOS(capability: "USB accessory passthrough", minimumVersion: 27),
            "Kernova needs macOS 27 or later for USB accessory passthrough."
        ),
    ]

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

    private func makeStoppedInstance(in harness: WiredCommandCore, name: String = "Core VM") -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences)
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

    @Test(
        "Every verb refuses, naming the cause, in a process that cannot pass accessories through",
        arguments: unavailable)
    func everyVerbRefusesWithoutTheCapability(
        gap: USBAccessoryPassthrough.Gap, refusal: CommandError, message: String
    ) async throws {
        let harness = makeHarness(.unavailable(gap))
        let instance = makeRunningInstance(in: harness)

        let listing = try #require(throws: CommandError.self) {
            _ = try harness.core.usbAccessories(of: .id(instance.id))
        }
        let available = try #require(throws: CommandError.self) { _ = try harness.core.availableUSBAccessories() }
        let edit = try await #require(throws: CommandError.self) {
            try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 42)
        }

        // The cause is the host — its macOS, or a signature without the
        // entitlement — and none of the three refusals may describe a VM as
        // the thing that cannot do it.
        #expect(listing == refusal)
        #expect(edit == refusal)
        #expect(available == refusal)
        #expect(available.message == message)
    }

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

    // MARK: - Reads

    @Test("A guest's listing names each accessory by the attachment a detach takes back")
    func guestListingCarriesTheAttachment() async throws {
        let harness = makeHarness()
        let instance = makeRunningInstance(in: harness)
        let accessory = MockUSBAccessoryService.accessory(registryID: 4_294_967_296)
        let deviceID = try await attach(accessory, to: instance, in: harness)

        let listed = try harness.core.usbAccessories(of: .id(instance.id))

        #expect(listed.count == 1)
        #expect(listed.first?.registryID == accessory.registryID)
        #expect(listed.first?.deviceID == deviceID)
        #expect(listed.first?.name == accessory.displayName)
        #expect(listed.first?.vendorID == 0x0403)
        #expect(listed.first?.productID == 0x6001)
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

    @Test("A detach of a device the guest no longer holds succeeds and clears the entry")
    func detachOfAnAlreadyGoneDeviceSucceeds() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let instance = makeRunningInstance(in: harness)
        let deviceID = try await attach(
            MockUSBAccessoryService.accessory(registryID: 11), to: instance, in: harness)
        service.detachError = USBAccessoryError.deviceNotFound

        // A surprise unplug, or a save's own detach sweep, may have got there
        // first — the outcome the caller asked for already holds, so this is
        // not something to alert about.
        try await harness.core.detachUSBAccessory(.id(instance.id), device: deviceID)

        #expect(instance.liveUSBAccessories.isEmpty)
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

    // MARK: - Names

    @Test("Two accessories that would read alike are told apart by their ports")
    func duplicateNamesAreQualifiedAcrossBothListings() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let instance = makeRunningInstance(in: harness)
        let held = MockUSBAccessoryService.accessory(
            registryID: 1, serial: "AAA", receptacle: "hub/Port-USB-C@2", vendorName: "Samsung",
            productName: "Type-C")
        _ = try await attach(held, to: instance, in: harness)
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 2, serial: "BBB", receptacle: "hub/Port-USB-C@3", vendorName: "Samsung",
                productName: "Type-C"))

        let attached = try harness.core.usbAccessories(of: .id(instance.id))
        let available = try harness.core.availableUSBAccessories()

        // One menu shows both lists, so the qualifier has to be decided across
        // the pair rather than within either one.
        #expect(attached.map(\.name) == ["Samsung Type-C (Port-USB-C@2)"])
        #expect(available.map(\.name) == ["Samsung Type-C (Port-USB-C@3)"])
    }

    @Test("An accessory a guest holds is not qualified against itself")
    func theOnlyAccessoryKeepsItsPlainNameWhileAttached() async throws {
        let harness = makeHarness()
        let instance = makeRunningInstance(in: harness)
        // macOS withdraws an accessory a guest captured, but not always before
        // the guest's listing is read — so the same one can be in both sets,
        // and counting it twice would make it qualify itself.
        _ = try await attach(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "AAA", receptacle: "hub/Port-USB-C@2", vendorName: "Samsung",
                productName: "Type-C"), to: instance, in: harness)

        #expect(try harness.core.usbAccessories(of: .id(instance.id)).map(\.name) == ["Samsung Type-C"])
        #expect(try harness.core.availableUSBAccessories().isEmpty)
    }

    @Test("A detach that fails for any other reason reports what it was told")
    func detachFailureCarriesItsMessage() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let instance = makeRunningInstance(in: harness)
        let deviceID = try await attach(
            MockUSBAccessoryService.accessory(registryID: 12), to: instance, in: harness)
        service.detachError = USBAccessoryError.accessoryNotFound

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.detachUSBAccessory(.id(instance.id), device: deviceID)
        }

        #expect(refusal.isOperationFailure)
        #expect(refusal.message == USBAccessoryError.accessoryNotFound.errorDescription)
    }

    // MARK: - One accessory, one guest

    @Test("An accessory another guest is holding is refused rather than handed over twice")
    func anAccessoryHeldElsewhereIsRefused() async throws {
        let harness = makeHarness()
        let holder = makeRunningInstance(in: harness, name: "Holder")
        let other = makeRunningInstance(in: harness, name: "Other")
        _ = try await attach(
            MockUSBAccessoryService.accessory(registryID: 5), to: holder, in: harness)

        let refusal = try await #require(throws: CommandError.self) {
            try await harness.core.attachUSBAccessory(.id(other.id), accessory: 5)
        }

        // A guest captures an accessory exclusively, so the second attach could
        // otherwise only fail inside VZ.
        #expect(refusal.isOperationFailure)
        #expect(refusal.message == "That USB accessory is in use by \u{201C}Holder\u{201D}.")
        #expect(other.liveUSBAccessories.isEmpty)
        #expect(holder.liveUSBAccessories.count == 1)
    }

    // MARK: - What the Edits Remember

    @Test("A pairing move the VM holding the pairing refuses is reported as that VM being busy")
    func pairingMoveRefusalNamesTheHoldingVM() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let holder = makeStoppedInstance(in: harness, name: "Holder")
        let target = makeRunningInstance(in: harness, name: "Target")
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 7, serial: "0373", receptacle: "hub/Port-A@1")
        let pairing = try #require(USBAccessoryPairing.make(for: accessory))
        try holder.activity.edit(.pairingRules) {
            try harness.library.updateUSBPairings($0) { $0.upsert(pairing) }
        }
        holder.activity.placeForTesting(.operating(.deleting, from: .stopped))

        _ = try await attach(accessory, to: target, in: harness)

        #expect(service.attachedRegistryIDs == [7])
        let busy = harness.core.commandError(for: .busy(.deleting), on: holder)
        #expect(harness.failures.count == 1)
        #expect(harness.failures.first?.message.hasSuffix(busy.message) == true)
        #expect(holder.usbPairings.pairings.map(\.key) == [pairing.key])
        #expect(target.usbPairings.isEmpty)
    }

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

    // MARK: - Listing and Forgetting

    @Test("The rules listing covers the whole library when no machine is named")
    func pairingListingCoversEveryMachine() async throws {
        let harness = makeHarness()
        let first = makeRunningInstance(in: harness, name: "First")
        let second = makeRunningInstance(in: harness, name: "Second")
        _ = try await attach(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "AAA", vendorName: "Samsung", productName: "Type-C"),
            to: first, in: harness)
        _ = try await attach(
            MockUSBAccessoryService.accessory(
                registryID: 2, receptacle: "hub/Port-A@1", productName: "Drive"),
            to: second, in: harness)

        let everyMachine = try harness.core.usbPairings(of: nil)
        let justFirst = try harness.core.usbPairings(of: .id(first.id))

        #expect(everyMachine.map(\.vm) == ["First", "Second"])
        #expect(everyMachine.map(\.name) == ["Samsung Type-C", "Drive (Port-A@1)"])
        // A rule keyed on a port is a claim about the port; one keyed on the
        // device's own serial follows it anywhere, so naming a port there would
        // say something the rule does not.
        #expect(justFirst.map(\.key) == [everyMachine.first?.key])
    }

    @Test("Forgetting works on a machine that is not running")
    func forgetDoesNotNeedALiveGuest() async throws {
        let harness = makeHarness()
        let instance = makeRunningInstance(in: harness)
        let accessory = MockUSBAccessoryService.accessory(registryID: 7, serial: "0373")
        _ = try await attach(accessory, to: instance, in: harness)
        let key = try #require(accessory.identity?.key)
        instance.handleSessionEvent(.guestDidStop)

        // A rule names hardware that is usually in a drawer, so requiring a
        // live guest would make the rows that most need removing unremovable.
        try harness.core.forgetUSBPairing(.id(instance.id), key: key)

        #expect(instance.usbPairings.isEmpty)
    }

    @Test(
        "Both remembered-accessory verbs refuse, naming the cause, in a process without passthrough",
        arguments: unavailable)
    func pairingVerbsRefuseWithoutTheCapability(
        gap: USBAccessoryPassthrough.Gap, refusal: CommandError, message: String
    ) async throws {
        let harness = makeHarness(.unavailable(gap))
        let instance = makeRunningInstance(in: harness)

        let listing = try #require(throws: CommandError.self) { _ = try harness.core.usbPairings(of: nil) }
        let forget = try #require(throws: CommandError.self) {
            try harness.core.forgetUSBPairing(.id(instance.id), key: "k")
        }

        #expect(listing == refusal)
        #expect(forget == refusal)
        #expect(listing.message == message)
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
