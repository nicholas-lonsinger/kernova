import Foundation
import KernovaTestSupport
import Testing

@testable import Kernova

@Suite("VMNetworkSlotRegistry Tests", .serialized, .admissionGated)
@MainActor
struct VMNetworkSlotRegistryTests {
    /// What the registry asked a user to be told, in place of a presenter.
    private let failures = MockLibraryFailureSink()
    /// The library the registry reads through. Held by the suite because the
    /// registry's reference is weak — the real one is owned by its library.
    private let roster = StubVMInstanceRoster()

    private func makeRegistry(
        vmnetNetworks: MockVmnetNetworkProvider = MockVmnetNetworkProvider(),
        isVMNetworkingEntitled: Bool = true
    ) -> (VMNetworkSlotRegistry, MockVmnetNetworkProvider) {
        let registry = VMNetworkSlotRegistry(
            vmnetNetworks: vmnetNetworks, isVMNetworkingEntitled: isVMNetworkingEntitled)
        registry.roster = roster
        registry.onFailure = { [failures] title, message in
            failures.record(title: title, message: message)
        }
        return (registry, vmnetNetworks)
    }

    private func makeInstance(name: String = "Test VM") -> VMInstance {
        let config = VMConfiguration(name: name, guestOS: .linux, bootMode: .efi)
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(config.id.uuidString, isDirectory: true)
        return VMInstance(configuration: config, bundleURL: bundleURL)
    }

    /// A shared-network configuration on `mac`, the shape that takes a slot.
    private func shared(_ base: VMConfiguration, mac: String?) -> VMConfiguration {
        var config = base
        config.networkEnabled = true
        config.networkMode = .shared
        config.macAddress = mac
        return config
    }

    // MARK: - Address Reservation Sync

    @Test("A configuration change syncs the VM's DHCP reservation slot for its mode's network")
    func moveSlotsSyncsAddressReservation() {
        let (registry, vmnet) = makeRegistry()
        let instance = makeInstance()
        let old = instance.configuration
        let new = shared(old, mac: "AA:BB:CC:DD:EE:0F")

        registry.moveSlots(from: old, to: new)

        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
        #expect(vmnet.reservedMACs.map(\.kind) == [.shared])
    }

    @Test("A bridged or MAC-less configuration takes no reservation slot")
    func bridgedConfigurationTakesNoReservationSlot() {
        let (registry, vmnet) = makeRegistry()
        let instance = makeInstance()
        let base = instance.configuration
        var bridged = base
        bridged.networkEnabled = true
        bridged.networkMode = .bridged
        bridged.macAddress = "aa:bb:cc:dd:ee:0f"
        let macLess = shared(bridged, mac: nil)

        registry.moveSlots(from: base, to: bridged)
        registry.moveSlots(from: bridged, to: macLess)

        #expect(vmnet.reservedMACs.isEmpty)
    }

    @Test("An unentitled build takes no slot at all")
    func unentitledBuildTakesNoSlot() {
        let (registry, vmnet) = makeRegistry(isVMNetworkingEntitled: false)
        let instance = makeInstance()
        let new = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:0f")

        registry.moveSlots(from: instance.configuration, to: new)

        #expect(vmnet.reservedMACs.isEmpty)
    }

    // MARK: - moveSlots Ordering

    @Test("An edited MAC releases the retired slot before reserving the new one")
    func moveSlotsReleasesBeforeReserving() {
        let (registry, vmnet) = makeRegistry()
        let instance = makeInstance()
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        roster.instances = [instance]
        registry.claimSlots(for: old)
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:01"])

        let new = shared(old, mac: "aa:bb:cc:dd:ee:02")
        instance.configuration = new

        registry.moveSlots(from: old, to: new)

        // The release has to precede the reserve, so the freed slot is the
        // lowest available one and the VM normally keeps its address.
        #expect(vmnet.releasedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:01"])
        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:02"])
    }

    @Test("A mode switch moves the slot to the new mode's network")
    func moveSlotsFollowsAModeSwitch() {
        let (registry, vmnet) = makeRegistry()
        let instance = makeInstance()
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        roster.instances = [instance]
        registry.claimSlots(for: old)

        var new = old
        new.networkMode = .hostOnly
        instance.configuration = new

        registry.moveSlots(from: old, to: new)

        #expect(vmnet.releasedMACs.map(\.kind) == [.shared])
        #expect(vmnet.reservedMACs.map(\.kind) == [.hostOnly])
    }

    @Test("Turning networking off frees the slot and withdraws the rules")
    func moveSlotsReleasesWhenNetworkingGoesOff() {
        let (registry, vmnet) = makeRegistry()
        let instance = makeInstance()
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        roster.instances = [instance]
        registry.claimSlots(for: old)

        var new = old
        new.networkEnabled = false
        instance.configuration = new

        registry.moveSlots(from: old, to: new)

        #expect(vmnet.reservedMACs.isEmpty)
        #expect(vmnet.releasedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:01"])
        // The address is unchanged, so nothing is withdrawn under the old MAC;
        // the re-sync under the new configuration declares an empty rule set.
        #expect(vmnet.declaredForwardingRules.last?.rules.isEmpty == true)
    }

    @Test("A retired MAC stops claiming the VM's host ports")
    func moveSlotsWithdrawsTheRetiredMACsRules() {
        let (registry, vmnet) = makeRegistry()
        let instance = makeInstance()
        var old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        old.portForwardingRules = [
            PortForwardingRule(transport: .tcp, hostPort: 2222, guestPort: 22)
        ]
        instance.configuration = old
        roster.instances = [instance]
        registry.claimSlots(for: old)

        let new = shared(old, mac: "aa:bb:cc:dd:ee:02")
        instance.configuration = new

        registry.moveSlots(from: old, to: new)

        // Rules are keyed on the address: the retired one is emptied, and the
        // VM's rules are re-declared under the address it now carries.
        let withdrawn = vmnet.declaredForwardingRules.first {
            $0.mac == "aa:bb:cc:dd:ee:01" && $0.rules.isEmpty
        }
        #expect(withdrawn != nil)
        #expect(vmnet.declaredForwardingRules.last?.mac == "aa:bb:cc:dd:ee:02")
        #expect(vmnet.declaredForwardingRules.last?.rules.count == 1)
    }

    // MARK: - refuseSlotConflict

    @Test("An edit onto an address another VM holds is refused")
    func refuseSlotConflictRefusesADuplicateAddress() {
        let (registry, _) = makeRegistry()
        let holder = makeInstance(name: "Twin")
        holder.configuration = shared(holder.configuration, mac: "aa:bb:cc:dd:ee:01")
        let instance = makeInstance(name: "Mine")
        roster.instances = [holder, instance]

        let old = instance.configuration
        let new = shared(old, mac: "AA:BB:CC:DD:EE:01")

        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == true)
        #expect(failures.errorTitle == "MAC Address In Use")
        #expect(failures.errorMessage?.contains("Twin") == true)
    }

    @Test("An edit onto an address nobody else holds is admitted")
    func refuseSlotConflictAdmitsAUniqueAddress() {
        let (registry, _) = makeRegistry()
        let instance = makeInstance()
        roster.instances = [instance]

        let old = instance.configuration
        let new = shared(old, mac: "aa:bb:cc:dd:ee:01")

        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }

    @Test("A live mode switch onto a network an active twin holds is refused")
    func refuseSlotConflictRefusesALiveModeSwitch() {
        let (registry, _) = makeRegistry()
        let twin = makeInstance(name: "Twin")
        var twinConfig = shared(twin.configuration, mac: "aa:bb:cc:dd:ee:01")
        twinConfig.networkMode = .hostOnly
        twin.configuration = twinConfig
        twin.enter(.running(sessionID: UUID()))

        let instance = makeInstance(name: "Mine")
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        instance.enter(.running(sessionID: UUID()))
        roster.instances = [twin, instance]

        // The address is unchanged; only the network it lands on moves.
        var new = old
        new.networkMode = .hostOnly

        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == true)
        #expect(failures.errorTitle == "Duplicate MAC Address")
    }

    @Test("A VM already in a live conflict stays editable")
    func refuseSlotConflictLeavesAnExistingConflictEditable() {
        let (registry, _) = makeRegistry()
        let twin = makeInstance(name: "Twin")
        twin.configuration = shared(twin.configuration, mac: "aa:bb:cc:dd:ee:01")
        twin.enter(.running(sessionID: UUID()))

        let instance = makeInstance(name: "Mine")
        // Already sharing the address on the same network — reached by some
        // other route, and the user has to be able to edit their way out.
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        instance.enter(.running(sessionID: UUID()))
        roster.instances = [twin, instance]

        var new = old
        new.networkMode = .hostOnly

        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }

    @Test("A stopped VM's mode switch onto an active twin's network is admitted")
    func refuseSlotConflictOnlyGuardsALiveVM() {
        let (registry, _) = makeRegistry()
        let twin = makeInstance(name: "Twin")
        var twinConfig = shared(twin.configuration, mac: "aa:bb:cc:dd:ee:01")
        twinConfig.networkMode = .hostOnly
        twin.configuration = twinConfig
        twin.enter(.running(sessionID: UUID()))

        let instance = makeInstance(name: "Mine")
        let old = shared(instance.configuration, mac: "aa:bb:cc:dd:ee:01")
        instance.configuration = old
        instance.enter(.stopped)
        roster.instances = [twin, instance]

        var new = old
        new.networkMode = .hostOnly

        // Nothing is attached yet — `start` is what refuses this one.
        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }
}
