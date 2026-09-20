import Foundation
import KernovaKit
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
        let instance = VMInstanceFixture.make()
        let old = instance.configuration
        let new = shared(old, mac: "AA:BB:CC:DD:EE:0F")

        registry.moveSlots(from: old, to: new)

        #expect(vmnet.reservedMACs.map(\.mac) == ["aa:bb:cc:dd:ee:0f"])
        #expect(vmnet.reservedMACs.map(\.kind) == [.shared])
    }

    @Test("A bridged or MAC-less configuration takes no reservation slot")
    func bridgedConfigurationTakesNoReservationSlot() {
        let (registry, vmnet) = makeRegistry()
        let instance = VMInstanceFixture.make()
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
        let instance = VMInstanceFixture.make()
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
        let base = VMInstanceFixture.make().configuration

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
        let base = VMInstanceFixture.make().configuration

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
        let config = shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:01")

        registry.claimSlots(for: config)
        // A second claim while the first is in flight rides the same learn.
        registry.claimSlots(for: shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:02"))
        await registry.addressingLearnTaskForTesting(.shared)?.value

        #expect(vmnet.materializeRequestedKinds == [.shared])

        // And once it has landed, nothing asks again — the addressing is known.
        registry.claimSlots(for: shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:03"))
        #expect(registry.addressingLearnTaskForTesting(.shared) == nil)
        #expect(vmnet.materializeCount == 1)
    }

    @Test("A network whose addressing is already known is not materialized to learn it")
    func aKnownAddressingIsNotRelearned() {
        let vmnet = MockVmnetNetworkProvider()
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)

        registry.claimSlots(for: shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:01"))

        #expect(vmnet.materializeCount == 0)
        #expect(registry.addressingLearnTaskForTesting(.shared) == nil)
    }

    @Test("A failed learn is retried at the next slot sync")
    func aFailedLearnRetriesAtTheNextSync() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        vmnet.materializeFails = true
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)

        registry.claimSlots(for: shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:01"))
        await registry.addressingLearnTaskForTesting(.shared)?.value
        #expect(vmnet.materializeCount == 1)

        vmnet.materializeFails = false
        registry.claimSlots(for: shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:02"))
        await registry.addressingLearnTaskForTesting(.shared)?.value

        #expect(vmnet.materializeCount == 2)
        #expect(vmnet.knownAddressingKinds.contains(.shared))
    }

    @Test("An unentitled build learns nothing — it materializes no network to learn from")
    func anUnentitledBuildLearnsNoAddressing() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet, isVMNetworkingEntitled: false)

        registry.claimSlots(for: shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:01"))

        #expect(registry.addressingLearnTaskForTesting(.shared) == nil)
        #expect(vmnet.materializeCount == 0)
    }

    @Test("A learn landing on a network that installed nothing recreates it there and then")
    func aLearnRecreatesANetworkLeftPending() async {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.knownAddressingKinds = []
        // The materialized network carries none of what it should — the state a
        // re-grabbed subnet, or a spent attempt limit, leaves behind.
        vmnet.scriptedRecreationReasons = [.shared: .declarationsPending]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        roster.instances = []

        registry.claimSlots(for: shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:01"))
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

        registry.claimSlots(for: shared(VMInstanceFixture.make().configuration, mac: "aa:bb:cc:dd:ee:01"))
        let beforeLearn = registry.addressingGeneration
        await registry.addressingLearnTaskForTesting(.shared)?.value
        #expect(registry.addressingGeneration > beforeLearn)

        // An invalidation drops the network that contradicted a slot taken
        // after its creation, so the address it withheld derives now.
        let beforeRecreate = registry.addressingGeneration
        vmnet.scriptedRecreationReasons = [.shared: .declarationsPending]
        registry.rebuildNetworksIfIdle()
        #expect(vmnet.invalidatedKinds == [.shared])
        #expect(registry.addressingGeneration > beforeRecreate)
    }

    // MARK: - moveSlots Ordering

    @Test("An edited MAC releases the retired slot before reserving the new one")
    func moveSlotsReleasesBeforeReserving() {
        let (registry, vmnet) = makeRegistry()
        let instance = VMInstanceFixture.make()
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
        let instance = VMInstanceFixture.make()
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
        let instance = VMInstanceFixture.make()
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
        let instance = VMInstanceFixture.make()
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
        let holder = VMInstanceFixture.make(name: "Twin")
        holder.configuration = shared(holder.configuration, mac: "aa:bb:cc:dd:ee:01")
        let instance = VMInstanceFixture.make(name: "Mine")
        roster.instances = [holder, instance]

        let old = instance.configuration
        let new = shared(old, mac: "AA:BB:CC:DD:EE:01")

        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == true)
        #expect(failures.errorTitle == "MAC Address In Use")
        #expect(failures.errorMessage?.contains("Twin") == true)
        // The address as the edit spelled it, so the refusal names what was
        // just typed rather than the holder's own spelling of it.
        #expect(failures.errorMessage?.contains("AA:BB:CC:DD:EE:01") == true)
    }

    @Test("An edit onto an address nobody else holds is admitted")
    func refuseSlotConflictAdmitsAUniqueAddress() {
        let (registry, _) = makeRegistry()
        let instance = VMInstanceFixture.make()
        roster.instances = [instance]

        let old = instance.configuration
        let new = shared(old, mac: "aa:bb:cc:dd:ee:01")

        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }

    @Test("A live mode switch onto a network an active twin holds is refused")
    func refuseSlotConflictRefusesALiveModeSwitch() {
        let (registry, _) = makeRegistry()
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

        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == true)
        #expect(failures.errorTitle == "Duplicate MAC Address")
    }

    @Test("A VM already in a live conflict stays editable")
    func refuseSlotConflictLeavesAnExistingConflictEditable() {
        let (registry, _) = makeRegistry()
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

        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }

    @Test("A stopped VM's mode switch onto an active twin's network is admitted")
    func refuseSlotConflictOnlyGuardsALiveVM() {
        let (registry, _) = makeRegistry()
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
        #expect(registry.refuseSlotConflict(on: instance, movingFrom: old, to: new) == false)
        #expect(failures.showError == false)
    }

    // MARK: - Network Recreation

    /// A running VM whose coordinator mirrors a live attachment on `kind` —
    /// what ``VMInstance/mayHoldAttachment(on:)`` reads as a holder.
    private func makeHolder(named name: String, on kind: VmnetNetworkKind) -> VMInstance {
        let instance = VMInstanceFixture.make(name: name)
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
        let instance = VMInstanceFixture.make(name: name)
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
        vmnet.scriptedRecreationReasons = [.hostOnly: .declarationsPending]
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
        roster.instances = [VMInstanceFixture.make(name: "Stopped")]

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

    @Test("A download in flight does not keep pending declarations from installing while idle")
    func aDownloadDoesNotHoldOffThePendingRecreate() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedRecreationReasons = [.shared: .declarationsPending]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        roster.instances = [makeDownloading(named: "Downloading")]

        registry.rebuildNetworksIfIdle()

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    // MARK: - Replacing a Served Network at the Next Join

    /// A registry over the real service, its networks created by a scripted
    /// operator — for following one network object across a stop and the
    /// next join.
    private func makeRegistryOverService() -> (
        VMNetworkSlotRegistry, VmnetNetworkService, MockVmnetNetworkOperator
    ) {
        let operations = MockVmnetNetworkOperator()
        let service = VmnetNetworkService(operations: operations, storeURL: nil)
        let registry = VMNetworkSlotRegistry(vmnetNetworks: service, isVMNetworkingEntitled: true)
        registry.roster = roster
        return (registry, service, operations)
    }

    /// A Shared VM fetching its installer image: a transitioning phase with no
    /// session context, so no configuration build behind it.
    private func makeDownloading(named name: String) -> VMInstance {
        let instance = VMInstanceFixture.make(name: name, phase: .installing(sessionID: nil))
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        return instance
    }

    @Test("An idle pass keeps a served network, its subnet held")
    func anIdlePassKeepsAServedNetwork() throws {
        let (registry, service, operations) = makeRegistryOverService()
        service.reserveAddressIfNeeded(for: "aa:bb:cc:dd:ee:01", kind: .shared)
        _ = try service.attachment(for: .shared)
        let released = operations.releasedNetworks
        roster.instances = [VMInstanceFixture.make(name: "Stopped")]

        registry.rebuildNetworksIfIdle()

        #expect(operations.releasedNetworks == released)
        #expect(!service.isPinnedOnlyForTesting(.shared))
        #expect(service.recreationReason(for: .shared) == .servedAttachment)
    }

    @Test("A VM joining a served network nobody else holds replaces it, and readers are told to ask again")
    func aJoinReplacesAnUnheldServedNetwork() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedRecreationReasons = [.shared: .servedAttachment]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let joiner = VMInstanceFixture.make(name: "Joiner")
        roster.instances = [VMInstanceFixture.make(name: "Stopped"), joiner]
        let before = registry.addressingGeneration

        registry.prepareNetwork(.shared, forJoining: joiner)

        #expect(vmnet.invalidatedKinds == [.shared])
        #expect(registry.addressingGeneration > before)
    }

    @Test("A VM joining a served network a running VM is on reuses it: that run has not ended")
    func aJoinReusesANetworkARunningVMHolds() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedRecreationReasons = [.shared: .servedAttachment]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let joiner = VMInstanceFixture.make(name: "Joiner")
        roster.instances = [makeHolder(named: "Running", on: .shared), joiner]

        registry.prepareNetwork(.shared, forJoining: joiner)

        #expect(vmnet.invalidatedKinds.isEmpty)
    }

    @Test("A VM joining a served network another VM's build has taken reuses it")
    func aJoinReusesANetworkABuildHolds() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedRecreationReasons = [.shared: .servedAttachment]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let building = VMInstanceFixture.make(name: "Building", phase: .starting(sessionID: nil))
        building.configuration.networkEnabled = true
        building.configuration.networkMode = .shared
        building.beginSessionContext()
        let joiner = VMInstanceFixture.make(name: "Joiner")
        roster.instances = [building, joiner]

        registry.prepareNetwork(.shared, forJoining: joiner)

        // Its configuration build hands out an attachment on whatever network
        // stands, so pulling this one away would split the two VMs.
        #expect(vmnet.invalidatedKinds.isEmpty)
        building.tearDownSession(restingAt: .stopped)
    }

    @Test("A download in flight does not keep a served network from being replaced at the next join")
    func aDownloadDoesNotHoldAServedNetwork() {
        let vmnet = MockVmnetNetworkProvider()
        vmnet.scriptedRecreationReasons = [.shared: .servedAttachment]
        let (registry, _) = makeRegistry(vmnetNetworks: vmnet)
        let joiner = VMInstanceFixture.make(name: "Joiner")
        roster.instances = [makeDownloading(named: "Downloading"), joiner]

        registry.prepareNetwork(.shared, forJoining: joiner)

        #expect(vmnet.invalidatedKinds == [.shared])
    }

    @Test("A served network is kept across a stop and replaced as the next VM joins, its addresses never pending")
    func aServedNetworkIsReplacedAtTheNextJoin() throws {
        let (registry, service, operations) = makeRegistryOverService()
        let macs = ["aa:bb:cc:dd:ee:01", "aa:bb:cc:dd:ee:02"]
        for mac in macs { service.reserveAddressIfNeeded(for: mac, kind: .shared) }
        // The addressing learn: a network no VM has joined yet.
        _ = try service.network(for: .shared)
        let first = VMInstanceFixture.make(name: "First")
        let second = VMInstanceFixture.make(name: "Second")
        roster.instances = [first, second]
        let addresses = { macs.map { service.reservedAddress(for: $0, kind: .shared) } }
        let reserved = ["192.168.213.2", "192.168.213.3"]
        #expect(addresses() == reserved)

        registry.prepareNetwork(.shared, forJoining: first)
        _ = try service.attachment(for: .shared)
        #expect(operations.releasedNetworks.count == 1)
        #expect(addresses() == reserved)

        // The first VM has stopped: nobody holds the network, and it stays.
        registry.rebuildNetworksIfIdle()
        #expect(operations.releasedNetworks.count == 1)
        #expect(addresses() == reserved)

        registry.prepareNetwork(.shared, forJoining: second)
        #expect(addresses() == reserved)
        _ = try service.attachment(for: .shared)
        #expect(addresses() == reserved)

        // The second VM joins a new network carrying every reservation, pinned
        // to the same subnet, and the first one's network is what was released.
        let attached = operations.attachedNetworks
        try #require(attached.count == 2)
        #expect(attached[1] != attached[0])
        #expect(operations.releasedNetworks.last == attached[0])
        #expect(operations.pinnedAddressings.last == operations.freshAddressing)
        #expect(operations.installedReservations.last?.map(\.mac) == macs)
    }

    /// A running Shared VM holding the attachment its configuration build took
    /// on `service`'s network, with the join hook the library wires it — the
    /// shape a guest reboot disconnects.
    private func makeAttachedSharedVM(
        named name: String, mac: String, joining registry: VMNetworkSlotRegistry,
        on service: VmnetNetworkService, alongside others: [VMInstance]
    ) throws -> (VMInstance, MockNetworkDeviceControl, NetworkAttachmentCoordinator) {
        let instance = VMInstanceFixture.make(name: name)
        instance.configuration.networkEnabled = true
        instance.configuration.networkMode = .shared
        instance.configuration.macAddress = mac
        instance.enter(.running(sessionID: UUID()))
        roster.instances = others + [instance]
        instance.onJoiningVmnetNetwork = { [weak instance] kind in
            guard let instance else { return }
            registry.prepareNetwork(kind, forJoining: instance)
        }
        // The bring-up: the session joins the network, and its configuration
        // build takes the attachment that starts the network's run.
        instance.beginSessionContext()
        _ = try service.attachment(for: .shared)
        let device = MockNetworkDeviceControl(plan: .sharedVmnet)
        let coordinator = attachNetworkCoordinator(
            to: instance, device: device, vmnetNetworks: service, isVMNetworkingEntitled: true)
        coordinator.activate()
        return (instance, device, coordinator)
    }

    @Test("A disconnected session rejoins a replacement, and its reserved address is what answers")
    func aDisconnectReplacesAnUnheldServedNetwork() throws {
        let (registry, service, operations) = makeRegistryOverService()
        let mac = "aa:bb:cc:dd:ee:01"
        service.reserveAddressIfNeeded(for: mac, kind: .shared)
        // The addressing learn: a network no VM has joined yet.
        _ = try service.network(for: .shared)
        let (instance, device, coordinator) = try makeAttachedSharedVM(
            named: "Rebooting", mac: mac, joining: registry, on: service, alongside: [])
        let served = try #require(operations.attachedNetworks.last)
        let releasedBefore = operations.releasedNetworks
        let reserved = GuestIPAddress.reserved("192.168.213.2")
        #expect(registry.reservedAddress(for: instance.configuration) == reserved)

        // An in-guest reboot: VZ nils the attachment, and the interface leaving
        // took the network's run, and its reservations, with it.
        device.plan = nil
        coordinator.attachmentWasDisconnected(error: TestFailure("guest reboot"))

        // The network the session was on is the one that went.
        #expect(operations.releasedNetworks == releasedBefore + [served])
        // The mock device installs a plan without asking the service, so the
        // attach the real handle makes on the replacement is spelled out here.
        _ = try service.attachment(for: .shared)
        #expect(operations.attachedNetworks.last != served)
        #expect(operations.pinnedAddressings.last == operations.freshAddressing)
        #expect(operations.installedReservations.last?.map(\.mac) == [mac])
        #expect(registry.reservedAddress(for: instance.configuration) == reserved)

        coordinator.stop()
        instance.tearDownSession(restingAt: .stopped)
    }

    @Test("A disconnected session rejoins the network a sibling is still on: that run has not ended")
    func aDisconnectReusesANetworkASiblingHolds() throws {
        let (registry, service, operations) = makeRegistryOverService()
        let mac = "aa:bb:cc:dd:ee:01"
        service.reserveAddressIfNeeded(for: mac, kind: .shared)
        _ = try service.network(for: .shared)
        let holder = makeHolder(named: "Holder", on: .shared)
        let (instance, device, coordinator) = try makeAttachedSharedVM(
            named: "Rebooting", mac: mac, joining: registry, on: service, alongside: [holder])
        let releasedBefore = operations.releasedNetworks
        let createdBefore = operations.createdKinds

        device.plan = nil
        coordinator.attachmentWasDisconnected(error: TestFailure("guest reboot"))

        // The sibling's interface kept the network running, so its reservations
        // stand and pulling it away would drop that guest's link.
        #expect(operations.releasedNetworks == releasedBefore)
        #expect(operations.createdKinds == createdBefore)
        #expect(service.recreationReason(for: .shared) == .servedAttachment)
        #expect(registry.reservedAddress(for: instance.configuration) == .reserved("192.168.213.2"))

        coordinator.stop()
        instance.tearDownSession(restingAt: .stopped)
    }
}
