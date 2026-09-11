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
    /// through.
    private let unsupported = CommandError.unsupported(capability: "USB accessory passthrough")

    /// The refusal the host-scoped listing owes, which names no virtual machine.
    private let unsupportedByBuild = CommandError.unsupportedByBuild(
        capability: "USB accessory passthrough")

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let storage: MockVMStorageService
        let accessories: MockUSBAccessoryService?
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
            isVMNetworkingEntitled: true
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
        return Harness(core: core, library: library, storage: storage, accessories: accessories)
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

        #expect(listing == unsupported)
        #expect(edit == unsupported)
        // The host-scoped read names no VM, so its refusal must not describe
        // one: "This build of Kernova does not support …", not "This virtual
        // machine does not support …".
        #expect(available == unsupportedByBuild)
        #expect(available?.message == "This build of Kernova does not support USB accessory passthrough.")
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
}

extension CommandError {
    fileprivate var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    fileprivate var isInvalidState: Bool {
        if case .invalidState = self { return true }
        return false
    }
}
