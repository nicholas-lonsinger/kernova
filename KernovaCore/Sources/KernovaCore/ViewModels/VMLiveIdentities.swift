import Foundation
import KernovaCommandModel
import KernovaLogging

/// Which identity another VM already claims — the identity term admission
/// decides every bring-up against (``VMAdmission/Facts/identityConflict``),
/// and the disk images a running VM's live edit may not open. A claim is
/// ``VMInstance/claimsIdentity``: a machine identity, a MAC address, and each
/// external disk image the VM has open (``VMInstance/claimedDiskImages``).
///
/// An external disk image is open in at most one active VM, except that
/// several may each have it read-only: VZ locks a writable image exclusively
/// and a read-only one shared
/// (`docs/research/2026-09-23-two-instances-same-vm.md`). Identity is the
/// path — the stored one on both sides, and the holder's resolved one too —
/// so two spellings of one file that neither bookmark exposes are left to
/// VZ's lock.
@MainActor
final class VMLiveIdentities {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMLiveIdentities")

    /// Which VMs exist. Weak and assigned after construction: the library owns
    /// this, so a strong reference back would be a cycle.
    weak var roster: (any VMInstanceRoster)?

    private let macAddresses: VMMACAddressRegistry
    private let preferences: AppPreferences

    init(macAddresses: VMMACAddressRegistry, preferences: AppPreferences) {
        self.macAddresses = macAddresses
        self.preferences = preferences
    }

    private var instances: [VMInstance] {
        guard let roster else {
            Self.logger.log(.fault, "VMLiveIdentities has no roster — answering as an empty library")
            assertionFailure("VMLiveIdentities.roster was never assigned")
            return []
        }
        return roster.instances
    }

    /// The VM claiming the identity bringing `instance` up under
    /// `configuration` would duplicate, and what on — `nil` when nothing
    /// collides, or when the only collision is a machine identity `override`
    /// waives.
    ///
    /// Every other VM's claim is first caught up with another copy of Kernova
    /// (``VMActivity/refreshClaim()``), so a VM that copy holds claims the
    /// identity its bundle carries now. A disk image is answered first: never
    /// waived and offering no route, so a start it refuses asks no question
    /// and changes no network. A shared machine identity is next: waived only
    /// while ``AppPreferences/allowsDuplicateMachineIDOverride`` is on, by a
    /// confirmed override or by the standing choice not to be asked
    /// (``AppPreferences/duplicateMachineIDQuestionDismissed``), and otherwise
    /// offered for confirmation only to a request that can ask. A MAC address
    /// is never waived, and is answered only once nothing else stands in the
    /// way, so the change of network its refusal routes through is the last
    /// step the bring-up needs.
    func conflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration,
        override: VMIdentityOverride
    ) -> VMIdentityConflict? {
        for other in instances where other !== instance {
            other.activity.refreshClaim()
        }
        let candidates = Self.diskImages(of: configuration, on: instance)
        if let conflict = diskImageConflict(for: instance, opening: candidates, under: configuration) {
            return conflict
        }
        let identityTwin = instances.first {
            $0 !== instance && $0.claimsIdentity && instance.sharesMachineIdentity(with: $0)
        }
        if let identityTwin {
            guard preferences.allowsDuplicateMachineIDOverride else {
                return VMIdentityConflict(
                    vm: instance, other: identityTwin, reason: .machineIdentity(overrideSettingOn: false),
                    configuration: configuration)
            }
            guard override.confirmed || preferences.duplicateMachineIDQuestionDismissed else {
                return VMIdentityConflict(
                    vm: instance, other: identityTwin, reason: .machineIdentity(overrideSettingOn: true),
                    configuration: configuration, asks: override.canAsk)
            }
        }
        if let other = macAddresses.liveMACAddressConflict(for: configuration, excluding: instance) {
            return VMIdentityConflict(
                vm: instance, other: other, reason: .macAddress, configuration: configuration)
        }
        if let identityTwin {
            let consent = override.confirmed ? "as the user confirmed" : "as the user chose not to be asked again"
            Self.logger.log(
                .notice,
                "Starting '\(instance.name, privacy: .public)' beside '\(identityTwin.name, privacy: .public)', which has the same machine identity, \(consent, privacy: .public)"
            )
        }
        return nil
    }

    /// The VM another active VM's disk image refuses a live edit of `instance`
    /// moving `old` to `new` on, or `nil` when nothing collides or `instance`
    /// is not live.
    ///
    /// Judges only the removable media the edit adds — an entry added,
    /// re-pointed, or turned writable — since only removable media reaches a
    /// running VM; a VM already in a collision stays editable to leave it.
    /// Runs inside the coordinated write, so it reads each claim as it stands
    /// and catches none up with another copy.
    func diskImageConflict(
        on instance: VMInstance, movingFrom old: VMConfiguration, to new: VMConfiguration
    ) -> VMIdentityConflict? {
        guard instance.holdsLiveIdentity else { return nil }
        let before = Dictionary(
            Self.diskImages(of: old, on: instance).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = Self.diskImages(of: new, on: instance).filter { reference in
            guard reference.kind == .removableMedia else { return false }
            guard let prior = before[reference.id] else { return true }
            return prior.path != reference.path || (prior.readOnly && !reference.readOnly)
        }
        return diskImageConflict(for: instance, opening: added, under: new)
    }

    /// The external disk images `configuration` has `instance` open, a
    /// guest-agent installer entry aside: each VM is attached its own copy.
    private static func diskImages(
        of configuration: VMConfiguration, on instance: VMInstance
    ) -> [ExternalFileReference] {
        let agents = instance.bundleProducts.guestAgents
        return configuration.externalFileReferences.filter {
            $0.kind.isDiskImage && !agents.isInstallerDisk(path: $0.path)
        }
    }

    /// The first claim, in candidate order and then library order, that
    /// another active VM holds on one of `candidates` with either side
    /// writable.
    ///
    /// A candidate is named by its stored path alone, so nothing resolves a
    /// bookmark or touches the file on the main actor.
    private func diskImageConflict(
        for instance: VMInstance, opening candidates: [ExternalFileReference],
        under configuration: VMConfiguration
    ) -> VMIdentityConflict? {
        guard !candidates.isEmpty else { return nil }
        let holders = instances.lazy.filter { $0 !== instance }.map { ($0, $0.claimedDiskImages) }
            .filter { !$0.1.isEmpty }
        for candidate in candidates {
            let identities = ExternalFileReference.fileIdentities(forPath: candidate.path, resolvedTarget: nil)
            for (other, claims) in holders {
                guard
                    let claim = claims.first(where: {
                        !$0.identities.isDisjoint(with: identities) && ($0.writable || !candidate.readOnly)
                    })
                else { continue }
                return VMIdentityConflict(
                    vm: instance, other: other,
                    reason: .diskImage(
                        label: candidate.label, writableHere: !candidate.readOnly,
                        writableThere: claim.writable),
                    configuration: configuration)
            }
        }
        return nil
    }
}

/// One external disk image an active VM has open
/// (``VMInstance/claimedDiskImages``).
struct DiskImageClaim {
    /// The canonical paths that name the file
    /// (``ExternalFileReference/fileIdentities(forPath:resolvedTarget:)``).
    let identities: Set<String>
    /// Whether the VM has it open for writing.
    let writable: Bool
}

/// What a bring-up's request can do about another active VM claiming its
/// identity — decided by whoever asked for the bring-up, never stored. The
/// standing choice not to be asked is a preference
/// ``VMLiveIdentities/conflict(for:bringingUp:override:)`` reads beside it.
///
/// Two independent facts: whether the user confirmed starting beside a VM
/// sharing its machine identity, and whether anyone is there to be asked. A
/// boot chained after the call that asked carries the first and never the
/// second, so it asks nothing.
package struct VMIdentityOverride: Sendable, Equatable {
    /// The user confirmed starting beside a VM sharing its machine identity.
    let confirmed: Bool
    /// Someone is there to answer a question, so a shared machine identity's
    /// refusal offers starting anyway.
    let canAsk: Bool

    /// Nobody is there to confirm — a start at launch — so the bring-up is
    /// refused.
    static let unavailable = VMIdentityOverride(confirmed: false, canAsk: false)
    /// Someone can be asked, nothing confirmed yet.
    static let askable = VMIdentityOverride(confirmed: false, canAsk: true)
    /// The user confirmed starting anyway, and can still be asked.
    static let confirmed = VMIdentityOverride(confirmed: true, canAsk: true)

    /// The override a caller holding `consent` brings.
    init(_ consent: Consent) {
        self = consent.covers(.startBesideSharedMachineIdentity) ? .confirmed : .askable
    }

    private init(confirmed: Bool, canAsk: Bool) {
        self.confirmed = confirmed
        self.canAsk = canAsk
    }

    /// This override for a bring-up that runs with nobody to ask — a boot
    /// chained after the call that asked: a confirmation carries over, and a
    /// question becomes a refusal.
    var unattended: VMIdentityOverride {
        VMIdentityOverride(confirmed: confirmed, canAsk: false)
    }
}

/// A bring-up refused because another VM already claims the identity it would
/// put in front of VZ (``VMInstance/claimsIdentity``).
package struct VMIdentityConflict: LocalizedError {
    /// The VM already claiming the identity.
    let other: VMInstance
    /// What the two would share.
    let reason: ConflictReason
    /// The configuration the refused bring-up would have put in front of VZ.
    let configuration: VMConfiguration
    /// Whether the request can be asked to start anyway beside a VM sharing
    /// its machine identity
    /// (``ConfirmationKind/startBesideSharedMachineIdentity``); always `false`
    /// for a MAC address or a disk image, which are never overridden.
    let asks: Bool
    /// The sentence every surface words this refusal in, fixed at the refusal
    /// because the names it carries — and whether the claim is another copy of
    /// Kernova's hold — are read on the main actor.
    package let errorDescription: String?

    @MainActor
    init(
        vm: VMInstance, other: VMInstance, reason: ConflictReason, configuration: VMConfiguration,
        asks: Bool = false
    ) {
        self.other = other
        self.reason = reason
        self.configuration = configuration
        self.asks = asks
        self.errorDescription = CommandErrorDTO.conflictMessage(
            vm: vm.name, other: other.name, otherHeldByAnotherCopy: other.heldByAnotherCopy,
            reason: reason)
    }
}
