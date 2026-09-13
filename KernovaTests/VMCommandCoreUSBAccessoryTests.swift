import Foundation
import KernovaKit
import Testing

@testable import Kernova

/// The USB accessory verbs, driven with no menu extra and no USB controller:
/// the capability refusal a build without passthrough owes, the two listings,
/// the state gate an edit is admitted by, and the vocabulary each failure comes
/// back in.
@Suite("VMCommandCore USB Accessory Tests", .serialized, .admissionGated)
@MainActor
struct VMCommandCoreUSBAccessoryTests {
    private let preferences = makeEphemeralPreferences(suiteName: "test.kernova.commandcore.usb")

    /// The refusal every verb owes a build that cannot pass accessories
    /// through — the cause is the build, so no VM is named.
    private let unsupportedByBuild = CommandError.unsupportedByBuild(
        capability: "USB accessory passthrough")

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let lifecycle: VMLifecycleCoordinator
        let storage: MockVMStorageService
        let accessories: MockUSBAccessoryService?
        /// Wired the way `VMLibraryViewModel` wires it, so what an attach and a
        /// detach mean for the pairings is exercised rather than stubbed — and
        /// held, because the core references it weakly.
        let pairingCoordinator: USBAccessoryCoordinator?
    }

    private func makeHarness(withAccessorySupport: Bool = true) -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMSnapshotStore()
        let fileSystem = MockFileSystem()
        let accessories = withAccessorySupport ? MockUSBAccessoryService() : nil
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: MockVirtualizationService(),
            installService: MockMacOSInstallService(),
            ipswService: MockIPSWService(),
            removableMediaDeviceService: MockRemovableMediaDeviceService(),
            usbAccessoryService: accessories,
            linuxImageResolveService: MockLinuxImageResolveService(),
            downloadService: MockDownloadService(),
            fileSystem: fileSystem
        )
        let library = VMLibrary(
            storageService: storage,
            snapshotStore: snapshots,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: MockVmnetNetworkProvider(),
            isVMNetworkingEntitled: true,
            usbPairingStore: MockUSBAccessoryPairingStore()
        )
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storage,
            snapshotStore: snapshots,
            diskImageService: MockDiskImageService(),
            fileSystem: fileSystem,
            preferences: preferences
        )
        let pairingCoordinator = USBAccessoryCoordinator(
            lifecycle: lifecycle, roster: library, pairings: library)
        core.onUserAttachedAccessory = { [weak pairingCoordinator] instance, accessory in
            pairingCoordinator?.userAttached(accessory, to: instance)
        }
        core.onUserReleasedAccessory = { [weak pairingCoordinator] instance, accessory in
            pairingCoordinator?.userReleased(accessory, from: instance)
        }
        return Harness(
            core: core, library: library, lifecycle: lifecycle, storage: storage,
            accessories: accessories, pairingCoordinator: pairingCoordinator)
    }

    /// A VM with a live session an accessory can be attached to.
    @discardableResult
    private func makeRunningInstance(in harness: Harness, name: String = "Core VM") -> VMInstance {
        let instance = RegisteredVMInstanceFixture.register(
            name: name, phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, storage: harness.storage, preferences: preferences)
        instance.beginSessionContext()
        return instance
    }

    private func makeStoppedInstance(in harness: Harness, name: String = "Core VM") -> VMInstance {
        RegisteredVMInstanceFixture.register(
            name: name, phase: .stopped, guestOS: .linux, library: harness.library,
            storage: harness.storage, preferences: preferences)
    }

    private func commandError(_ body: () async throws -> Void) async -> CommandError? {
        do {
            try await body()
            return nil
        } catch let error as CommandError {
            return error
        } catch {
            return nil
        }
    }

    /// Attaches `accessory` to `instance` and answers the attachment's
    /// identifier — the setup every detach and every listing assertion needs.
    private func attach(
        _ accessory: USBAccessoryInfo, to instance: VMInstance, in harness: Harness
    ) async throws -> UUID {
        let service = try #require(harness.accessories)
        service.accessories.append(accessory)
        let deviceID = UUID()
        service.nextDeviceID = deviceID
        try await harness.core.attachUSBAccessory(
            .id(instance.id), accessory: accessory.registryID)
        return deviceID
    }

    // MARK: - Capability

    @Test("Every verb refuses in a build that cannot pass accessories through")
    func everyVerbRefusesWithoutTheCapability() async throws {
        let harness = makeHarness(withAccessorySupport: false)
        let instance = makeRunningInstance(in: harness)

        let listing = await commandError {
            _ = try harness.core.usbAccessories(of: .id(instance.id))
        }
        let available = await commandError { _ = try harness.core.availableUSBAccessories() }
        let edit = await commandError {
            try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 42)
        }

        // The cause is the build — the OS version, or a signature without the
        // entitlement — and none of the three refusals may describe a VM as
        // the thing that cannot do it.
        #expect(listing == unsupportedByBuild)
        #expect(edit == unsupportedByBuild)
        #expect(available == unsupportedByBuild)
        #expect(available?.message == "This build of Kernova does not support USB accessory passthrough.")
    }

    @Test("An accessory macOS has not assigned to Kernova is a miss, not a failed attach")
    func attachingAnUnassignedAccessoryIsRefusedAsAMiss() async throws {
        let harness = makeHarness()
        let service = try #require(harness.accessories)
        let instance = makeRunningInstance(in: harness)
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 7))

        let refusal = try #require(
            await commandError {
                try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 42)
            })

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

    @Test("The available listing leaves out what another guest is already holding")
    func availableListingExcludesHeldAccessories() async throws {
        let harness = makeHarness()
        let service = try #require(harness.accessories)
        let holder = makeRunningInstance(in: harness, name: "Holder")
        makeRunningInstance(in: harness, name: "Bystander")
        let free = MockUSBAccessoryService.accessory(registryID: 1)
        service.accessories.append(free)
        _ = try await attach(
            MockUSBAccessoryService.accessory(registryID: 2), to: holder, in: harness)

        let available = try harness.core.availableUSBAccessories()

        // Held exclusively by the one guest, so it is not on offer to the
        // other — and it carries no attachment identifier here either.
        #expect(available.map(\.registryID) == [free.registryID])
        #expect(available.first?.deviceID == nil)
    }

    @Test("A VM holding nothing lists nothing, and refuses no listing for it")
    func guestListingIsEmptyWithoutAttachments() throws {
        let harness = makeHarness()
        let stopped = makeStoppedInstance(in: harness)

        #expect(try harness.core.usbAccessories(of: .id(stopped.id)).isEmpty)
    }

    // MARK: - Selectors

    @Test("A selector no VM answers to refuses before anything is asked of the guest")
    func unresolvedSelectorRefuses() async throws {
        let harness = makeHarness()
        makeRunningInstance(in: harness, name: "Twin")
        makeRunningInstance(in: harness, name: "Twin")

        let missingListing = await commandError {
            _ = try harness.core.usbAccessories(of: .name("Nobody"))
        }
        let missingEdit = await commandError {
            try await harness.core.detachUSBAccessory(.name("Nobody"), device: UUID())
        }
        #expect(missingListing?.isNotFound == true)
        #expect(missingEdit?.isNotFound == true)

        let ambiguous = await commandError {
            _ = try harness.core.usbAccessories(of: .name("Twin"))
        }
        guard case .ambiguous(_, let candidates) = try #require(ambiguous) else {
            Issue.record("expected an ambiguous refusal")
            return
        }
        #expect(candidates.count == 2)
    }

    // MARK: - Edits

    @Test("Attaching hands the accessory to the live session and records the attachment")
    func attachRecordsTheAttachment() async throws {
        let harness = makeHarness()
        let service = try #require(harness.accessories)
        let instance = makeRunningInstance(in: harness)
        let accessory = MockUSBAccessoryService.accessory(registryID: 7)

        let deviceID = try await attach(accessory, to: instance, in: harness)

        #expect(service.attachedRegistryIDs == [7])
        #expect(instance.liveUSBAccessories.map(\.deviceID) == [deviceID])
        #expect(instance.liveUSBAccessories.first?.accessory == accessory)
    }

    @Test("Detaching gives the accessory back and drops the attachment")
    func detachDropsTheAttachment() async throws {
        let harness = makeHarness()
        let service = try #require(harness.accessories)
        let instance = makeRunningInstance(in: harness)
        let accessory = MockUSBAccessoryService.accessory(registryID: 7)
        let deviceID = try await attach(accessory, to: instance, in: harness)

        try await harness.core.detachUSBAccessory(.id(instance.id), device: deviceID)

        #expect(service.detachedDeviceIDs == [deviceID])
        #expect(instance.liveUSBAccessories.isEmpty)
        #expect(try harness.core.availableUSBAccessories().map(\.registryID) == [7])
    }

    @Test("Only a guest that is already running takes an accessory edit")
    func editNeedsALiveGuest() async throws {
        for phase: VMLifecyclePhase in [.stopped, .suspended, .starting(sessionID: UUID())] {
            let harness = makeHarness()
            let service = try #require(harness.accessories)
            service.accessories.append(MockUSBAccessoryService.accessory(registryID: 7))
            let instance = RegisteredVMInstanceFixture.register(
                name: "Core VM", phase: phase, guestOS: .linux, library: harness.library,
                storage: harness.storage, preferences: preferences)

            let refusal = await commandError {
                try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 7)
            }

            #expect(refusal?.isInvalidState == true, "\(phase)")
            #expect(service.attachedRegistryIDs.isEmpty, "\(phase)")
        }
    }

    // MARK: - Failures

    @Test("A failed attach is refused in the vocabulary its cause names")
    func attachFailuresMapOntoTheCommandVocabulary() async throws {
        let cases: [(USBAccessoryError, (CommandError) -> Bool)] = [
            // The guest went away between the state gate and the controller.
            (.noVirtualMachine, \.isInvalidState),
            // A VM configured without a USB controller cannot hold one, which
            // is the same answer a build without the capability gives.
            (.noUSBController, { $0 == .unsupported(capability: "USB accessory passthrough") }),
            (.accessoryNotFound, \.isOperationFailure),
            (.deviceNotFound, \.isOperationFailure),
        ]

        for (thrown, matches) in cases {
            let harness = makeHarness()
            let service = try #require(harness.accessories)
            let instance = makeRunningInstance(in: harness)
            service.accessories.append(MockUSBAccessoryService.accessory(registryID: 7))
            service.attachError = thrown

            let thrownRefusal = await commandError {
                try await harness.core.attachUSBAccessory(.id(instance.id), accessory: 7)
            }
            let refusal = try #require(thrownRefusal)

            #expect(matches(refusal), "\(thrown)")
            #expect(instance.liveUSBAccessories.isEmpty, "\(thrown)")
        }
    }

    @Test("A detach of a device the guest no longer holds succeeds and clears the entry")
    func detachOfAnAlreadyGoneDeviceSucceeds() async throws {
        let harness = makeHarness()
        let service = try #require(harness.accessories)
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
        let service = try #require(harness.accessories)
        let instance = makeRunningInstance(in: harness)
        _ = try await attach(
            MockUSBAccessoryService.accessory(registryID: 11), to: instance, in: harness)
        let stranger = UUID()

        let refusal = try #require(
            await commandError {
                try await harness.core.detachUSBAccessory(.id(instance.id), device: stranger)
            })

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
        let service = try #require(harness.accessories)
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

    @Test("A lone accessory keeps its plain name")
    func aLoneAccessoryIsNotQualified() async throws {
        let harness = makeHarness()
        let service = try #require(harness.accessories)
        service.accessories.append(
            MockUSBAccessoryService.accessory(
                registryID: 1, serial: "AAA", receptacle: "hub/Port-USB-C@2", vendorName: "Samsung",
                productName: "Type-C"))

        #expect(try harness.core.availableUSBAccessories().map(\.name) == ["Samsung Type-C"])
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
        let service = try #require(harness.accessories)
        let instance = makeRunningInstance(in: harness)
        let deviceID = try await attach(
            MockUSBAccessoryService.accessory(registryID: 12), to: instance, in: harness)
        service.detachError = USBAccessoryError.accessoryNotFound

        let thrownRefusal = await commandError {
            try await harness.core.detachUSBAccessory(.id(instance.id), device: deviceID)
        }
        let refusal = try #require(thrownRefusal)

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

        let refusal = await commandError {
            try await harness.core.attachUSBAccessory(.id(other.id), accessory: 5)
        }

        // A guest captures an accessory exclusively, so the second attach could
        // otherwise only fail inside VZ.
        #expect(refusal?.isOperationFailure == true)
        #expect(other.liveUSBAccessories.isEmpty)
        #expect(holder.liveUSBAccessories.count == 1)
    }

    // MARK: - What the Edits Remember

    @Test("Attaching remembers the accessory for that virtual machine")
    func attachRecordsThePairing() async throws {
        let harness = makeHarness()
        let instance = makeRunningInstance(in: harness)
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 7, serial: "0373", receptacle: "hub/Port-A@1", vendorName: "Samsung",
            productName: "Type-C")

        _ = try await attach(accessory, to: instance, in: harness)

        // Placing a device is the answer to "which VM", whichever surface asked
        // — so a user who attaches from the menu with nothing else running is
        // remembered too.
        #expect(instance.usbPairings.pairings.map(\.key) == [accessory.identity?.key])
        #expect(instance.usbPairings.pairings.first?.displayName == "Samsung Type-C")
        #expect(instance.usbPairings.pairings.first?.form == .serialNumber)
    }

    @Test("An accessory with no durable identity is remembered by nothing")
    func attachOfAnUnidentifiableAccessoryRemembersNothing() async throws {
        let harness = makeHarness()
        let instance = makeRunningInstance(in: harness)

        _ = try await attach(
            MockUSBAccessoryService.accessory(registryID: 7), to: instance, in: harness)

        #expect(instance.usbPairings.isEmpty)
    }

    @Test("Attaching on a second guest takes the rule off the first")
    func attachElsewhereRewritesTheRule() async throws {
        let harness = makeHarness()
        let first = makeRunningInstance(in: harness, name: "First")
        let second = makeRunningInstance(in: harness, name: "Second")
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 7, serial: "0373", receptacle: "hub/Port-A@1")
        let deviceID = try await attach(accessory, to: first, in: harness)
        try await harness.core.detachUSBAccessory(.id(first.id), device: deviceID)

        _ = try await attach(accessory, to: second, in: harness)

        // One key names at most one VM, so a device moved between guests cannot
        // leave both of them expecting it.
        #expect(first.usbPairings.isEmpty)
        #expect(second.usbPairings.pairings.map(\.key) == [accessory.identity?.key])
    }

    @Test("A detach the user asked for forgets the rule")
    func detachForgetsThePairing() async throws {
        let harness = makeHarness()
        let instance = makeRunningInstance(in: harness)
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 7, serial: "0373", receptacle: "hub/Port-A@1")
        let deviceID = try await attach(accessory, to: instance, in: harness)
        #expect(!instance.usbPairings.isEmpty)

        try await harness.core.detachUSBAccessory(.id(instance.id), device: deviceID)

        // Taking a device back by hand is how a user ends a pairing without
        // opening settings — and the only way the returning device stays with
        // the Mac.
        #expect(instance.usbPairings.isEmpty)
    }

    @Test("A detach the lifecycle performs on its own leaves the rule alone")
    func alifecycleEjectKeepsThePairing() async throws {
        let harness = makeHarness()
        let instance = makeRunningInstance(in: harness)
        let sessionID = try #require(instance.attachableSessionID)
        let accessory = MockUSBAccessoryService.accessory(
            registryID: 7, serial: "0373", receptacle: "hub/Port-A@1")
        let deviceID = try await attach(accessory, to: instance, in: harness)

        // A stop, a suspend and a snapshot capture all take passthrough devices
        // off without the user asking, and none of them is a decision about
        // where the accessory belongs.
        try await harness.lifecycle.detachUSBAccessory(
            deviceID: deviceID, from: instance, for: sessionID)

        #expect(instance.usbPairings.pairings.map(\.key) == [accessory.identity?.key])
    }
}

extension CommandError {
    fileprivate var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    fileprivate var isItemNotFound: Bool {
        if case .itemNotFound = self { return true }
        return false
    }

    fileprivate var isInvalidState: Bool {
        if case .invalidState = self { return true }
        return false
    }
}
