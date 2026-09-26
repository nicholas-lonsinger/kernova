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
    /// for it.
    func conflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration
    ) -> VMIdentityConflict? {
        for other in instances where other !== instance {
            other.activity.refreshFromBundle()
        }
        if preferences.blockDuplicateMachineIDBoot,
            let other = liveMachineIDConflict(for: instance)
        {
            return VMIdentityConflict(vm: instance, other: other, reason: .machineIdentity)
        }
        if let other = macAddresses.liveMACAddressConflict(for: configuration, excluding: instance) {
            return VMIdentityConflict(vm: instance, other: other, reason: .macAddress)
        }
        return nil
    }

    /// The first VM claiming a machine identity matching `instance`'s.
    private func liveMachineIDConflict(for instance: VMInstance) -> VMInstance? {
        instances.first { other in
            other !== instance
                && other.claimsIdentity
                && Self.sharesMachineIdentifier(instance, other)
        }
    }

    /// Whether two VMs would claim the same machine identity.
    ///
    /// macOS identifiers compare the *effective* value, which falls back to the
    /// bundle's identifier file exactly as the boot path does; generic
    /// identifiers have no such file, so they compare configuration fields.
    private static func sharesMachineIdentifier(_ a: VMInstance, _ b: VMInstance) -> Bool {
        if let lhs = a.effectiveMachineIdentifierData, let rhs = b.effectiveMachineIdentifierData,
            lhs == rhs
        {
            return true
        }
        if let lhs = a.configuration.genericMachineIdentifierData,
            let rhs = b.configuration.genericMachineIdentifierData,
            lhs == rhs
        {
            return true
        }
        return false
    }
}

/// A bring-up refused because another VM already claims the identity it would
/// put in front of VZ (``VMInstance/claimsIdentity``).
struct VMIdentityConflict: LocalizedError {
    /// What the two VMs would share.
    enum Reason: Sendable {
        case machineIdentity
        case macAddress

        /// The reason in the command vocabulary.
        var conflictReason: ConflictReason {
            switch self {
            case .machineIdentity: .machineIdentity
            case .macAddress: .macAddress
            }
        }
    }

    /// The VM already claiming the identity.
    let other: VMInstance
    let reason: Reason
    /// The sentence every surface words this refusal in, fixed at the refusal
    /// because the names it carries — and whether the claim is another copy of
    /// Kernova's hold — are read on the main actor.
    let errorDescription: String?

    @MainActor
    init(vm: VMInstance, other: VMInstance, reason: Reason) {
        self.other = other
        self.reason = reason
        self.errorDescription = CommandErrorDTO.conflictMessage(
            vm: vm.name, other: other.name, otherHeldByAnotherCopy: other.heldByAnotherCopy,
            reason: reason.conflictReason)
    }
}
