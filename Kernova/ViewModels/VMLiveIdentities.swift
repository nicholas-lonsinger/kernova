import Foundation
import KernovaKit
import KernovaLogging

/// Which identity another live VM already claims — the refusal every bring-up
/// passes (``VMInstance/beginBringUp(_:)``).
///
/// Live means VZ holds the identity, or a bring-up that will hand it to VZ is
/// under way: any active phase, or paused with the virtual machine still in
/// memory. A cold-paused VM has released it, and blocking its twin on a saved
/// state that claims nothing would be wrong.
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

    /// The live VM whose identity bringing `instance` up would duplicate, and
    /// what on — `nil` when nothing collides.
    ///
    /// The machine identity is checked only while
    /// ``AppPreferences/blockDuplicateMachineIDBoot`` asks for it.
    func conflict(for instance: VMInstance) -> VMIdentityConflict? {
        if preferences.blockDuplicateMachineIDBoot,
            let other = liveMachineIDConflict(for: instance)
        {
            return VMIdentityConflict(vm: instance, other: other, reason: .machineIdentity)
        }
        if let other = macAddresses.liveMACAddressConflict(
            for: instance.configuration, excluding: instance)
        {
            return VMIdentityConflict(vm: instance, other: other, reason: .macAddress)
        }
        return nil
    }

    /// The first live VM holding a machine identity matching `instance`'s.
    private func liveMachineIDConflict(for instance: VMInstance) -> VMInstance? {
        instances.first { other in
            other !== instance
                && (other.isActive || other.isLivePaused)
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

/// A bring-up refused because another live VM already claims the identity it
/// would put in front of VZ.
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

    /// The live VM already holding the identity.
    let other: VMInstance
    let reason: Reason
    /// The sentence every surface words this refusal in, fixed at the refusal
    /// because the names it carries are read on the main actor.
    let errorDescription: String?

    @MainActor
    init(vm: VMInstance, other: VMInstance, reason: Reason) {
        self.other = other
        self.reason = reason
        self.errorDescription = CommandErrorDTO.conflictMessage(
            vm: vm.name, other: other.name, reason: reason.conflictReason)
    }
}
