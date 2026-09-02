import Foundation
import os

/// What the guest's IPv4 address resolves to for the mode it is on — the one
/// answer every surface states, whether it renders prose or reports the bare
/// address.
enum GuestIPAddress: Equatable, Sendable {
    /// Nothing assigns the guest an address the app can state — the row is
    /// absent rather than empty.
    case unavailable
    /// Bridged: the guest asks the network, so there is nothing deterministic.
    case externallyAssigned
    /// A reservation exists but the network's addressing is not known yet.
    case pending
    case reserved(String)

    /// The address itself, `nil` unless the app reserved one — what a headless
    /// surface answers with, where the other cases are prose rather than data.
    var reservedAddress: String? {
        guard case .reserved(let address) = self else { return nil }
        return address
    }
}

/// The slots a VM holds on the app-managed networks: its DHCP address
/// reservation, its port-forwarding rules, and the uniqueness of the MAC
/// address both are keyed on.
///
/// Both a reservation and a rule set are fixed when a network is created, so
/// every change made here waits for a recreate — which this is also what
/// schedules, once no session could be holding the network.
///
/// Headless: the two refusals leave through ``onFailure``.
@MainActor
@Observable
final class VMNetworkSlotRegistry {
    nonisolated private static let logger = Logger(
        subsystem: "app.kernova", category: "VMNetworkSlotRegistry")

    @ObservationIgnored
    private let vmnetNetworks: any VmnetNetworkProviding & VmnetNetworkRecreating

    /// Whether this build's reservation machinery is live — a process-wide
    /// constant, snapshotted at init.
    @ObservationIgnored
    private let isVMNetworkingEntitled: Bool

    /// Which VMs exist. Weak and assigned after construction: the library owns
    /// this registry, so a strong reference back would be a cycle.
    @ObservationIgnored
    weak var roster: (any VMInstanceRoster)?

    /// Receives the refusals a user has to be told about.
    @ObservationIgnored
    var onFailure: ((_ title: String, _ message: String) -> Void)?

    /// Bumped whenever ``reservedAddress(for:)`` can answer differently for an
    /// unchanged configuration: a learned addressing, or an invalidation that
    /// lets a slot taken after its network's creation derive an address at last.
    /// A reader registers for it by calling that method — nothing else has to
    /// know the counter exists.
    private(set) var addressingGeneration = 0

    /// The in-flight addressing learn per kind, doubling as its single-flight
    /// guard.
    @ObservationIgnored
    private var addressingLearns: [VmnetNetworkKind: Task<Void, Never>] = [:]

    private var instances: [VMInstance] {
        guard let roster else {
            Self.logger.fault("VMNetworkSlotRegistry has no roster — answering as an empty library")
            assertionFailure("VMNetworkSlotRegistry.roster was never assigned")
            return []
        }
        return roster.instances
    }

    init(
        vmnetNetworks: any VmnetNetworkProviding & VmnetNetworkRecreating,
        isVMNetworkingEntitled: Bool
    ) {
        self.vmnetNetworks = vmnetNetworks
        self.isVMNetworkingEntitled = isVMNetworkingEntitled
    }

    // MARK: - Composed Entry Points

    /// Refuses a configuration edit that would put two guests on one MAC
    /// address, surfacing the alert the refusal owes.
    ///
    /// - Returns: `true` when the caller must abort.
    func refuseSlotConflict(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration
    ) -> Bool {
        if let mac = new.macAddress, mac.lowercased() != old.macAddress?.lowercased(),
            refuseIfDuplicateMACAddress(mac, on: instance)
        {
            return true
        }
        // A live VM's Mode picker stays enabled, and a mode change hot-swaps the
        // attachment: the address is unchanged, so the refusal above never sees
        // it, and the network it lands on is not the one `start` checked. Only a
        // VM already running can form the collision this way, and only a
        // configuration not already in one is refused — a VM that reached a
        // collision by some other route has to stay editable to leave it.
        if instance.isActive || instance.isLivePaused,
            liveMACAddressConflict(for: old, excluding: instance) == nil,
            refuseIfDuplicateMACAddressConflict(instance, joining: new)
        {
            return true
        }
        return false
    }

    /// Moves this VM's reservation and forwarding slots from `old` to `new`.
    func moveSlots(from old: VMConfiguration, to new: VMConfiguration) {
        // An edited MAC leaves its predecessor holding an older — so
        // higher-priority — reservation slot. Left declared there, the retired
        // address keeps claiming the VM's host ports and the rules re-declared
        // under the new one are dropped as duplicates.
        if let retired = old.macAddress, retired != new.macAddress {
            withdrawPortForwardingRules(for: old)
        }
        // Released before the new slot is taken, so the freed slot is the
        // lowest one available and an edited MAC normally keeps the VM's
        // address. Covers a MAC change, a mode switch, and networking off.
        if let retired = reservationTarget(for: old) {
            let kept = reservationTarget(for: new)
            if kept?.kind != retired.kind || kept?.mac != retired.mac {
                releaseAddressReservationIfUnused(retired)
            }
        }
        syncAddressReservation(for: new)
        syncPortForwardingRules(for: new)
    }

    /// Takes the slots a VM entering the library claims.
    func claimSlots(for config: VMConfiguration) {
        syncAddressReservation(for: config)
        syncPortForwardingRules(for: config)
    }

    /// Frees the slots a VM leaving the library held.
    ///
    /// `bundleIsGone: false` keeps the DHCP reservation, for a bundle still on
    /// disk whose configuration could not be read — that VM still exists, so
    /// handing its address to somebody else would move it once the
    /// configuration is readable again.
    func releaseSlots(for config: VMConfiguration, bundleIsGone: Bool) {
        withdrawPortForwardingRules(for: config)
        if bundleIsGone, let target = reservationTarget(for: config) {
            releaseAddressReservationIfUnused(target)
        }
    }

    // MARK: - Reservations

    /// The reservation slot `config` wants: the network its mode maps to and
    /// the lowercased MAC keying the slot, `nil` for a VM that can join no
    /// app-managed network (networking off, or Bridged, where external DHCP
    /// owns addressing).
    private func reservationTarget(
        for config: VMConfiguration
    ) -> (kind: VmnetNetworkKind, mac: String)? {
        guard config.networkEnabled, let mac = config.macAddress,
            let kind = VmnetNetworkKind(mode: config.networkMode)
        else { return nil }
        return (kind: kind, mac: mac.lowercased())
    }

    /// Keeps the VM's DHCP reservation slot in step with its configuration:
    /// any VM that can join an app-managed network holds a slot keyed on its
    /// persisted MAC, so its address is assigned before the network next
    /// materializes. Runs at every instance construction and configuration
    /// change; cheap and idempotent. Entitlement-gated like every other
    /// consumer of the reservation machinery — an unentitled build never
    /// materializes a network, so slots taken there would be dead weight.
    private func syncAddressReservation(for config: VMConfiguration) {
        guard isVMNetworkingEntitled, let target = reservationTarget(for: config) else { return }
        vmnetNetworks.reserveAddressIfNeeded(for: target.mac, kind: target.kind)
        learnNetworkAddressingIfNeeded(target.kind)
    }

    /// Materializes `kind`'s network once, when nothing has established its
    /// addressing yet.
    ///
    /// A slot's address is its position within the network's subnet, so it is
    /// derivable only once that subnet is known, and only a materialization
    /// establishes it. The registry handing out the slots is therefore what
    /// learns it: leaving each reader to trigger a materialization of its own is
    /// what made the answer depend on which surface asked.
    ///
    /// Single-flight per kind, and the entry is cleared however the
    /// materialization ended — a failed one is retried at the next slot sync,
    /// which is the whole retry ladder. Reached only from
    /// ``syncAddressReservation(for:)``, so the entitlement gate there covers it.
    private func learnNetworkAddressingIfNeeded(_ kind: VmnetNetworkKind) {
        guard addressingLearns[kind] == nil, !vmnetNetworks.addressingIsKnown(for: kind) else {
            return
        }
        let networks = vmnetNetworks
        addressingLearns[kind] = Task { [weak self] in
            _ = await networks.materializeNetwork(for: kind)
            guard let self else { return }
            self.addressingLearns[kind] = nil
            // A materialization reports success for two states that install no
            // reservations — the subnet was re-grabbed between the probe and the
            // recreate, or the attempt limit was spent — and both leave the
            // network idle with its declarations pending. Recreating here is what
            // keeps the address from waiting on an unrelated event; a no-op
            // wherever the network already carries what it should.
            self.rebuildNetworksIfIdle()
            self.addressingGeneration &+= 1
        }
    }

    /// Frees `target`'s reservation slot unless a VM still in the library wants
    /// the same one — a bundle can arrive carrying an address another VM already
    /// holds, so the last claimant is what releases the slot.
    private func releaseAddressReservationIfUnused(_ target: (kind: VmnetNetworkKind, mac: String)) {
        guard isVMNetworkingEntitled else { return }
        let stillWanted = instances.contains {
            let other = reservationTarget(for: $0.configuration)
            return other?.kind == target.kind && other?.mac == target.mac
        }
        guard !stillWanted else { return }
        vmnetNetworks.releaseAddressReservation(for: target.mac, kind: target.kind)
    }

    /// What the guest gets for an address on the network its mode joins — the
    /// one read the Overview, the Network panel and the command surface all
    /// take, so none of them can answer differently from the others.
    ///
    /// Reads the reservation store without taking a slot: the sync at every
    /// configuration change is what claims one, and the addressing a
    /// ``GuestIPAddress/pending`` answer waits on is learned there too.
    func reservedAddress(for config: VMConfiguration) -> GuestIPAddress {
        // Registers the caller with the generation the learn bumps, so a
        // pending answer repaints itself once the addressing lands.
        _ = addressingGeneration
        guard config.networkEnabled else { return .unavailable }
        // Answered before the entitlement gate: external DHCP owns a bridged
        // guest's address whether or not this build can manage a network.
        if config.networkMode == .bridged { return .externallyAssigned }
        guard isVMNetworkingEntitled, let target = reservationTarget(for: config) else {
            return .unavailable
        }
        if let address = vmnetNetworks.reservedAddress(for: target.mac, kind: target.kind) {
            return .reserved(address)
        }
        return .pending
    }

    /// Frees every reservation slot no VM in the library claims — the reclaim
    /// for slots orphaned while the app was not running (a bundle trashed in
    /// Finder), which no in-session release can catch.
    ///
    /// Runs only over a complete library: a bundle whose configuration failed
    /// to parse is absent from `instances` while its VM still exists, so its
    /// slot must not be handed to somebody else. Entitlement-gated like the
    /// rest of the reservation machinery — an unentitled build never reserves,
    /// so pruning there would empty a store the entitled build owns.
    func pruneAddressReservations(scanWasComplete: Bool) {
        guard isVMNetworkingEntitled, scanWasComplete else { return }
        let targets = instances.compactMap { reservationTarget(for: $0.configuration) }
        for kind in VmnetNetworkKind.allCases {
            let macs = Set(targets.filter { $0.kind == kind }.map(\.mac))
            vmnetNetworks.retainAddressReservations(macs, kind: kind)
        }
        // A reload can run while a network is materialized, so the slots this
        // just reclaimed only reach guests through a recreate.
        rebuildNetworksIfIdle()
    }

    // MARK: - Port Forwarding

    /// Keeps the VM's port-forwarding rules in step with its configuration: a
    /// Shared Network VM declares its rules on that network, a VM in any other
    /// mode declares none. Runs wherever ``syncAddressReservation(for:)`` does.
    private func syncPortForwardingRules(for config: VMConfiguration) {
        let forwards = config.networkEnabled && config.networkMode == .shared
        declarePortForwardingRules(forwards ? config.portForwardingRules : [], for: config)
    }

    /// Declares `rules` for the VM `config` identifies.
    ///
    /// Entitlement-gated like the reservation machinery it rides on — an
    /// unentitled build attaches system NAT, which forwards nothing.
    private func declarePortForwardingRules(
        _ rules: [PortForwardingRule], for config: VMConfiguration
    ) {
        guard isVMNetworkingEntitled, let mac = config.macAddress else { return }
        vmnetNetworks.setPortForwardingRules(rules, for: mac, kind: .shared)
    }

    /// Withdraws the rules `config` declared, unless a VM still in the library
    /// carries the same MAC — rules are keyed on the address, so a blanket
    /// withdrawal would disarm that VM's rules too; its own are re-declared
    /// instead. An address is one VM's alone once it passes
    /// ``refuseIfDuplicateMACAddress(_:on:)``, so the survivor is a bundle that
    /// arrived carrying one already in use.
    private func withdrawPortForwardingRules(for config: VMConfiguration) {
        guard let mac = config.macAddress?.lowercased() else { return }
        let survivor = instances.first { $0.configuration.macAddress?.lowercased() == mac }
        if let survivor {
            syncPortForwardingRules(for: survivor.configuration)
        } else {
            declarePortForwardingRules([], for: config)
        }
    }

    // MARK: - MAC Address Uniqueness

    /// The VMs other than `instance` whose configuration carries `mac`, in
    /// library order — the one lookup every duplicate-address question derives
    /// from.
    ///
    /// Case-insensitive, matching the reservation slots and forwarding rules the
    /// address keys. A VM with networking off counts: the address persists
    /// across mode changes, so turning networking back on would re-form the
    /// collision.
    private func vmsHoldingMACAddress(_ mac: String, otherThan instance: VMInstance) -> [VMInstance] {
        let wanted = mac.lowercased()
        return instances.filter {
            $0 !== instance && $0.configuration.macAddress?.lowercased() == wanted
        }
    }

    /// Names of the other VMs in the library carrying `instance`'s MAC address,
    /// in library order — empty when the address is this VM's alone.
    func vmNamesSharingMACAddress(with instance: VMInstance) -> [String] {
        guard let mac = instance.configuration.macAddress else { return [] }
        return vmsHoldingMACAddress(mac, otherThan: instance).map(\.name)
    }

    /// Records every MAC address two or more VMs in the library hold.
    ///
    /// Import, load and reconcile admit whatever address a bundle arrives
    /// carrying, so this is where a pair the app never authored becomes
    /// traceable. Runs on each of those three, which are the paths a VM the app
    /// did not author an address for enters by.
    func logDuplicateMACAddressHolders() {
        let holders = Dictionary(grouping: instances) { $0.configuration.macAddress?.lowercased() }
        for (mac, vms) in holders where mac != nil && vms.count > 1 {
            let names = vms.map { "'\($0.name)'" }.joined(separator: ", ")
            Self.logger.warning(
                "MAC address \(mac ?? "", privacy: .public) is held by \(names, privacy: .public)")
        }
    }

    /// Refuses a change that would give `instance` a MAC address another VM in
    /// the library holds, logging the refusal and surfacing the alert.
    ///
    /// - Returns: `true` when the caller must abort.
    private func refuseIfDuplicateMACAddress(_ mac: String, on instance: VMInstance) -> Bool {
        guard let holder = vmsHoldingMACAddress(mac, otherThan: instance).first else { return false }
        Self.logger.notice(
            "Refused the MAC address \(mac, privacy: .public) for '\(instance.name, privacy: .public)': '\(holder.name, privacy: .public)' already holds it"
        )
        onFailure?(
            "MAC Address In Use",
            "“\(holder.name)” already uses \(mac). "
                + "Each virtual machine needs its own MAC address. "
                + "Change or delete “\(holder.name)” first to move this address to “\(instance.name)”.")
        return true
    }

    /// Refuses an operation that would put a second guest on one MAC address on
    /// one network, logging the refusal and surfacing the alert.
    ///
    /// `config` is the configuration the VM would run under — its own at start,
    /// the prospective one for a live mode switch, which moves an unchanged
    /// address onto a different network.
    ///
    /// ``refuseIfDuplicateMACAddress(_:on:)`` keeps the library unique for every
    /// address the app writes; this covers the pair a bundle arrived carrying,
    /// which passed through no writer.
    ///
    /// - Returns: `true` when the caller must abort.
    private func refuseIfDuplicateMACAddressConflict(
        _ instance: VMInstance, joining config: VMConfiguration
    ) -> Bool {
        guard let conflict = liveMACAddressConflict(for: config, excluding: instance),
            let mac = config.macAddress
        else { return false }
        Self.logger.notice(
            "Refused to run '\(instance.name, privacy: .public)': shares the MAC address \(mac, privacy: .public) with active VM '\(conflict.name, privacy: .public)'"
        )
        onFailure?(
            "Duplicate MAC Address",
            "“\(instance.name)” has the same MAC address as “\(conflict.name)”, which is active. "
                + "Two virtual machines with the same MAC address must not run on the same network at once. "
                + "Stop “\(conflict.name)” first, or give one of them a new address in Network settings.")
        return true
    }

    /// The first live VM sharing `config`'s MAC address on the network `config`
    /// joins, if any.
    ///
    /// Live means VZ holds the attachment, as it does for the machine identity.
    /// The mode names the network, so two holders collide only where both
    /// guests attach: networking off puts no address on a wire, and Shared,
    /// Host Only and Bridged are separate networks. Two bridged VMs compare as
    /// one network whatever interface each names — Automatic resolves at start,
    /// so which link they land on is not knowable in advance.
    func liveMACAddressConflict(
        for config: VMConfiguration, excluding instance: VMInstance
    ) -> VMInstance? {
        guard config.networkEnabled, let mac = config.macAddress else { return nil }
        return vmsHoldingMACAddress(mac, otherThan: instance).first { other in
            (other.isActive || other.isLivePaused)
                && other.configuration.networkEnabled
                && other.configuration.networkMode == config.networkMode
        }
    }

    // MARK: - Network Recreation

    /// Recreates every app-managed network that has a reason to be recreated,
    /// once no VM could be attached to it.
    ///
    /// Two reasons, both re-derived on every pass: the network's DHCP
    /// reservations or forwarding rules are no longer the ones that should
    /// install (both are fixed at creation, so a change reaches guests only
    /// through a recreate), or a session's attachment recovery reports the
    /// network defective. The recreate keeps the network's addressing, so no
    /// guest's address moves.
    ///
    /// `tornDown` is the instance whose session just ended, excluded from the
    /// idle scan: `tearDownSession` fires its hook before the caller settles
    /// the status, so a VM released from a transitioning one (`.saving` on a
    /// save-suspend, `.installing` on a cancelled guest setup) would otherwise
    /// read as still holding the network it just let go of.
    func rebuildNetworksIfIdle(ignoring tornDown: VMInstance? = nil) {
        for kind in VmnetNetworkKind.allCases { rebuildNetworkIfIdle(kind, ignoring: tornDown) }
    }

    /// Recreates the app-managed network of `kind` when something asks for it
    /// and nothing holds it — the only place ``VmnetNetworkRecreating`` is
    /// called, because a recreate pulls the network out from under every VM
    /// sharing it and this is the only type that can see them all.
    private func rebuildNetworkIfIdle(_ kind: VmnetNetworkKind, ignoring tornDown: VMInstance?) {
        let others = instances.filter { $0 !== tornDown }
        let reason: String
        if vmnetNetworks.networkConfigurationIsPending(for: kind) {
            reason = "to install its pending changes"
        } else if others.contains(where: { $0.suspectsDefectiveNetwork(on: kind) }) {
            reason = "after a session reported it defective"
        } else {
            return
        }
        // The single precondition for dropping shared state: nobody is on it.
        guard !others.contains(where: { $0.mayHoldAttachment(on: kind) }) else { return }
        Self.logger.notice(
            "Recreating the \(kind.rawValue, privacy: .public) network \(reason, privacy: .public)")
        vmnetNetworks.invalidateNetwork(for: kind)
        // The network that contradicted a slot taken after its creation is
        // gone, so an address pending on that contradiction derives now.
        addressingGeneration &+= 1
        // The network a detached session was waiting on just went away, on both
        // reasons alike — its retry ladder is spent, so this nudge is the only
        // wake-up it gets. A no-op for every VM not detached on this kind.
        for instance in others { instance.vmnetNetworkWasInvalidated(kind) }
    }

    #if DEBUG
    /// The in-flight addressing learn for `kind`, for event-driven test waits.
    func addressingLearnTaskForTesting(_ kind: VmnetNetworkKind) -> Task<Void, Never>? {
        addressingLearns[kind]
    }
    #endif
}
