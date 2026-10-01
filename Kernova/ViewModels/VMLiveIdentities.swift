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
    /// collides.
    ///
    /// Every other VM at rest is first caught up with another copy of
    /// Kernova (``VMActivity/refreshFromBundle()``), so a VM that copy holds
    /// claims the identity its bundle carries now. The machine identity is
    /// checked only while ``AppPreferences/blockDuplicateMachineIDBoot`` asks
    /// for it. Two VMs that are exact copies of each other
    /// (``VMIdentityKinship/exactCopy``) are refused as the pair.
    func conflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration
    ) -> VMIdentityConflict? {
        for other in instances where other !== instance {
            other.activity.refreshFromBundle()
        }
        if preferences.blockDuplicateMachineIDBoot,
            let other = instances.first(where: {
                $0 !== instance && $0.claimsIdentity && instance.sharesMachineIdentity(with: $0)
            })
        {
            let reason: ConflictReason =
                instance.kinship(with: other, bringingUp: configuration) == .exactCopy
                ? .exactCopy(bar: .runningAtOnce) : .machineIdentity
            return VMIdentityConflict(vm: instance, other: other, reason: reason)
        }
        if let other = macAddresses.liveMACAddressConflict(for: configuration, excluding: instance) {
            let reason: ConflictReason =
                instance.kinship(with: other, bringingUp: configuration) == .exactCopy
                ? .exactCopy(bar: .oneNetwork) : .macAddress
            return VMIdentityConflict(vm: instance, other: other, reason: reason)
        }
        return nil
    }
}

/// A bring-up refused because another VM already claims the identity it would
/// put in front of VZ (``VMInstance/claimsIdentity``).
struct VMIdentityConflict: LocalizedError {
    /// The VM already claiming the identity.
    let other: VMInstance
    /// What the two would share.
    let reason: ConflictReason
    /// The sentence every surface words this refusal in, fixed at the refusal
    /// because the names it carries — and whether the claim is another copy of
    /// Kernova's hold — are read on the main actor.
    let errorDescription: String?

    @MainActor
    init(vm: VMInstance, other: VMInstance, reason: ConflictReason) {
        self.other = other
        self.reason = reason
        self.errorDescription = CommandErrorDTO.conflictMessage(
            vm: vm.name, other: other.name, otherHeldByAnotherCopy: other.heldByAnotherCopy,
            reason: reason)
    }
}
