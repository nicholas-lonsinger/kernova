import Foundation
import KernovaKit
import KernovaLogging

/// The uniqueness of each VM's MAC address across the library: the refusal of
/// an edit that would give two guests one address, and the traces of a pair the
/// app did not author (docs/NETWORKING.md, a MAC address belongs to one virtual
/// machine).
///
/// A VM holds the address its configuration carries and the one each of its
/// snapshots was taken with, until that snapshot is deleted: a revert puts
/// the VM back on the snapshot's address — a warm snapshot's saved state
/// restores under no other — so the address must still be the VM's to take.
///
/// Headless: a refusal leaves through ``onFailure`` as words, and through
/// ``macAddressConflict(on:movingFrom:to:)`` as data for a caller that renders
/// its own.
@MainActor
final class VMMACAddressRegistry {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMMACAddressRegistry")

    /// Which VMs exist. Weak and assigned after construction: the library owns
    /// this registry, so a strong reference back would be a cycle.
    weak var roster: (any VMInstanceRoster)?

    /// Receives the refusals a user has to be told about.
    var onFailure: ((_ title: String, _ message: String) -> Void)?

    /// The address a refusal's summaries carry for each VM.
    private let guestAddresses: GuestAddressObserver

    private var instances: [VMInstance] {
        guard let roster else {
            #log(Self.logger, .fault, "VMMACAddressRegistry has no roster — answering as an empty library")
            assertionFailure("VMMACAddressRegistry.roster was never assigned")
            return []
        }
        return roster.instances
    }

    init(guestAddresses: GuestAddressObserver) {
        self.guestAddresses = guestAddresses
    }

    // MARK: - Refusals

    /// Why a configuration change is refused, and which VM it collides with.
    struct MACAddressConflict {
        /// The VM already holding what the change asked for — the first, in
        /// library order, when several do.
        let other: VMInstance
        /// What the two collide on.
        let reason: ConflictReason
    }

    /// Surfaces the alert a configuration edit refused for `conflict` owes.
    func presentRefusal(_ conflict: MACAddressConflict, on instance: VMInstance) {
        let failure = commandFailure(conflict, on: instance)
        #log(
            Self.logger, .notice,
            "Refused a configuration change to '\(instance.name, privacy: .public)': \(failure.message, privacy: .public)"
        )
        onFailure?(failure.title, failure.message)
    }

    /// The VM a configuration change would collide with, and what on — the one
    /// derivation both an in-process refusal and a wire refusal read.
    ///
    /// `nil` when the change is admissible. An address one of the VM's own
    /// snapshots was taken with is its own to move back onto.
    func macAddressConflict(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration
    ) -> MACAddressConflict? {
        if let mac = new.macAddress, mac.lowercased() != old.macAddress?.lowercased() {
            let holders = self.holders(of: mac, otherThan: instance)
            if let (first, holding) = holders.first {
                return MACAddressConflict(
                    other: first,
                    reason: .macAddressInUse(
                        address: mac, holding: holding,
                        otherHolders: holders.dropFirst().map {
                            MACAddressHolder(name: $0.vm.name, holding: $0.holding)
                        }))
            }
        }
        // A live VM's Mode picker stays enabled, and a mode change hot-swaps the
        // attachment: the address is unchanged, so the refusal above never sees
        // it, and the network it lands on is not the one `start` checked. Only a
        // VM already running can form the collision this way, and only a
        // configuration not already in one is refused — a VM that reached a
        // collision by some other route has to stay editable to leave it.
        guard instance.holdsLiveIdentity,
            !Self.claimSameNetwork(old, new),
            let live = liveMACAddressConflict(for: new, excluding: instance),
            liveMACAddressConflict(for: old, excluding: instance) == nil
        else { return nil }
        return MACAddressConflict(other: live, reason: .macAddress)
    }

    /// Whether `a` and `b` put the same address on the same network — the
    /// three fields ``liveMACAddressConflict(for:excluding:)`` reads.
    private static func claimSameNetwork(_ a: VMConfiguration, _ b: VMConfiguration) -> Bool {
        a.networkEnabled == b.networkEnabled && a.networkMode == b.networkMode
            && a.macAddress?.lowercased() == b.macAddress?.lowercased()
    }

    /// `conflict` in the command vocabulary, so an alert and a wire client word
    /// the same refusal identically.
    func commandFailure(_ conflict: MACAddressConflict, on instance: VMInstance) -> CommandErrorDTO {
        .conflict(
            vm: summary(instance), with: summary(conflict.other), reason: conflict.reason)
    }

    private func summary(_ instance: VMInstance) -> VMSummary {
        instance.summary(ipAddress: guestAddresses.address(for: instance))
    }

    // MARK: - Holders

    /// How `vm` holds `mac` — in its configuration, in snapshots, or both —
    /// or `nil` when it does not. `mac` is lowercased.
    private static func holding(of mac: String, by vm: VMInstance) -> MACAddressHolding? {
        MACAddressHolding(
            configured: vm.configuration.macAddress?.lowercased() == mac,
            snapshots: vm.snapshotManifest.snapshots
                .filter { $0.macAddress?.lowercased() == mac }
                .map { HeldSnapshot(name: $0.name, isEphemeralBaseline: vm.isEphemeralBaseline($0)) })
    }

    /// The VMs other than `instance` holding `mac`, in library order, each
    /// with how it holds it — the lookup every refusal derives from.
    ///
    /// Case-insensitive. A VM with networking off counts: the address persists
    /// across mode changes, so turning networking back on would re-form the
    /// collision.
    private func holders(
        of mac: String, otherThan instance: VMInstance
    ) -> [(vm: VMInstance, holding: MACAddressHolding)] {
        let wanted = mac.lowercased()
        return instances.compactMap { vm in
            guard vm !== instance, let holding = Self.holding(of: wanted, by: vm) else { return nil }
            return (vm, holding)
        }
    }

    /// The VMs other than `instance` whose configuration carries `mac`, in
    /// library order.
    private func configurationHolders(
        of mac: String, otherThan instance: VMInstance
    ) -> [VMInstance] {
        let wanted = mac.lowercased()
        return instances.filter {
            $0 !== instance && $0.configuration.macAddress?.lowercased() == wanted
        }
    }

    /// Names of the other VMs in the library whose configuration carries
    /// `instance`'s MAC address, in library order — empty when no other
    /// configuration does.
    ///
    /// A snapshot's hold is left out: it puts the address on no network until
    /// a revert makes it the configuration's.
    func vmNamesSharingMACAddress(with instance: VMInstance) -> [String] {
        guard let mac = instance.configuration.macAddress else { return [] }
        return configurationHolders(of: mac, otherThan: instance).map(\.name)
    }

    /// Records every MAC address two or more VMs in the library hold, in
    /// their configurations or their snapshots.
    ///
    /// Import, load and reconcile admit whatever address a bundle arrives
    /// carrying, so this is where a pair the app never authored becomes
    /// traceable. Runs once each of those has taken in the bundle's snapshots,
    /// which are the paths a VM the app did not author an address for enters
    /// by.
    func logDuplicateMACAddressHolders() {
        let addresses = Set(
            instances.flatMap { vm in
                [vm.configuration.macAddress] + vm.snapshotManifest.snapshots.map(\.macAddress)
            }.compactMap { $0?.lowercased() })
        for mac in addresses {
            let holders = instances.compactMap { vm in
                Self.holding(of: mac, by: vm).map { (vm: vm, holding: $0) }
            }
            guard holders.count > 1 else { continue }
            let names = holders.map { "'\($0.vm.name)' (\(Self.describe($0.holding)))" }
                .joined(separator: ", ")
            #log(
                Self.logger, .warning,
                "MAC address \(mac, privacy: .public) is held by \(names, privacy: .public)")
        }
    }

    private static func describe(_ holding: MACAddressHolding) -> String {
        switch holding {
        case .configuration: "configuration"
        case .snapshots(let held): "snapshots " + held.all.map { "'\($0.name)'" }.joined(separator: ", ")
        case .configurationAndSnapshots(let held):
            "configuration, snapshots " + held.all.map { "'\($0.name)'" }.joined(separator: ", ")
        }
    }

    /// The first live VM sharing `config`'s MAC address on the network `config`
    /// joins, if any.
    ///
    /// Live is ``VMInstance/holdsLiveIdentity``. The mode names the network, so two holders collide only where both
    /// guests attach: networking off puts no address on a wire, and Shared,
    /// Host Only and Bridged are separate networks. Two bridged VMs compare as
    /// one network whatever interface each names — Automatic resolves at start,
    /// so which link they land on is not knowable in advance. Only
    /// configurations count: a running guest is on its configuration's address.
    func liveMACAddressConflict(
        for config: VMConfiguration, excluding instance: VMInstance
    ) -> VMInstance? {
        guard config.networkEnabled, let mac = config.macAddress else { return nil }
        return configurationHolders(of: mac, otherThan: instance).first { other in
            other.holdsLiveIdentity
                && other.configuration.networkEnabled
                && other.configuration.networkMode == config.networkMode
        }
    }
}
