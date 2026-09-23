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
        /// The VM already holding what the change asked for.
        let other: VMInstance
        /// What the two collide on.
        let reason: ConflictReason
    }

    /// Refuses a configuration edit that would put two guests on one MAC
    /// address, surfacing the alert the refusal owes.
    ///
    /// - Returns: `true` when the caller must abort.
    func refuseMACAddressConflict(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration
    ) -> Bool {
        guard let conflict = macAddressConflict(on: instance, movingFrom: old, to: new) else {
            return false
        }
        let failure = commandFailure(conflict, on: instance)
        #log(
            Self.logger, .notice,
            "Refused a configuration change to '\(instance.name, privacy: .public)': \(failure.message, privacy: .public)"
        )
        onFailure?(failure.title, failure.message)
        return true
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
            let claims = claims(on: mac, otherThan: instance)
            if let holder = claims.first?.holder {
                let held = claims.filter { $0.holder === holder }
                return MACAddressConflict(
                    other: holder,
                    reason: .macAddressInUse(
                        address: mac, configured: held.contains { $0.snapshot == nil },
                        snapshots: held.compactMap(\.snapshot?.name)))
            }
        }
        // A live VM's Mode picker stays enabled, and a mode change hot-swaps the
        // attachment: the address is unchanged, so the refusal above never sees
        // it, and the network it lands on is not the one `start` checked. Only a
        // VM already running can form the collision this way, and only a
        // configuration not already in one is refused — a VM that reached a
        // collision by some other route has to stay editable to leave it.
        if instance.isActive || instance.isLivePaused,
            liveMACAddressConflict(for: old, excluding: instance) == nil,
            let live = liveMACAddressConflict(for: new, excluding: instance)
        {
            return MACAddressConflict(other: live, reason: .macAddress)
        }
        return nil
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

    // MARK: - Claims

    /// One VM's hold on a MAC address.
    private struct Claim {
        let holder: VMInstance
        /// The snapshot taken with the address, or `nil` for the address the
        /// VM's configuration carries.
        let snapshot: VMSnapshot?
        /// Lowercased, so claims compare case-insensitively.
        let address: String?
    }

    /// Every claim `instance` makes: its configuration's address, then each
    /// snapshot's in the order they were taken.
    private static func claims(of instance: VMInstance) -> [Claim] {
        [
            Claim(
                holder: instance, snapshot: nil,
                address: instance.configuration.macAddress?.lowercased())
        ]
            + instance.snapshotManifest.snapshots.map {
                Claim(holder: instance, snapshot: $0, address: $0.macAddress?.lowercased())
            }
    }

    /// The claims VMs other than `instance` make on `mac`, in library order —
    /// the one lookup every duplicate-address question derives from.
    ///
    /// Case-insensitive. A VM with networking off counts: the address persists
    /// across mode changes, so turning networking back on would re-form the
    /// collision.
    private func claims(on mac: String, otherThan instance: VMInstance) -> [Claim] {
        let wanted = mac.lowercased()
        return instances.filter { $0 !== instance }.flatMap(Self.claims(of:)).filter {
            $0.address == wanted
        }
    }

    /// Names of the other VMs in the library whose configuration carries
    /// `instance`'s MAC address, in library order — empty when no other
    /// configuration does.
    ///
    /// A snapshot's claim is left out: it puts the address on no network until
    /// a revert makes it the configuration's.
    func vmNamesSharingMACAddress(with instance: VMInstance) -> [String] {
        guard let mac = instance.configuration.macAddress else { return [] }
        return claims(on: mac, otherThan: instance).filter { $0.snapshot == nil }.map(\.holder.name)
    }

    /// Records every MAC address two or more VMs in the library hold.
    ///
    /// Import, load and reconcile admit whatever address a bundle arrives
    /// carrying, so this is where a pair the app never authored becomes
    /// traceable. Runs on each of those three, which are the paths a VM the app
    /// did not author an address for enters by.
    func logDuplicateMACAddressHolders() {
        let holders = Dictionary(grouping: instances.flatMap(Self.claims(of:)), by: \.address)
        for (mac, claims) in holders {
            guard let mac, Set(claims.map { ObjectIdentifier($0.holder) }).count > 1 else {
                continue
            }
            let names = claims.map { claim in
                claim.snapshot.map { "'\(claim.holder.name)' (snapshot '\($0.name)')" }
                    ?? "'\(claim.holder.name)'"
            }.joined(separator: ", ")
            #log(
                Self.logger, .warning,
                "MAC address \(mac, privacy: .public) is held by \(names, privacy: .public)")
        }
    }

    /// The first live VM sharing `config`'s MAC address on the network `config`
    /// joins, if any.
    ///
    /// Live means VZ holds the attachment, as it does for the machine identity.
    /// The mode names the network, so two holders collide only where both
    /// guests attach: networking off puts no address on a wire, and Shared,
    /// Host Only and Bridged are separate networks. Two bridged VMs compare as
    /// one network whatever interface each names — Automatic resolves at start,
    /// so which link they land on is not knowable in advance. A snapshot's
    /// claim is never live: the running guest is on its configuration's
    /// address.
    func liveMACAddressConflict(
        for config: VMConfiguration, excluding instance: VMInstance
    ) -> VMInstance? {
        guard config.networkEnabled, let mac = config.macAddress else { return nil }
        return claims(on: mac, otherThan: instance).first { claim in
            let other = claim.holder
            return claim.snapshot == nil
                && (other.isActive || other.isLivePaused)
                && other.configuration.networkEnabled
                && other.configuration.networkMode == config.networkMode
        }?.holder
    }
}
