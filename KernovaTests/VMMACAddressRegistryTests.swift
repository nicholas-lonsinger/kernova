import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMMACAddressRegistry Tests", .serialized, .admissionGated)
@MainActor
struct VMMACAddressRegistryTests {
    /// What the registry asked a user to be told, in place of a presenter.
    private let failures = MockLibraryFailureSink()
    /// The library the registry reads through. Held by the suite because the
    /// registry's reference is weak — the real one is owned by its library.
    private let roster = StubVMInstanceRoster()

    private func makeRegistry() -> VMMACAddressRegistry {
        let registry = VMMACAddressRegistry(
            guestAddresses: GuestAddressObserver(
                reader: ScriptedARPTable(), vmnetNetworks: MockVmnetNetworkProvider(),
                canObserve: true, isVMNetworkingEntitled: true))
        registry.roster = roster
        registry.onFailure = { [failures] title, message in
            failures.record(title: title, message: message)
        }
        return registry
    }

    /// A shared-network configuration on `mac`.
    private func shared(_ base: VMConfiguration, mac: String?) -> VMConfiguration {
        var config = base
        config.networkEnabled = true
        config.networkMode = .shared
        config.macAddress = mac
        return config
    }

    private static let before = HeldSnapshot(name: "Before", isEphemeralBaseline: false)
    private static let after = HeldSnapshot(name: "After", isEphemeralBaseline: false)

    /// A VM on the shared network at `mac`, holding `snapshots`.
    private func makeVM(
        _ name: String, mac: String?, snapshots: [VMSnapshot] = [],
        _ mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(name: name) {
            $0 = shared($0, mac: mac)
            mutate(&$0)
        }
        instance.snapshotManifest = VMSnapshotManifest(snapshots: snapshots)
        return instance
    }

    @Test("An edit onto an address another VM holds is refused")
    func refuseMACAddressConflictRefusesADuplicateAddress() {
        let registry = makeRegistry()
        let holder = makeVM("Twin", mac: "aa:bb:cc:dd:ee:01")
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [holder, instance]

        let old = instance.configuration
        let new = shared(old, mac: "AA:BB:CC:DD:EE:01")

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) != nil)
        #expect(failures.errorTitle == "MAC Address In Use")
        #expect(failures.errorMessage?.contains("Twin") == true)
        // The address as the edit spelled it, so the refusal names what was
        // just typed rather than the holder's own spelling of it.
        #expect(failures.errorMessage?.contains("AA:BB:CC:DD:EE:01") == true)
    }

    @Test("An edit onto an address nobody else holds is admitted")
    func refuseMACAddressConflictAdmitsAUniqueAddress() {
        let registry = makeRegistry()
        let instance = VMInstanceFixture.make()
        roster.instances = [instance]

        let old = instance.configuration
        let new = shared(old, mac: "aa:bb:cc:dd:ee:01")

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == nil)
        #expect(failures.showError == false)
    }

    @Test("An edit onto an address another VM's snapshot was taken with is refused, naming it")
    func refuseMACAddressConflictRefusesASnapshotsAddress() {
        let registry = makeRegistry()
        let holder = makeVM(
            "Twin", mac: "aa:bb:cc:dd:ee:02",
            snapshots: [VMSnapshot(name: "Before", macAddress: "aa:bb:cc:dd:ee:01")])
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [holder, instance]

        let old = instance.configuration
        let new = shared(old, mac: "aa:bb:cc:dd:ee:01")

        let conflict = registry.macAddressConflict(on: instance, movingFrom: old, to: new)
        #expect(conflict?.other === holder)
        #expect(
            conflict?.reason
                == .macAddressInUse(
                    address: "aa:bb:cc:dd:ee:01", holding: .snapshots(HeldSnapshots(Self.before)),
                    otherHolders: []))
        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) != nil)
        #expect(failures.errorMessage?.contains("\u{201C}Before\u{201D}") == true)
    }

    @Test("A holder that uses an address and took snapshots with it is named for both")
    func macAddressConflictNamesTheConfigurationAndItsSnapshots() {
        let registry = makeRegistry()
        let holder = makeVM(
            "Twin", mac: "aa:bb:cc:dd:ee:01",
            snapshots: [
                VMSnapshot(name: "Before", macAddress: "aa:bb:cc:dd:ee:01"),
                VMSnapshot(name: "Elsewhere", macAddress: "aa:bb:cc:dd:ee:09"),
                VMSnapshot(name: "After", macAddress: "AA:BB:CC:DD:EE:01"),
            ])
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [holder, instance]

        let old = instance.configuration
        let new = shared(old, mac: "aa:bb:cc:dd:ee:01")

        #expect(
            registry.macAddressConflict(on: instance, movingFrom: old, to: new)?.reason
                == .macAddressInUse(
                    address: "aa:bb:cc:dd:ee:01",
                    holding: .configurationAndSnapshots(HeldSnapshots(Self.before, [Self.after])),
                    otherHolders: []))
    }

    @Test("Every VM holding an address is named, each with how it holds it")
    func macAddressConflictNamesEveryHolder() {
        let registry = makeRegistry()
        let first = makeVM("First", mac: "aa:bb:cc:dd:ee:01")
        let unrelated = makeVM("Unrelated", mac: "aa:bb:cc:dd:ee:03")
        let baselineID = UUID()
        let second = makeVM(
            "Second", mac: "aa:bb:cc:dd:ee:02",
            snapshots: [VMSnapshot(id: baselineID, name: "Baseline", macAddress: "aa:bb:cc:dd:ee:01")]
        ) { $0.applyEphemeralMode(enabled: true, baseline: baselineID) }
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [first, unrelated, second, instance]

        let old = instance.configuration
        let conflict = registry.macAddressConflict(
            on: instance, movingFrom: old, to: shared(old, mac: "aa:bb:cc:dd:ee:01"))

        #expect(conflict?.other === first)
        #expect(
            conflict?.reason
                == .macAddressInUse(
                    address: "aa:bb:cc:dd:ee:01", holding: .configuration,
                    otherHolders: [
                        MACAddressHolder(
                            name: "Second",
                            holding: .snapshots(
                                HeldSnapshots(
                                    HeldSnapshot(name: "Baseline", isEphemeralBaseline: true))))
                    ]))
    }

    @Test("A VM moving back onto an address its own snapshot was taken with is admitted")
    func refuseMACAddressConflictAdmitsTheVMsOwnSnapshotAddress() {
        let registry = makeRegistry()
        let instance = makeVM(
            "Mine", mac: "aa:bb:cc:dd:ee:02",
            snapshots: [VMSnapshot(name: "Before", macAddress: "aa:bb:cc:dd:ee:01")])
        roster.instances = [instance]

        let old = instance.configuration
        let new = shared(old, mac: "aa:bb:cc:dd:ee:01")

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == nil)
        #expect(failures.showError == false)
    }

    @Test("Deleting the snapshot that holds an address releases it")
    func deletingTheSnapshotReleasesTheAddress() {
        let registry = makeRegistry()
        let snapshot = VMSnapshot(name: "Before", macAddress: "aa:bb:cc:dd:ee:01")
        let holder = makeVM("Twin", mac: "aa:bb:cc:dd:ee:02", snapshots: [snapshot])
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [holder, instance]
        let old = instance.configuration
        let new = shared(old, mac: "aa:bb:cc:dd:ee:01")
        #expect(registry.macAddressConflict(on: instance, movingFrom: old, to: new) != nil)

        holder.snapshotManifest.remove(id: snapshot.id)

        #expect(registry.macAddressConflict(on: instance, movingFrom: old, to: new) == nil)
    }

    @Test("A snapshot's address is never a live conflict")
    func liveMACAddressConflictIgnoresSnapshots() {
        let registry = makeRegistry()
        let twin = makeVM(
            "Twin", mac: "aa:bb:cc:dd:ee:02",
            snapshots: [VMSnapshot(name: "Before", macAddress: "aa:bb:cc:dd:ee:01")])
        twin.enter(.running(sessionID: UUID()))
        let instance = makeVM("Mine", mac: "aa:bb:cc:dd:ee:01")
        roster.instances = [twin, instance]

        // The running guest is on its configuration's address, not on one a
        // snapshot records.
        #expect(registry.liveMACAddressConflict(for: instance.configuration, excluding: instance) == nil)

        let sameAddress = makeVM("Same", mac: "aa:bb:cc:dd:ee:01")
        sameAddress.enter(.running(sessionID: UUID()))
        roster.instances = [twin, sameAddress, instance]
        #expect(
            registry.liveMACAddressConflict(for: instance.configuration, excluding: instance)
                === sameAddress)
    }

    @Test("The VMs named as sharing an address are those whose configuration carries it")
    func vmNamesSharingMACAddressLeavesSnapshotsOut() {
        let registry = makeRegistry()
        let snapshotHolder = makeVM(
            "Snapshotted", mac: "aa:bb:cc:dd:ee:02",
            snapshots: [VMSnapshot(name: "Before", macAddress: "aa:bb:cc:dd:ee:01")])
        let twin = makeVM("Twin", mac: "AA:BB:CC:DD:EE:01")
        let instance = makeVM("Mine", mac: "aa:bb:cc:dd:ee:01")
        roster.instances = [snapshotHolder, twin, instance]

        #expect(registry.vmNamesSharingMACAddress(with: instance) == ["Twin"])
    }

    @Test("A live mode switch onto a network an active twin holds is refused")
    func refuseMACAddressConflictRefusesALiveModeSwitch() {
        let registry = makeRegistry()
        let twin = makeVM("Twin", mac: "aa:bb:cc:dd:ee:01") { $0.networkMode = .hostOnly }
        twin.enter(.running(sessionID: UUID()))

        let instance = makeVM("Mine", mac: "aa:bb:cc:dd:ee:01")
        let old = instance.configuration
        instance.enter(.running(sessionID: UUID()))
        roster.instances = [twin, instance]

        // The address is unchanged; only the network it lands on moves.
        var new = old
        new.networkMode = .hostOnly

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) != nil)
        #expect(failures.errorTitle == "Duplicate MAC Address")
    }

    @Test("A VM already in a live conflict stays editable")
    func refuseMACAddressConflictLeavesAnExistingConflictEditable() {
        let registry = makeRegistry()
        let twin = makeVM("Twin", mac: "aa:bb:cc:dd:ee:01")
        twin.enter(.running(sessionID: UUID()))

        // Already sharing the address on the same network — reached by some
        // other route, and the user has to be able to edit their way out.
        let instance = makeVM("Mine", mac: "aa:bb:cc:dd:ee:01")
        let old = instance.configuration
        instance.enter(.running(sessionID: UUID()))
        roster.instances = [twin, instance]

        var new = old
        new.networkMode = .hostOnly

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == nil)
        #expect(failures.showError == false)
    }

    @Test("A stopped VM's mode switch onto an active twin's network is admitted")
    func refuseMACAddressConflictOnlyGuardsALiveVM() {
        let registry = makeRegistry()
        let twin = makeVM("Twin", mac: "aa:bb:cc:dd:ee:01") { $0.networkMode = .hostOnly }
        twin.enter(.running(sessionID: UUID()))

        let instance = makeVM("Mine", mac: "aa:bb:cc:dd:ee:01")
        let old = instance.configuration
        instance.enter(.stopped)
        roster.instances = [twin, instance]

        var new = old
        new.networkMode = .hostOnly

        // Nothing is attached yet — `start` is what refuses this one.
        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == nil)
        #expect(failures.showError == false)
    }
}
