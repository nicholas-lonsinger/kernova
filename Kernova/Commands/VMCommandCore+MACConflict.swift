import Foundation
import KernovaKit

/// The refusal a MAC address conflict raises: another active VM uses the VM's
/// MAC address on the network it would join.
///
/// A MAC address on one network is never overridden, so the way through is a
/// change to the VM's network, each a `setConfiguration` step of its own. A
/// route is offered only when every step in it passes its gates now, or — for
/// a write that follows a discard — once that discard lands.
extension VMCommandCore {
    /// One change to a VM's network that removes a MAC address conflict.
    private enum NetworkChange: CaseIterable {
        case ownNetwork, newAddress, noNetwork

        var assignment: ConfigurationEntry {
            switch self {
            case .ownNetwork:
                VMConfigurationKeyRegistry.networkMembership.assigning(VMNetworkMembership.isolated.rawValue)
            case .newAddress:
                VMConfigurationKeyRegistry.networkMAC.assigning(VMConfigurationKeyRegistry.newMACAddressValue)
            case .noNetwork:
                VMConfigurationKeyRegistry.networkMode.assigning(VMConfigurationKeyRegistry.noNetworkValue)
            }
        }

        var key: VMConfigurationKey {
            switch self {
            case .ownNetwork: VMConfigurationKeyRegistry.networkMembership
            case .newAddress: VMConfigurationKeyRegistry.networkMAC
            case .noNetwork: VMConfigurationKeyRegistry.networkMode
            }
        }

        var title: String {
            switch self {
            case .ownNetwork: "Move to a Network of Its Own"
            case .newAddress: "Use a New MAC Address"
            case .noNetwork: "Turn Off Networking"
            }
        }

        var phrase: String {
            switch self {
            case .ownNetwork: "move it to a network of its own"
            case .newAddress: "give it a new MAC address"
            case .noNetwork: "turn its networking off"
            }
        }
    }

    // MARK: - Bring-up

    /// The refusal a MAC address conflict at the bring-up `verb` performs
    /// raises, with the routes that change the VM's network first.
    ///
    /// A revert has none: it installs the snapshot's network
    /// (``VMConfiguration/adoptingSnapshotState(_:)``), so a change made
    /// before it is overwritten. A running VM's restart takes only a network
    /// of its own, the one of these changes a live VM's gates admit.
    func duplicateMACAddressRequirement(
        _ conflict: VMIdentityConflict, on instance: VMInstance, verb: VMVerb?
    ) -> StepRequirement {
        let vm = "\u{201C}\(instance.name)\u{201D}"
        let other = "\u{201C}\(conflict.other.name)\u{201D}"
        let heldElsewhere = conflict.other.heldByAnotherCopy
        let shared = CommandErrorDTO.sharedMACAddressSentences(
            vm: instance.name, other: conflict.other.name, otherHeldByAnotherCopy: heldElsewhere)
        guard verb != .revertToSnapshot else {
            let stopOther = heldElsewhere ? "" : " Stop \(other) first, or"
            let stopThis = heldElsewhere ? " Stop \(vm)" : " stop \(vm)"
            return StepRequirement(
                title: ConflictReason.macAddress.title,
                message: shared + stopOther + stopThis
                    + " and then revert it: it comes back suspended, and its network can be changed before it resumes."
            )
        }
        let changes = duplicateMACAddressChanges(on: instance, verb: verb)
        var sentences = [shared]
        if changes.contains(where: { $0.discards }) {
            let keeps = changes.contains { $0.change == .ownNetwork }
            sentences.append(
                "A saved state does not restore under a new MAC address or without its network device, "
                    + "so those changes discard \(vm)\u{2019}s saved state"
                    + (keeps ? "; a network of its own keeps it." : "."))
        }
        if changes.isEmpty {
            sentences.append(
                heldElsewhere
                    ? "Change \(vm)\u{2019}s network or MAC address first."
                    : "Stop \(other) first, or change \(vm)\u{2019}s network or MAC address.")
        } else {
            sentences.append(
                (heldElsewhere
                    ? "Change \(vm)\u{2019}s network first: "
                    : "Stop \(other), or change \(vm)\u{2019}s network first: ")
                    + Self.orList(changes.map(\.change.phrase)) + ".")
        }
        let summary = summary(instance)
        return StepRequirement(
            title: ConflictReason.macAddress.title, message: sentences.joined(separator: " "),
            routes: changes.map { change, discards in
                StepRoute(
                    title: change.title,
                    steps: (discards ? [.discardSavedState(vm: summary)] : [])
                        + [.setConfiguration(vm: summary, assignments: [change.assignment])])
            })
    }

    /// The changes `instance` can take before the bring-up `verb` performs,
    /// each with whether it discards the saved state first — in the order a
    /// surface offers them.
    ///
    /// A saved state restores under neither another MAC address nor without
    /// its network device
    /// (docs/research/2026-09-23-vz-restore-requires-the-saved-mac-address.md,
    /// docs/research/2026-09-30-vz-restore-matches-machine-shape-and-device-set.md),
    /// so those two changes discard it first; a network of its own keeps it
    /// where the state's gate admits the move.
    private func duplicateMACAddressChanges(
        on instance: VMInstance, verb: VMVerb?
    ) -> [(change: NetworkChange, discards: Bool)] {
        guard instance.configuration.networkEnabled else { return [] }
        return NetworkChange.allCases.compactMap { change in
            switch change {
            case .ownNetwork:
                // An Ephemeral Mode VM's power-off reverts it to its baseline's
                // settings before a restart's boot, undoing the move.
                guard
                    verb != .restart || instance.ephemeralBaselineSnapshot == nil,
                    let membership = instance.configuration.effectiveNetworkMembership,
                    membership != .isolated,
                    capabilities.isAvailable(
                        change.key, writing: change.assignment.value, on: instance)
                else { return nil }
                return (change, false)
            case .newAddress, .noNetwork:
                guard instance.hasSaveFile else {
                    guard
                        capabilities.isAvailable(
                            change.key, writing: change.assignment.value, on: instance)
                    else { return nil }
                    return (change, false)
                }
                // An Ephemeral Mode VM's discard is a revert to its baseline,
                // and a warm one lands it holding a saved state again, which
                // the write is refused beside.
                guard instance.ephemeralBaselineSnapshot?.kind != .warm,
                    capabilities.accepts(.discardSavedState, on: instance),
                    capabilities.acceptsAsIfSavedStateDiscarded(
                        change.key.capability(
                            writing: change.assignment.value, for: instance.configuration.guestOS),
                        on: instance),
                    change.key.accepts(
                        change.assignment.value, for: instance, entitlements: library.entitlements,
                        networks: library.networks.state)
                else { return nil }
                return (change, true)
            }
        }
    }

    /// `items` joined as alternatives: "a", "a or b", "a, b, or c".
    private static func orList(_ items: [String]) -> String {
        guard items.count > 2 else { return items.joined(separator: " or ") }
        return items.dropLast().joined(separator: ", ") + ", or " + items[items.count - 1]
    }

    // MARK: - Live Edit

    /// The one refusal a configuration write the MAC address registry turned
    /// away raises: a network of its own, then the same write again, where
    /// the VM can take that; the conflict otherwise.
    ///
    /// Offered only for a write that left the membership alone, so taking the
    /// route and asking again lands the write on a network of its own.
    func macAddressRefusal(
        _ conflict: VMMACAddressRegistry.MACAddressConflict, on instance: VMInstance
    ) -> CommandError {
        let change = NetworkChange.ownNetwork
        guard conflict.reason == .macAddress,
            conflict.source.networkMembership == conflict.target.networkMembership,
            joinsAttachableOwnNetwork(conflict.target),
            capabilities.isAvailable(change.key, writing: change.assignment.value, on: instance)
        else {
            return .conflict(
                vm: summary(instance), with: summary(conflict.other), reason: conflict.reason)
        }
        return .stepRequired(
            StepRequirement(
                title: ConflictReason.macAddress.title,
                message: CommandErrorDTO.sharedMACAddressSentences(
                    vm: instance.name, other: conflict.other.name,
                    otherHeldByAnotherCopy: conflict.other.heldByAnotherCopy)
                    + " Move \u{201C}\(instance.name)\u{201D} to a network of its own first, then make this change.",
                routes: [
                    StepRoute(
                        title: "Join a Network of Its Own",
                        steps: [.setConfiguration(vm: summary(instance), assignments: [change.assignment])])
                ]))
    }

    /// Whether `configuration`, moved to a network of its own, joins one this
    /// build can attach — `false` where it joins no shared app-managed
    /// network.
    private func joinsAttachableOwnNetwork(_ configuration: VMConfiguration) -> Bool {
        guard let membership = configuration.effectiveNetworkMembership, membership != .isolated
        else { return false }
        var moved = configuration
        moved.networkMembership = .isolated
        return moved.joinedNetwork.map(library.entitlements.canAttach) ?? false
    }
}
