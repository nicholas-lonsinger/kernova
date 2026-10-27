import Foundation
import KernovaCommandModel

/// The refusal a MAC address conflict raises: another active VM uses the VM's
/// MAC address on the network it would join.
///
/// A MAC address on one network is never overridden, so the way through is a
/// change to the VM's network, each a `setConfiguration` step of its own. A
/// route is offered only when, once its steps are taken, the refused verb is
/// admitted.
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

    /// Why the changes that discard a saved state are not offered, where the
    /// user is owed the reason.
    private enum DiscardWithheld {
        /// The discard is a revert to a warm Ephemeral Mode baseline, which
        /// lands the VM on a saved state again, beside which the write is
        /// refused.
        case ephemeralBaselineHoldsSavedState(VMSnapshot)
        /// A restart's power-off returns an Ephemeral Mode VM to its baseline,
        /// network included, before the boot.
        case restartReturnsToBaseline(VMSnapshot)
    }

    /// The changes a bring-up can be routed through, each with the discard
    /// it is taken after and the request it ends with, and why those that
    /// need a discard are not, when they are not.
    private struct NetworkChanges {
        var offered: [(change: NetworkChange, discard: VMSavedStateDiscard?, ending: StepRoute.Ending)] = []
        var withheld: DiscardWithheld?
    }

    /// The refusal a MAC address conflict at the bring-up `verb` performs
    /// raises, with the routes that change the VM's network first.
    ///
    /// A route is offered only when, once its steps are taken, the request it
    /// ends with is admitted: `verb` asked again, or a start where a discard
    /// leaves nothing to resume. A revert has none: it installs the snapshot's
    /// network (``VMConfiguration/adoptingSnapshotState(_:)``), so a change
    /// made before it is overwritten.
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
        if let discard = changes.offered.lazy.compactMap(\.discard).first {
            let keeps = changes.offered.contains { $0.change == .ownNetwork }
            sentences.append(
                "A saved state does not restore under a new MAC address or without its network device, "
                    + "so those changes discard \(vm)\u{2019}s saved state"
                    + (keeps ? "; a network of its own keeps it." : "."))
            if case .revertsToBaseline(let baseline) = discard {
                sentences.append(Self.ephemeralDiscardSentences(instance, baseline: baseline))
            }
        }
        switch changes.withheld {
        case .ephemeralBaselineHoldsSavedState(let baseline):
            sentences.append(
                "\(vm) is ephemeral, and discarding its saved state returns it to "
                    + "\u{201C}\(baseline.name)\u{201D}, which holds one too, so a new MAC address "
                    + "or no network device needs Ephemeral Mode turned off first.")
        case .restartReturnsToBaseline(let baseline):
            sentences.append(
                "\(vm) is ephemeral, so a restart returns it to \u{201C}\(baseline.name)\u{201D}, "
                    + "network included, before it starts again.")
        case nil:
            break
        }
        if changes.offered.contains(where: { if case .start = $0.ending { true } else { false } }) {
            sentences.append(
                "A new MAC address or no network device discards \(vm)\u{2019}s saved state, "
                    + "so it then starts rather than resumes.")
        }
        if !changes.offered.isEmpty {
            sentences.append(
                (heldElsewhere
                    ? "Change \(vm)\u{2019}s network first: "
                    : "Stop \(other), or change \(vm)\u{2019}s network first: ")
                    + DataFormatters.alternatives(changes.offered.map(\.change.phrase)) + ".")
        } else if changes.withheld != nil {
            if !heldElsewhere { sentences.append("Stop \(other) first.") }
        } else {
            sentences.append(
                heldElsewhere
                    ? "Change \(vm)\u{2019}s network or MAC address first."
                    : "Stop \(other) first, or change \(vm)\u{2019}s network or MAC address.")
        }
        let summary = summary(instance)
        return StepRequirement(
            title: ConflictReason.macAddress.title, message: sentences.joined(separator: " "),
            routes: changes.offered.map { change, discard, ending in
                StepRoute(
                    title: change.title,
                    steps: (discard == nil ? [] : [.discardSavedState(vm: summary)])
                        + [.setConfiguration(vm: summary, assignments: [change.assignment])],
                    ending: ending)
            })
    }

    /// The changes `instance` can take before the bring-up `verb` performs —
    /// in the order a surface offers them.
    ///
    /// A saved state restores under neither another MAC address nor without
    /// its network device
    /// (docs/research/2026-09-23-vz-restore-requires-the-saved-mac-address.md,
    /// docs/research/2026-09-30-vz-restore-matches-machine-shape-and-device-set.md),
    /// so those two changes follow the stop's discard, judged where that
    /// discard lands (``VMSavedStateDiscard/landing``); a network of its own
    /// keeps it where the state's gate admits the move.
    private func duplicateMACAddressChanges(
        on instance: VMInstance, verb: VMVerb?
    ) -> NetworkChanges {
        var changes = NetworkChanges()
        guard instance.configuration.networkEnabled else { return changes }
        for change in NetworkChange.allCases {
            let value = change.assignment.value
            switch change {
            case .ownNetwork:
                guard let membership = instance.configuration.effectiveNetworkMembership,
                    membership != .isolated,
                    capabilities.isAvailable(change.key, writing: value, on: instance)
                else { continue }
                if verb == .restart, let baseline = instance.ephemeralBaselineSnapshot {
                    changes.withheld = .restartReturnsToBaseline(baseline)
                    continue
                }
                changes.offered.append((change, nil, .refusedVerb))
            case .newAddress, .noNetwork:
                guard let discard = instance.savedStateDiscard else {
                    if capabilities.isAvailable(change.key, writing: value, on: instance) {
                        changes.offered.append((change, nil, .refusedVerb))
                    }
                    continue
                }
                guard capabilities.accepts(.discardSavedState, on: instance),
                    change.key.accepts(
                        value, for: instance, entitlements: library.entitlements,
                        networks: library.networks.state,
                        resourceLimits: library.virtualizationHost.resourceLimits)
                else { continue }
                let capability = change.key.capability(
                    writing: value, for: instance.configuration.guestOS)
                guard capabilities.accepts(capability, on: instance, after: discard) else {
                    if case .revertsToBaseline(let baseline) = discard, discard.landing.holdsSaveFile {
                        changes.withheld = .ephemeralBaselineHoldsSavedState(baseline)
                    }
                    continue
                }
                let ending: StepRoute.Ending
                if bringUpAdmitted(verb, on: instance, after: discard) {
                    ending = .refusedVerb
                } else if bringUpAdmitted(.start, on: instance, after: discard) {
                    ending = .start(vm: summary(instance))
                } else {
                    continue
                }
                changes.offered.append((change, discard, ending))
            }
        }
        return changes
    }

    /// Whether the bring-up `verb` names is admitted once `discard` lands,
    /// identity aside — the route that discarded on its way there changed the
    /// VM's network.
    private func bringUpAdmitted(
        _ verb: VMVerb?, on instance: VMInstance, after discard: VMSavedStateDiscard
    ) -> Bool {
        let request: VMAdmission.Request = verb == .resume ? .resume : .start(recovery: false)
        switch instance.activity.decide(request, posture: .commit, after: discard) {
        case .admit, .join, .wait: return true
        case .refuse: return false
        }
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
                        steps: [.setConfiguration(vm: summary(instance), assignments: [change.assignment])],
                        ending: .refusedVerb)
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
