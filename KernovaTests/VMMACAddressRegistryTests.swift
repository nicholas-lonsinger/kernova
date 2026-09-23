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

    @Test("An edit onto an address another VM holds is refused")
    func refuseMACAddressConflictRefusesADuplicateAddress() {
        let registry = makeRegistry()
        let holder = VMInstanceFixture.make(name: "Twin")
        holder.configuration = shared(holder.configuration, mac: "aa:bb:cc:dd:ee:01")
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [holder, instance]

        let old = instance.configuration
        let new = shared(old, mac: "AA:BB:CC:DD:EE:01")

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == true)
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

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }

    @Test("A live mode switch onto a network an active twin holds is refused")
    func refuseMACAddressConflictRefusesALiveModeSwitch() {
        let registry = makeRegistry()
        let twin = VMInstanceFixture.make(name: "Twin")
        var twinConfig = shared(twin.configuration, mac: "aa:bb:cc:dd:ee:01")
        twinConfig.networkMode = .hostOnly
        twin.configuration = twinConfig
        twin.enter(.running(sessionID: UUID()))

        let instance = VMInstanceFixture.make(name: "Mine")
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        instance.enter(.running(sessionID: UUID()))
        roster.instances = [twin, instance]

        // The address is unchanged; only the network it lands on moves.
        var new = old
        new.networkMode = .hostOnly

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == true)
        #expect(failures.errorTitle == "Duplicate MAC Address")
    }

    @Test("A VM already in a live conflict stays editable")
    func refuseMACAddressConflictLeavesAnExistingConflictEditable() {
        let registry = makeRegistry()
        let twin = VMInstanceFixture.make(name: "Twin")
        twin.configuration = shared(twin.configuration, mac: "aa:bb:cc:dd:ee:01")
        twin.enter(.running(sessionID: UUID()))

        let instance = VMInstanceFixture.make(name: "Mine")
        // Already sharing the address on the same network — reached by some
        // other route, and the user has to be able to edit their way out.
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        instance.enter(.running(sessionID: UUID()))
        roster.instances = [twin, instance]

        var new = old
        new.networkMode = .hostOnly

        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }

    @Test("A stopped VM's mode switch onto an active twin's network is admitted")
    func refuseMACAddressConflictOnlyGuardsALiveVM() {
        let registry = makeRegistry()
        let twin = VMInstanceFixture.make(name: "Twin")
        var twinConfig = shared(twin.configuration, mac: "aa:bb:cc:dd:ee:01")
        twinConfig.networkMode = .hostOnly
        twin.configuration = twinConfig
        twin.enter(.running(sessionID: UUID()))

        let instance = VMInstanceFixture.make(name: "Mine")
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        instance.enter(.stopped)
        roster.instances = [twin, instance]

        var new = old
        new.networkMode = .hostOnly

        // Nothing is attached yet — `start` is what refuses this one.
        #expect(registry.refuseMACAddressConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }
}
