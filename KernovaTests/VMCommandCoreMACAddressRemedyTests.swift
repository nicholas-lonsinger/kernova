import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// A bring-up refused over a MAC address another active VM uses on its network
/// offers changes to the VM's network, and a request carrying one makes the
/// change, then brings the VM up.
@Suite("VMCommandCore MAC Address Remedy Tests", .serialized, .caseScoped)
@MainActor
struct VMCommandCoreMACAddressRemedyTests {
    private let preferences = makeTestPreferences()

    private struct Harness {
        let core: VMCommandCore
        let library: VMLibrary
        let virtualization: MockVirtualizationService
        let snapshots: MockVMBundleMachineFiles
    }

    private func makeHarness(entitlements: EntitlementService = .entitled) -> Harness {
        let storage = MockVMStorageService()
        let snapshots = MockVMBundleMachineFiles(files: storage.files)
        let fileSystem = MockFileSystem()
        let virtualization = MockVirtualizationService()
        let lifecycle = makeTestLifecycle(virtualization: virtualization, fileSystem: fileSystem)
        let library = makeWiredLibrary(
            storage: storage, machineFiles: snapshots, lifecycle: lifecycle,
            fileSystem: fileSystem, preferences: preferences, entitlements: entitlements)
        let core = VMCommandCore(
            library: library, lifecycle: lifecycle, storageService: storage,
            diskImageService: MockDiskImageService(), fileSystem: fileSystem,
            preferences: preferences)
        return Harness(
            core: core, library: library, virtualization: virtualization, snapshots: snapshots)
    }

    private static let sharedMAC = "02:4b:4e:56:0c:01"

    /// An active VM on `mode`'s common network at ``sharedMAC``, and a second
    /// VM in `phase` carrying the same address on the same network.
    @discardableResult
    private func makePair(
        in harness: Harness, mode: VMNetworkMode = .shared,
        phase: VMLifecyclePhase = .stopped, savedState: Bool = false,
        identity: Data? = nil
    ) throws -> (vm: VMInstance, other: VMInstance) {
        let other = RegisteredVMInstanceFixture.register(
            name: "Source", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.networkMode = mode
            $0.macAddress = Self.sharedMAC
            $0.genericMachineIdentifierData = identity
        }
        let vm = RegisteredVMInstanceFixture.register(
            name: "Clone", phase: phase, guestOS: .linux, library: harness.library,
            preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.networkMode = mode
            $0.macAddress = Self.sharedMAC
            $0.genericMachineIdentifierData = identity
        }
        if savedState { try VMInstanceFixture.writeSaveFile(for: vm) }
        return (vm, other)
    }

    private func refusal(_ body: () async throws -> Void) async -> CommandError? {
        do {
            try await body()
            return nil
        } catch let error as CommandError {
            return error
        } catch {
            Issue.record("threw \(error)")
            return nil
        }
    }

    // MARK: - Offers

    @Test("A stopped Shared VM is offered all three changes, none discarding anything")
    func stoppedSharedVMIsOfferedEveryRemedy() async throws {
        let harness = makeHarness()
        let (vm, other) = try makePair(in: harness)

        let error = try #require(
            await refusal { try await harness.core.start(.id(vm.id), recovery: false, consent: .none) })
        let prompt = try #require(error.macAddressRemedyPrompt)

        #expect(prompt.vm.id == vm.id)
        #expect(prompt.other.id == other.id)
        #expect(prompt.verb == .start)
        #expect(prompt.title == "Duplicate MAC Address")
        #expect(
            prompt.message
                == "\u{201C}Clone\u{201D} has the same MAC address as \u{201C}Source\u{201D}, which is active. "
                + "Two virtual machines with the same MAC address must not run on the same network at once. "
                + "Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network:")
        #expect(
            prompt.offers
                == [
                    MACAddressRemedyOffer(
                        remedy: .ownNetwork, title: "Move to a Network of Its Own and Start",
                        isDestructive: false),
                    MACAddressRemedyOffer(
                        remedy: .newAddress, title: "Use a New MAC Address and Start",
                        isDestructive: false),
                    MACAddressRemedyOffer(
                        remedy: .noNetwork, title: "Turn Off Networking and Start",
                        isDestructive: false),
                ])
        #expect(prompt.dismissTitle == "Cancel")
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A suspended Shared VM keeps its saved state only on a network of its own, and is told so")
    func suspendedSharedVMIsToldWhatDiscards() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .suspended, savedState: true)

        let error = try #require(
            await refusal { try await harness.core.resume(.id(vm.id), consent: .none) })
        let prompt = try #require(error.macAddressRemedyPrompt)

        #expect(
            prompt.message
                == "\u{201C}Clone\u{201D} has the same MAC address as \u{201C}Source\u{201D}, which is active. "
                + "Two virtual machines with the same MAC address must not run on the same network at once. "
                + "A saved state does not restore under a new MAC address or without its network device, "
                + "so those choices discard \u{201C}Clone\u{201D}\u{2019}s saved state; a network of its own keeps it. "
                + "Stop \u{201C}Source\u{201D}, or change \u{201C}Clone\u{201D}\u{2019}s network:")
        #expect(prompt.offers.map(\.remedy) == [.ownNetwork, .newAddress, .noNetwork])
        #expect(prompt.offers.map(\.isDestructive) == [false, true, true])
        #expect(
            prompt.offers.map(\.title) == [
                "Move to a Network of Its Own and Resume", "Use a New MAC Address and Resume",
                "Turn Off Networking and Resume",
            ])
    }

    @Test("A suspended Host Only VM is not offered a network of its own, which no restore was measured on")
    func suspendedHostOnlyVMIsNotOfferedItsOwnNetwork() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, mode: .hostOnly, phase: .suspended, savedState: true)

        let error = try #require(
            await refusal { try await harness.core.resume(.id(vm.id), consent: .none) })
        let prompt = try #require(error.macAddressRemedyPrompt)

        #expect(prompt.offers.map(\.remedy) == [.newAddress, .noNetwork])
        #expect(prompt.offers.allSatisfy { $0.isDestructive })
        #expect(
            prompt.message.contains(
                "so those choices discard \u{201C}Clone\u{201D}\u{2019}s saved state. Stop"))
    }

    @Test("A stopped Host Only VM, holding no saved state, is offered a network of its own")
    func stoppedHostOnlyVMIsOfferedItsOwnNetwork() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, mode: .hostOnly)

        let error = try #require(
            await refusal { try await harness.core.start(.id(vm.id), recovery: false, consent: .none) })

        #expect(
            error.macAddressRemedyPrompt?.offers.map(\.remedy) == [.ownNetwork, .newAddress, .noNetwork])
    }

    @Test("Bridged has no network of its own to offer")
    func bridgedVMIsNotOfferedItsOwnNetwork() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, mode: .bridged)

        let error = try #require(
            await refusal { try await harness.core.start(.id(vm.id), recovery: false, consent: .none) })

        #expect(error.macAddressRemedyPrompt?.offers.map(\.remedy) == [.newAddress, .noNetwork])
    }

    @Test("A build that cannot attach a VM's own network does not offer one")
    func unentitledBuildDoesNotOfferItsOwnNetwork() async throws {
        let harness = makeHarness(entitlements: .unentitled)
        let (vm, _) = try makePair(in: harness)

        let error = try #require(
            await refusal { try await harness.core.start(.id(vm.id), recovery: false, consent: .none) })

        #expect(error.macAddressRemedyPrompt?.offers.map(\.remedy) == [.newAddress, .noNetwork])
    }

    @Test("A bring-up nobody can be asked about is refused with no offers")
    func standingStartIsRefusedWithoutOffers() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness)

        do {
            try harness.core.startNow(vm, policy: .standing)
            Issue.record("the standing start was admitted")
        } catch let refused as VMAdmissionRefusal {
            guard case .identityConflict(let conflict) = refused.refusal else {
                Issue.record("refused as \(refused.refusal)")
                return
            }
            #expect(!conflict.asks)
            let error = harness.core.commandError(for: refused.refusal, on: vm, verb: .start)
            guard case .conflict(_, _, .macAddress) = error else {
                Issue.record("mapped to \(error)")
                return
            }
        }
    }

    // MARK: - Taking a Remedy

    @Test("A network of its own lands as the VM's membership, and the VM starts")
    func ownNetworkStarts() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness)

        try await harness.core.start(
            .id(vm.id), recovery: false, consent: .none, macAddressRemedy: .ownNetwork)

        #expect(vm.configuration.networkMembership == .isolated)
        #expect(vm.configuration.macAddress == Self.sharedMAC)
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("A new MAC address lands, and the VM starts")
    func newAddressStarts() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness)

        try await harness.core.start(
            .id(vm.id), recovery: false, consent: .none, macAddressRemedy: .newAddress)

        let address = try #require(vm.configuration.macAddress)
        #expect(address != Self.sharedMAC)
        #expect(vm.configuration.networkEnabled)
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("Networking off lands in the configuration, and the VM starts")
    func noNetworkStarts() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness)

        try await harness.core.start(
            .id(vm.id), recovery: false, consent: .none, macAddressRemedy: .noNetwork)

        #expect(!vm.configuration.networkEnabled)
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("A suspended Shared VM moved to a network of its own restores its saved state there")
    func ownNetworkKeepsTheSavedState() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .suspended, savedState: true)

        try await harness.core.resume(.id(vm.id), consent: .none, macAddressRemedy: .ownNetwork)

        #expect(vm.configuration.networkMembership == .isolated)
        #expect(harness.virtualization.lastStartRoute == .restoredSavedState)
    }

    @Test("A suspended VM taking a new MAC address discards its saved state and boots")
    func newAddressDiscardsTheSavedState() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .suspended, savedState: true)

        try await harness.core.resume(.id(vm.id), consent: .none, macAddressRemedy: .newAddress)

        #expect(vm.configuration.macAddress != Self.sharedMAC)
        #expect(harness.virtualization.lastStartRoute == .coldBoot)
    }

    @Test("A suspended Host Only VM asking for a network of its own is refused, writing nothing")
    func hostOnlySavedStateRefusesItsOwnNetwork() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, mode: .hostOnly, phase: .suspended, savedState: true)

        let error = try #require(
            await refusal {
                try await harness.core.resume(.id(vm.id), consent: .none, macAddressRemedy: .ownNetwork)
            })

        #expect(error.macAddressRemedyPrompt == nil)
        #expect(vm.configuration.networkMembership == .common)
        #expect(vm.hasSaveFile)
        #expect(harness.virtualization.startCallCount == 0)
    }

    @Test("A remedy whose bring-up meets another refusal writes nothing before that refusal")
    func anotherRefusalWritesNothing() async throws {
        let harness = makeHarness()
        preferences.allowsDuplicateMachineIDOverride = true
        let (vm, _) = try makePair(in: harness, identity: Data([3, 1, 4]))

        let error = try #require(
            await refusal {
                try await harness.core.start(
                    .id(vm.id), recovery: false, consent: .none, macAddressRemedy: .newAddress)
            })

        #expect(error.confirmationPrompt?.kind == .startBesideSharedMachineIdentity)
        #expect(vm.configuration.macAddress == Self.sharedMAC)
        #expect(harness.virtualization.startCallCount == 0)

        try await harness.core.start(
            .id(vm.id), recovery: false, consent: Consent([.startBesideSharedMachineIdentity]),
            macAddressRemedy: .newAddress)
        #expect(vm.configuration.macAddress != Self.sharedMAC)
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("A remedy given where nothing conflicts is ignored")
    func remedyWithoutConflictIsIgnored() async throws {
        let harness = makeHarness()
        let vm = RegisteredVMInstanceFixture.register(
            name: "Alone", phase: .stopped, guestOS: .linux, library: harness.library,
            preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.networkMode = .shared
            $0.macAddress = Self.sharedMAC
        }

        try await harness.core.start(
            .id(vm.id), recovery: false, consent: .none, macAddressRemedy: .noNetwork)

        #expect(vm.configuration.networkEnabled)
        #expect(vm.configuration.macAddress == Self.sharedMAC)
        #expect(harness.virtualization.startCallCount == 1)
    }

    @Test("The change stays when the bring-up after it fails")
    func remedyStaysWhenTheBringUpFails() async throws {
        let harness = makeHarness()
        harness.virtualization.startError = VirtualizationError.noVirtualMachine
        let (vm, _) = try makePair(in: harness)

        let error = try #require(
            await refusal {
                try await harness.core.start(
                    .id(vm.id), recovery: false, consent: .none, macAddressRemedy: .ownNetwork)
            })

        #expect(error.isOperationFailure)
        #expect(vm.configuration.networkMembership == .isolated)
    }

    @Test("Restart asks before the guest goes down, and takes the remedy between the power-off and the boot")
    func restartTakesTheRemedyBetweenStopAndBoot() async throws {
        let harness = makeHarness()
        let (vm, _) = try makePair(in: harness, phase: .running(sessionID: UUID()))

        let error = try #require(
            await refusal { try await harness.core.restart(.id(vm.id), timeout: nil, consent: .none) })
        let prompt = try #require(error.macAddressRemedyPrompt)
        #expect(prompt.verb == .restart)
        #expect(prompt.offers.first?.title == "Move to a Network of Its Own and Restart")
        #expect(harness.virtualization.stopCallCount == 0)

        try await harness.core.restart(
            .id(vm.id), timeout: nil, consent: .none, macAddressRemedy: .newAddress)

        #expect(harness.virtualization.stopCallCount == 1)
        #expect(harness.virtualization.configurationAtStart?.macAddress != Self.sharedMAC)
        #expect(vm.configuration.macAddress != Self.sharedMAC)
    }

    @Test("A warm revert that would resume onto a used address lands at rest, takes the remedy, then resumes")
    func revertTakesTheRemedyBeforeItsRestore() async throws {
        let harness = makeHarness()
        RegisteredVMInstanceFixture.register(
            name: "Holder", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.macAddress = Self.sharedMAC
        }
        let reverting = RegisteredVMInstanceFixture.register(
            name: "Reverting", phase: .running(sessionID: UUID()), guestOS: .linux,
            library: harness.library, preferences: preferences
        ) {
            $0.networkEnabled = true
            $0.macAddress = "02:4b:4e:56:0c:02"
        }
        let snapshot = VMSnapshot(name: "Before", kind: .warm, macAddress: Self.sharedMAC)
        reverting.seedSnapshotManifest(VMSnapshotManifest(snapshots: [snapshot]))
        var captured = reverting.configuration
        captured.macAddress = Self.sharedMAC
        harness.snapshots.setCapturedConfiguration(captured, for: snapshot.id)

        let error = try #require(
            await refusal {
                try await harness.core.revertToSnapshot(
                    .id(reverting.id), snapshot: snapshot.id, takingCheckpoint: false,
                    consent: .all)
            })
        let prompt = try #require(error.macAddressRemedyPrompt)
        #expect(prompt.verb == .revertToSnapshot)
        #expect(prompt.offers.map(\.isDestructive) == [false, true, true])
        #expect(harness.virtualization.revertedSnapshots.isEmpty)

        try await harness.core.revertToSnapshot(
            .id(reverting.id), snapshot: snapshot.id, takingCheckpoint: false, consent: .all,
            macAddressRemedy: .ownNetwork)

        #expect(harness.virtualization.revertedSnapshots.count == 1)
        #expect(reverting.configuration.networkMembership == .isolated)
        #expect(reverting.configuration.macAddress == Self.sharedMAC)
        #expect(harness.virtualization.lastStartRoute == .restoredSavedState)
    }
}
