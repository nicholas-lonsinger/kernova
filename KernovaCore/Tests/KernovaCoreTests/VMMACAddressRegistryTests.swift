import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

@Suite("VMMACAddressRegistry Tests", .serialized, .caseScoped)
@MainActor
struct VMMACAddressRegistryTests {
    /// What a refused edit tells the user, in place of a presenter.
    private let failures = MockLibraryFailureSink()
    /// The library the registry reads through. Held by the suite because the
    /// registry's reference is weak — the real one is owned by its library.
    private let roster = StubVMInstanceRoster()

    private func makeRegistry() -> VMMACAddressRegistry {
        let registry = VMMACAddressRegistry()
        registry.roster = roster
        return registry
    }

    /// The conflict `registry` finds for the edit, recorded in `failures` in
    /// the words the refusal a write raises over it reads in.
    private func refuse(
        _ registry: VMMACAddressRegistry, on instance: VMInstance,
        movingFrom old: VMConfiguration, to new: VMConfiguration
    ) -> VMMACAddressRegistry.MACAddressConflict? {
        guard let conflict = registry.macAddressConflict(on: instance, movingFrom: old, to: new)
        else { return nil }
        let failure = CommandErrorDTO.conflict(
            vm: instance.summary(ipAddress: .unavailable),
            with: conflict.other.summary(ipAddress: .unavailable), reason: conflict.reason)
        failures.record(title: failure.title, message: failure.message, subject: .vm(instance))
        return conflict
    }

    /// A NAT configuration on `mac`.
    private func nat(_ base: VMConfiguration, mac: String?) -> VMConfiguration {
        var config = base
        config.networkEnabled = true
        config.networkMode = .nat
        config.macAddress = mac
        return config
    }

    /// A VM on NAT at `mac`, holding `snapshots`.
    private func makeVM(
        _ name: String, mac: String?, snapshots: [VMSnapshot] = [],
        hostState: VMHostState = VMHostState(),
        _ mutate: (inout VMConfiguration) -> Void = { _ in }
    ) -> VMInstance {
        let instance = VMInstanceFixture.make(name: name, hostState: hostState) {
            $0 = nat($0, mac: mac)
            mutate(&$0)
        }
        instance.seedSnapshotManifest(VMSnapshotManifest(snapshots: snapshots))
        return instance
    }

    @Test("An edit onto an address another VM holds is refused")
    func refuseMACAddressConflictRefusesADuplicateAddress() {
        let registry = makeRegistry()
        let holder = makeVM("Twin", mac: "aa:bb:cc:dd:ee:01")
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [holder, instance]

        let old = instance.configuration
        let new = nat(old, mac: "AA:BB:CC:DD:EE:01")

        #expect(refuse(registry, on: instance, movingFrom: old, to: new) != nil)
        #expect(failures.errorTitle == "MAC Address In Use")
        #expect(failures.errorMessage?.contains("Twin") == true)
        // The address as the edit spelled it, so the refusal names what was
        // just typed rather than the holder's own spelling of it.
        #expect(failures.errorMessage?.contains("AA:BB:CC:DD:EE:01") == true)
    }

    @Test("Every VM holding an address is named, each with how it holds it")
    func macAddressConflictNamesEveryHolder() {
        let registry = makeRegistry()
        let first = makeVM("First", mac: "aa:bb:cc:dd:ee:01")
        let unrelated = makeVM("Unrelated", mac: "aa:bb:cc:dd:ee:03")
        let baselineID = UUID()
        let second = makeVM(
            "Second", mac: "aa:bb:cc:dd:ee:02",
            snapshots: [VMSnapshot(id: baselineID, name: "Baseline", macAddress: "aa:bb:cc:dd:ee:01")],
            hostState: .ephemeral(baseline: baselineID))
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [first, unrelated, second, instance]

        let old = instance.configuration
        let conflict = registry.macAddressConflict(
            on: instance, movingFrom: old, to: nat(old, mac: "aa:bb:cc:dd:ee:01"))

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
        let new = nat(old, mac: "aa:bb:cc:dd:ee:01")

        #expect(refuse(registry, on: instance, movingFrom: old, to: new) == nil)
        #expect(failures.showError == false)
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

    @Test("An address is shared when more than one VM holds it, whatever their machine identities")
    func sharedMACAddressesCountHolders() {
        let registry = makeRegistry()
        let identity = Data([2, 7, 1, 8])
        let source = makeVM("Source", mac: "aa:bb:cc:dd:ee:01") {
            $0.genericMachineIdentifierData = identity
        }
        let copy = makeVM("Source Copy", mac: "AA:BB:CC:DD:EE:01") {
            $0.genericMachineIdentifierData = identity
        }
        let lone = makeVM(
            "Lone", mac: "aa:bb:cc:dd:ee:02",
            snapshots: [VMSnapshot(name: "Before", macAddress: "aa:bb:cc:dd:ee:02")])
        roster.instances = [source, copy, lone]

        let shared = registry.sharedMACAddresses()
        #expect(shared.map(\.address) == ["aa:bb:cc:dd:ee:01"])
        #expect(shared.first?.holders.map(\.vm.name) == ["Source", "Source Copy"])
        #expect(registry.vmNamesSharingMACAddress(with: copy) == ["Source"])
    }

    @Test("A VM already in a live conflict stays editable")
    func refuseMACAddressConflictLeavesAnExistingConflictEditable() {
        let registry = makeRegistry()
        let twin = makeVM("Twin", mac: "aa:bb:cc:dd:ee:01")
        twin.activity.placeForTesting(.running(sessionID: UUID()))

        // Already sharing the address on the same network — reached by some
        // other route, and the user has to be able to edit their way out.
        let instance = makeVM("Mine", mac: "aa:bb:cc:dd:ee:01")
        let old = instance.configuration
        instance.activity.placeForTesting(.running(sessionID: UUID()))
        roster.instances = [twin, instance]

        var new = old
        new.networkMode = .hostOnly

        #expect(refuse(registry, on: instance, movingFrom: old, to: new) == nil)
        #expect(failures.showError == false)
    }

    @Test("A stopped VM's mode switch onto an active twin's network is admitted")
    func refuseMACAddressConflictOnlyGuardsALiveVM() {
        let registry = makeRegistry()
        let twin = makeVM("Twin", mac: "aa:bb:cc:dd:ee:01") { $0.networkMode = .hostOnly }
        twin.activity.placeForTesting(.running(sessionID: UUID()))

        let instance = makeVM("Mine", mac: "aa:bb:cc:dd:ee:01")
        let old = instance.configuration
        instance.activity.placeForTesting(.stopped)
        roster.instances = [twin, instance]

        var new = old
        new.networkMode = .hostOnly

        // Nothing is attached yet — `start` is what refuses this one.
        #expect(refuse(registry, on: instance, movingFrom: old, to: new) == nil)
        #expect(failures.showError == false)
    }
}
