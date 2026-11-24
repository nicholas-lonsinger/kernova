import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The shared-directory and USB accessory half of the App Intents surface:
/// which share, accessory or remembered accessory a pick names when its action
/// runs.
///
/// Driven through the gateway rather than through the intents, which resolve
/// their `@Dependency` only inside a live intent session.
@Suite("VM Sharing Intent Tests", .serialized, .caseScoped)
@MainActor
struct VMSharingIntentTests {
    private let preferences = makeTestPreferences()

    private func makeHarness() -> WiredCommandCore {
        WiredCommandCore(
            usbAccessoryPassthrough: .available(MockUSBAccessoryService()), preferences: preferences)
    }

    private func makeGateway(_ wired: WiredCommandCore) -> VMIntentGateway {
        VMIntentGateway(
            commands: wired.core, readiness: LibraryReadiness(awaitReady: {}),
            index: MockVMEntityIndex(), record: makeTestIndexRecord())
    }

    /// A VM with a live session an accessory can be attached to.
    private func makeRunningInstance(in harness: WiredCommandCore) -> VMInstance {
        let instance = RegisteredVMInstanceFixture.register(
            name: "Guest", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences)
        instance.beginSessionContextForTesting()
        return instance
    }

    @Test("A pick from another VM's list is refused, though the VM the action names lists the same item")
    func pickFromAnotherVMIsRefused() async throws {
        let harness = makeHarness()
        let folder = "/Users/somebody/Projects"
        let picked = harness.register(name: "Picked") { $0.sharedDirectories = [SharedDirectory(path: folder)] }
        let named = harness.register(name: "Named") { $0.sharedDirectories = [SharedDirectory(path: folder)] }
        // Remembered by the VM the action names, as a pairing that moved there
        // after the pick was made.
        let pairing = USBAccessoryPairing(
            key: "0403:6001:0100:0373", form: .serialNumber, displayName: "Drive", receptacleLabel: nil)
        try named.activity.edit(.pairingRules) { try harness.library.pairUSBAccessory(pairing, $0) }
        let gateway = makeGateway(harness)

        await #expect(throws: CommandError.self) {
            try await gateway.removeSharedDirectory(
                named.id, directory: SharedDirectoryEntityID(vm: picked.id, path: folder))
        }
        await #expect(throws: CommandError.self) {
            try await gateway.forgetUSBAccessory(
                named.id, accessory: RememberedUSBAccessoryEntityID(vm: picked.id, key: pairing.key))
        }
        #expect(named.configuration.sharedDirectories?.map(\.path) == [folder])
        #expect(named.usbPairings.pairing(forKey: pairing.key) != nil)

        // The same items, picked from the VM the action names.
        try await gateway.removeSharedDirectory(
            named.id, directory: SharedDirectoryEntityID(vm: named.id, path: folder))
        try await gateway.forgetUSBAccessory(
            named.id, accessory: RememberedUSBAccessoryEntityID(vm: named.id, key: pairing.key))
        #expect((named.configuration.sharedDirectories ?? []).isEmpty)
        #expect(named.usbPairings.isEmpty)
        #expect(picked.configuration.sharedDirectories?.map(\.path) == [folder])
    }

    @Test("An accessory pick names the same unit after a replug, and a pick from another run of Kernova names nothing")
    func accessoryPickOutlivesAReplugButNotTheRun() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let vm = makeRunningInstance(in: harness)
        service.accessories = [
            MockUSBAccessoryService.accessory(registryID: 7, serial: "0373", receptacle: "hub/Port-A@1")
        ]
        let gateway = makeGateway(harness)
        let picked = try #require(try await gateway.availableUSBAccessories().first)

        // Unplugged and plugged back in: the same unit, under a new registry ID.
        service.accessories = [
            MockUSBAccessoryService.accessory(registryID: 8, serial: "0373", receptacle: "hub/Port-A@1")
        ]
        try await gateway.attachUSBAccessory(vm.id, accessory: picked.id, named: picked.name)
        #expect(service.attachedRegistryIDs == [8])

        // An accessory nothing durable names, under the registry ID a pick from
        // another run of Kernova holds.
        service.accessories.append(MockUSBAccessoryService.accessory(registryID: 9))
        await #expect(throws: CommandError.self) {
            try await gateway.attachUSBAccessory(vm.id, accessory: .registryID(9, run: UUID()), named: "Drive")
        }
        #expect(service.attachedRegistryIDs == [8])

        // Picked in this run, it is named by that ID.
        let listed = try #require(try await gateway.availableUSBAccessories().first)
        try await gateway.attachUSBAccessory(vm.id, accessory: listed.id, named: listed.name)
        #expect(service.attachedRegistryIDs == [8, 9])
    }

    @Test("A pick known only by its port is refused while another unit of its model is connected")
    func portKeyedPickIsRefusedBesideAnotherUnitOfItsModel() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let vm = makeRunningInstance(in: harness)
        let inPortA = MockUSBAccessoryService.accessory(registryID: 7, receptacle: "hub/Port-A@1")
        let inPortB = MockUSBAccessoryService.accessory(registryID: 8, receptacle: "hub/Port-B@1")
        let portA = try #require(inPortA.identity?.key)
        service.accessories = [inPortA, inPortB]
        let gateway = makeGateway(harness)

        await #expect(throws: CommandError.self) {
            try await gateway.attachUSBAccessory(vm.id, accessory: .key(portA), named: "Drive")
        }
        #expect(service.attachedRegistryIDs.isEmpty)

        // Alone of its model, the unit in the port is the one the key names.
        service.accessories = [inPortA]
        try await gateway.attachUSBAccessory(vm.id, accessory: .key(portA), named: "Drive")
        #expect(service.attachedRegistryIDs == [7])

        // A second unit of the model, held by the same guest.
        service.accessories = [inPortA, inPortB]
        try await harness.core.attachUSBAccessory(.id(vm.id), accessory: inPortB.registryID)
        await #expect(throws: CommandError.self) {
            try await gateway.detachUSBAccessory(vm.id, accessory: .key(portA), named: "Drive")
        }
        #expect(service.detachedDeviceIDs.isEmpty)
    }

    @Test("Detach takes back the accessory the pick names, of two the guest holds")
    func detachTakesBackThePickedAccessory() async throws {
        let harness = makeHarness()
        let service = try #require(harness.usbAccessories)
        let vm = makeRunningInstance(in: harness)
        let first = MockUSBAccessoryService.accessory(registryID: 7, serial: "AAAA", receptacle: "hub/Port-A@1")
        let second = MockUSBAccessoryService.accessory(registryID: 8, serial: "BBBB", receptacle: "hub/Port-B@1")
        service.accessories = [first, second]
        let firstDevice = UUID()
        let secondDevice = UUID()
        service.nextDeviceID = firstDevice
        try await harness.core.attachUSBAccessory(.id(vm.id), accessory: first.registryID)
        service.nextDeviceID = secondDevice
        try await harness.core.attachUSBAccessory(.id(vm.id), accessory: second.registryID)
        let gateway = makeGateway(harness)
        let secondKey = try #require(second.identity?.key)
        let picked = try #require(
            try await gateway.usbAccessories(attachedTo: vm.id).first { $0.id == .key(secondKey) })

        try await gateway.detachUSBAccessory(vm.id, accessory: picked.id, named: picked.name)

        #expect(service.detachedDeviceIDs == [secondDevice])
    }
}
