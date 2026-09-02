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

    // MARK: - The Reserved Address

    @Test("Each configuration shape resolves to the one answer every surface states")
    func reservedAddressAnswersEachConfigurationShape() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:01": "192.168.64.3"]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let base = makeInstance().configuration

        #expect(registry.reservedAddress(for: shared(base, mac: "aa:bb:cc:dd:ee:01")) == .reserved("192.168.64.3"))
        #expect(registry.reservedAddress(for: shared(base, mac: "aa:bb:cc:dd:ee:02")) == .pending)
        #expect(registry.reservedAddress(for: shared(base, mac: nil)) == .unavailable)

        var bridged = shared(base, mac: "aa:bb:cc:dd:ee:01")
        bridged.networkMode = .bridged
        #expect(registry.reservedAddress(for: bridged) == .externallyAssigned)

        var off = shared(base, mac: "aa:bb:cc:dd:ee:01")
        off.networkEnabled = false
        #expect(registry.reservedAddress(for: off) == .unavailable)
    }

    @Test("An unentitled build states no address but still hands bridged to the network")
    func reservedAddressIsUnavailableUnentitled() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedAddresses = ["aa:bb:cc:dd:ee:01": "192.168.64.3"]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet, isVMNetworkingEntitled: false)
        let base = makeInstance().configuration

        #expect(registry.reservedAddress(for: shared(base, mac: "aa:bb:cc:dd:ee:01")) == .unavailable)

        var bridged = shared(base, mac: "aa:bb:cc:dd:ee:01")
        bridged.networkMode = .bridged
        #expect(registry.reservedAddress(for: bridged) == .externallyAssigned)
    }

    // MARK: - Learning a Network's Addressing

    @Test("Claiming a slot on a network with no addressing materializes that kind, once")
    func claimingASlotLearnsTheAddressingOnce() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let config = shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:01")

        registry.claimSlots(for: config)
        // A second claim while the first is in flight rides the same learn.
        registry.claimSlots(for: shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:02"))
        await registry.addressingLearnTaskForTesting(.shared)?.value

        #expect(vmnet.materializeRequestedKinds == [.shared])

        // And once it has landed, nothing asks again — the addressing is known.
        registry.claimSlots(for: shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:03"))
        #expect(registry.addressingLearnTaskForTesting(.shared) == nil)
        #expect(vmnet.materializeCount == 1)
    }

    @Test("A network whose addressing is already known is not materialized to learn it")
    func aKnownAddressingIsNotRelearned() {
        let vmnet = MockVmnetNetworkProvider()
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)

        registry.claimSlots(for: shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:01"))

        #expect(vmnet.materializeCount == 0)
        #expect(registry.addressingLearnTaskForTesting(.shared) == nil)
    }

    @Test("A failed learn is retried at the next slot sync")
    func aFailedLearnRetriesAtTheNextSync() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        vmnet.materializeFails = true
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)

        registry.claimSlots(for: shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:01"))
        await registry.addressingLearnTaskForTesting(.shared)?.value
        #expect(vmnet.materializeCount == 1)

        vmnet.materializeFails = false
        registry.claimSlots(for: shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:02"))
        await registry.addressingLearnTaskForTesting(.shared)?.value

        #expect(vmnet.materializeCount == 2)
        #expect(vmnet.knownAddressingKinds.contains(.shared))
    }

    @Test("An unentitled build learns nothing — it materializes no network to learn from")
    func anUnentitledBuildLearnsNoAddressing() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet, isVMNetworkingEntitled: false)

        registry.claimSlots(for: shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:01"))

        #expect(registry.addressingLearnTaskForTesting(.shared) == nil)
        #expect(vmnet.materializeCount == 0)
    }

    @Test("A learn landing on a network that installed nothing recreates it there and then")
    func aLearnRecreatesANetworkLeftPending() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        // The materialized network carries none of what it should — the state a
        // re-grabbed subnet, or a spent attempt limit, leaves behind.
        vmnet.scriptedPendingKinds = [.shared]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        roster.instances = []

        registry.claimSlots(for: shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:01"))
        #expect(vmnet.invalidatedKinds.isEmpty)
        await registry.addressingLearnTaskForTesting(.shared)?.value

        // Without this the address waits on an unrelated event to arrive.
        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("A learned addressing, and an invalidation, each tell a reader to ask again")
    func readersAreToldWhenTheAnswerCanMove() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        roster.instances = []

        registry.claimSlots(for: shared(makeInstance().configuration, mac: "aa:bb:cc:dd:ee:01"))
        let beforeLearn = registry.addressingGeneration
        await registry.addressingLearnTaskForTesting(.shared)?.value
        #expect(registry.addressingGeneration > beforeLearn)

        // An invalidation drops the network that contradicted a slot taken
        // after its creation, so the address it withheld derives now.
        let beforeRecreate = registry.addressingGeneration
        vmnet.scriptedPendingKinds = [.shared]
        registry.rebuildNetworksIfIdle()
        #expect(vmnet.invalidatedKinds == [.shared])
        #expect(registry.addressingGeneration > beforeRecreate)
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

    // MARK: - Network Recreation

    /// A running VM whose coordinator mirrors a live attachment on `kind` —
    /// what ``VMInstance/mayHoldAttachment(on:)`` reads as a holder.
    private func makeHolder(named name: String, on kind: VmnetNetworkKind) -> VMInstance {
        let instance = makeInstance(name: name)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = kind == .hostOnly ? .hostOnly : .shared
        instance.enter(.running(sessionID: UUID()))
        attachNetworkCoordinator(
            to: instance,
            device: MockNetworkDeviceControl(plan: kind == .hostOnly ? .hostOnly : .sharedVmnet),
            isVMNetworkingEntitled: kind == .shared)
        return instance
    }

    /// A running Host Only VM whose device refuses every attach, so activating
    /// its coordinator burns the ladder out and publishes the suspicion.
    ///
    /// `vmnet.materializeFails` is set here so the materialization ladder ends
    /// rather than re-driving a device that will never accept the plan.
    private func makeHostOnlyReporter(
        named name: String, vmnet: MockVmnetNetworkProvider
    ) -> (VMInstance, MockNetworkDeviceControl, NetworkAttachmentCoordinator) {
        let instance = makeInstance(name: name)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .hostOnly
        instance.enter(.running(sessionID: UUID()))
        let device = MockNetworkDeviceControl()
        device.refusedPlans = [.hostOnly]
        vmnet.materializeFails = true
        let coordinator = attachNetworkCoordinator(
            to: instance, device: device, vmnetNetworks: vmnet)
        return (instance, device, coordinator)
    }

    @Test("A sibling holding the network refuses the recreate a suspicion asks for")
    func aHolderRefusesTheDefectRecreate() async {
        let vmnet = MockVmnetNetworkProvider()
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let holder = makeHolder(named: "Holder", on: .hostOnly)
        let (reporter, _, coordinator) = makeHostOnlyReporter(named: "Reporter", vmnet: vmnet)
        roster.instances = [holder, reporter]
        coordinator.activate()
        #expect(reporter.suspectsDefectiveNetwork(on: .hostOnly))

        registry.rebuildNetworksIfIdle()

        // One VM's local failure must not pull the network out from under a
        // healthy sibling.
        #expect(vmnet.invalidatedKinds.isEmpty)
        await coordinator.vmnetMaterializationTaskForTesting?.value
        coordinator.stop()
    }

    @Test("The same suspicion recreates the network once the holder is gone")
    func theRefusedDefectRecreateLandsOnceTheHolderGoes() async {
        let vmnet = MockVmnetNetworkProvider()
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let holder = makeHolder(named: "Holder", on: .hostOnly)
        let (reporter, _, coordinator) = makeHostOnlyReporter(named: "Reporter", vmnet: vmnet)
        roster.instances = [holder, reporter]
        coordinator.activate()
        registry.rebuildNetworksIfIdle()
        #expect(vmnet.invalidatedKinds.isEmpty)

        // Nothing was queued: the claim still stands on the reporter, so the
        // next pass re-derives it.
        holder.tearDownSession(restingAt: .stopped)
        registry.rebuildNetworksIfIdle()

        #expect(vmnet.invalidatedKinds == [.hostOnly])
        await coordinator.vmnetMaterializationTaskForTesting?.value
        coordinator.stop()
    }

    @Test("A suspicion with nobody on the network recreates it and reattaches the reporter")
    func anUnheldDefectRecreatesAndNudges() async {
        let vmnet = MockVmnetNetworkProvider()
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let (reporter, device, coordinator) = makeHostOnlyReporter(named: "Reporter", vmnet: vmnet)
        roster.instances = [reporter]
        coordinator.activate()

        // The recreated network comes up healthy. The reporter's retry ladder
        // is spent, so the arbiter's nudge is its only wake-up.
        vmnet.materializeFails = false
        device.refusedPlans = []
        registry.rebuildNetworksIfIdle()
        #expect(vmnet.invalidatedKinds == [.hostOnly])
        await coordinator.vmnetMaterializationTaskForTesting?.value

        #expect(device.appliedPlans == [.hostOnly])
        #expect(!reporter.suspectsDefectiveNetwork(on: .hostOnly))
    }

    @Test("A pending declaration set recreates the network and nudges a detached session")
    func aPendingDeclarationRecreatesAndNudges() async {
        let vmnet = MockVmnetNetworkProvider()
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let (reporter, device, coordinator) = makeHostOnlyReporter(named: "Detached", vmnet: vmnet)
        roster.instances = [reporter]
        coordinator.activate()
        vmnet.scriptedPendingKinds = [.hostOnly]
        vmnet.materializeFails = false
        device.refusedPlans = []

        registry.rebuildNetworksIfIdle()

        // The nudge is not reserved for the defect path: a VM sitting detached
        // on a network that was just dropped needs it either way.
        #expect(vmnet.invalidatedKinds == [.hostOnly])
        await coordinator.vmnetMaterializationTaskForTesting?.value
        #expect(device.appliedPlans == [.hostOnly])
    }

    @Test("Nothing to install and nobody suspicious leaves the network alone")
    func anIdleNetworkWithNoReasonIsLeftAlone() {
        let vmnet = MockVmnetNetworkProvider()
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        roster.instances = [makeInstance(name: "Stopped")]

        registry.rebuildNetworksIfIdle()

        #expect(vmnet.invalidatedKinds.isEmpty)
    }

    @Test("Reports re-entering the arbitration pass settle on one recreate")
    func theArbitrationPassTerminatesUnderReentrantReports() async {
        let vmnet = MockVmnetNetworkProvider()
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let (reporter, _, coordinator) = makeHostOnlyReporter(named: "Reporter", vmnet: vmnet)
        roster.instances = [reporter]
        // The production wiring: going pending and reporting a defect both
        // re-enter the same pass, and the pass nudges back into the session.
        reporter.onNetworkArbitrationNeeded = { registry.rebuildNetworksIfIdle() }

        coordinator.activate()

        #expect(vmnet.invalidatedKinds == [.hostOnly])
        await coordinator.vmnetMaterializationTaskForTesting?.value
        coordinator.stop()
    }
}
