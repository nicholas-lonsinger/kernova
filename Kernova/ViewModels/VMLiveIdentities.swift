import Foundation
import KernovaKit
import KernovaLogging

/// Which identity another VM already claims — the identity term admission
/// decides every bring-up against (``VMAdmission/Facts/identityConflict``). A
/// claim is ``VMInstance/claimsIdentity``.
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
            #log(Self.logger, .fault, "VMLiveIdentities has no roster — answering as an empty library")
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
    /// Every other VM at rest is first caught up with another copy of
    /// Kernova (``VMActivity/refreshFromBundle()``), so a VM that copy holds
    /// claims the identity its bundle carries now. A MAC address is checked
    /// first and never waived; a request that can ask is offered changing the
    /// VM's network instead. A shared machine identity is waived only by a
    /// confirmed override while ``AppPreferences/allowsDuplicateMachineIDOverride``
    /// is on, and is offered for confirmation only to a request that can ask.
    func conflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration,
        override: VMIdentityOverride
    ) -> VMIdentityConflict? {
        for other in instances where other !== instance {
            other.activity.refreshFromBundle()
        }
        if let other = macAddresses.liveMACAddressConflict(for: configuration, excluding: instance) {
            return VMIdentityConflict(
                vm: instance, other: other, reason: .macAddress, configuration: configuration,
                asks: override.canAsk)
        }
        guard
            let other = instances.first(where: {
                $0 !== instance && $0.claimsIdentity && instance.sharesMachineIdentity(with: $0)
            })
        else { return nil }
        guard preferences.allowsDuplicateMachineIDOverride else {
            return VMIdentityConflict(
                vm: instance, other: other, reason: .machineIdentity, configuration: configuration)
        }
        guard override.confirmed else {
            return VMIdentityConflict(
                vm: instance, other: other, reason: .machineIdentity, configuration: configuration,
                asks: override.canAsk)
        }
        #log(
            Self.logger, .notice,
            "Starting '\(instance.name, privacy: .public)' beside '\(other.name, privacy: .public)', which has the same machine identity, as the user confirmed"
        )
        return nil
    }
}

/// What a bring-up's request can do about another active VM claiming its
/// identity — decided by whoever asked for the bring-up, never stored.
///
/// Two independent facts: whether the user confirmed starting beside a VM
/// sharing its machine identity, and whether anyone is there to be asked. A
/// boot chained after the call that asked carries the first and never the
/// second, so it asks nothing.
struct VMIdentityOverride: Sendable, Equatable {
    /// The user confirmed starting beside a VM sharing its machine identity.
    let confirmed: Bool
    /// Someone is there to answer a question, so a refusal offers its way
    /// through — starting anyway, or changing the VM's network.
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
struct VMIdentityConflict: LocalizedError {
    /// The VM already claiming the identity.
    let other: VMInstance
    /// What the two would share.
    let reason: ConflictReason
    /// The configuration the refused bring-up would have put in front of VZ.
    let configuration: VMConfiguration
    /// Whether the request can be asked a way through: starting anyway
    /// (``ConfirmationKind/startBesideSharedMachineIdentity``) for a machine
    /// identity, and a change to the VM's network (``MACAddressRemedy``) for a
    /// MAC address.
    let asks: Bool
    /// The sentence every surface words this refusal in, fixed at the refusal
    /// because the names it carries — and whether the claim is another copy of
    /// Kernova's hold — are read on the main actor.
    let errorDescription: String?

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
