import Foundation
import KernovaKit
import KernovaLogging

/// The way out of a MAC address conflict at a bring-up: a change to the VM's
/// network, chosen by the caller and carried by the request that asked for the
/// bring-up, never stored.
///
/// A MAC address on one network is never overridden, so every remedy removes
/// the conflict by changing the VM's configuration, and a bring-up decides
/// admission again once the change has landed.
extension VMCommandCore {
    // MARK: - Applicability

    /// Why `remedy` cannot be taken by a VM brought up under `configuration`,
    /// or `nil` when it can — the one rule both the offers and the write read.
    ///
    /// A network of its own is a Shared or Host Only VM's on its mode's common
    /// network, where this build can attach the VM's own network, and beside a
    /// saved state only where that state restores on it
    /// (``VMConfiguration/savedStateSurvivesMembershipMove``). A new address
    /// and no network are open to any VM with a network device.
    func macAddressRemedyRefusal(
        _ remedy: MACAddressRemedy, for configuration: VMConfiguration,
        holdingSavedState: Bool
    ) -> CommandError? {
        guard configuration.networkEnabled else {
            return .invalidArgument(
                "\u{201C}\(configuration.name)\u{201D} has no network device, so there is no network to change.")
        }
        switch remedy {
        case .ownNetwork:
            guard configuration.effectiveNetworkMembership == .common else {
                return .invalidArgument(
                    "Only a Shared Network or Host Only virtual machine on its mode\u{2019}s common network can move to a network of its own."
                )
            }
            var moved = configuration
            Self.apply(.ownNetwork, to: &moved)
            if let network = moved.joinedNetwork, !library.entitlements.canAttach(network) {
                return .unsupportedByBuild(capability: network.entitledCapability)
            }
            guard !holdingSavedState || configuration.savedStateSurvivesMembershipMove else {
                return .invalidArgument(
                    "\u{201C}\(configuration.name)\u{201D}\u{2019}s saved state is not known to restore on a network of its own in this mode. Use a new MAC address, or turn networking off, instead."
                )
            }
            return nil
        case .newAddress, .noNetwork:
            return nil
        }
    }

    /// Whether taking `remedy` discards a saved state the VM holds: only a
    /// network of its own keeps one, since a saved state restores under
    /// neither another MAC address nor without its network device
    /// (docs/research/2026-09-23-vz-restore-requires-the-saved-mac-address.md,
    /// docs/research/2026-09-30-vz-restore-matches-machine-shape-and-device-set.md).
    static func discardsSavedState(_ remedy: MACAddressRemedy) -> Bool {
        remedy != .ownNetwork
    }

    /// Puts `remedy`'s change on `configuration`.
    static func apply(_ remedy: MACAddressRemedy, to configuration: inout VMConfiguration) {
        switch remedy {
        case .ownNetwork: configuration.networkMembership = .isolated
        case .newAddress: configuration.macAddress = GuestMACAddress.random()
        case .noNetwork: configuration.applyNetworkMode(nil)
        }
    }

    // MARK: - Offers

    /// The question a MAC address conflict a request can be asked about
    /// raises, worded for the bring-up `verb` performs.
    func macAddressRemedyPrompt(
        _ conflict: VMIdentityConflict, on instance: VMInstance, verb: VMVerb?
    ) -> MACAddressRemedyPrompt {
        let holdsSavedState = Self.holdsSavedStateAtBringUp(instance, verb: verb)
        let action = Self.bringUpTitle(verb)
        let offers = MACAddressRemedy.allCases.compactMap { remedy -> MACAddressRemedyOffer? in
            guard
                macAddressRemedyRefusal(
                    remedy, for: conflict.configuration, holdingSavedState: holdsSavedState) == nil
            else { return nil }
            let title =
                switch remedy {
                case .ownNetwork: "Move to a Network of Its Own and \(action)"
                case .newAddress: "Use a New MAC Address and \(action)"
                case .noNetwork: "Turn Off Networking and \(action)"
                }
            return MACAddressRemedyOffer(
                remedy: remedy, title: title,
                isDestructive: holdsSavedState && Self.discardsSavedState(remedy))
        }
        let vm = "\u{201C}\(instance.name)\u{201D}"
        let other = "\u{201C}\(conflict.other.name)\u{201D}"
        let heldElsewhere = conflict.other.heldByAnotherCopy
        var sentences = [
            "\(vm) has the same MAC address as \(other), "
                + (heldElsewhere ? "which another copy of Kernova is using." : "which is active."),
            "Two virtual machines with the same MAC address must not run on the same network at once.",
        ]
        if holdsSavedState, offers.contains(where: \.isDestructive) {
            let keeps = offers.contains { $0.remedy == .ownNetwork }
            sentences.append(
                "A saved state does not restore under a new MAC address or without its network device, "
                    + "so those choices discard \(vm)\u{2019}s saved state"
                    + (keeps ? "; a network of its own keeps it." : "."))
        }
        sentences.append(
            heldElsewhere
                ? "Change \(vm)\u{2019}s network:"
                : "Stop \(other), or change \(vm)\u{2019}s network:")
        return MACAddressRemedyPrompt(
            vm: summary(instance), other: summary(conflict.other), verb: verb ?? .start,
            title: ConflictReason.macAddress.title, message: sentences.joined(separator: " "),
            offers: offers, dismissTitle: "Cancel")
    }

    /// Whether the VM will hold a saved state when the bring-up `verb`
    /// performs reaches it: a revert that resumes restores its snapshot's, and
    /// a restart's boot follows the power-off an Ephemeral Mode VM answers
    /// with its baseline.
    private static func holdsSavedStateAtBringUp(_ instance: VMInstance, verb: VMVerb?) -> Bool {
        switch verb {
        case .revertToSnapshot: true
        case .restart: instance.ephemeralBaselineSnapshot?.kind == .warm
        default: instance.hasSaveFile
        }
    }

    /// The control a bring-up's offers name: the Resume a restore performs,
    /// the Restart, or the Start.
    static func bringUpTitle(_ verb: VMVerb?) -> String {
        switch verb {
        case .resume, .revertToSnapshot: "Resume"
        case .restart: "Restart"
        default: "Start"
        }
    }

    /// The one refusal a configuration write the MAC address registry turned
    /// away raises: the change of network a running VM can take instead where
    /// there is one, the conflict otherwise.
    func macAddressRefusal(
        _ conflict: VMMACAddressRegistry.MACAddressConflict, on instance: VMInstance
    ) -> CommandError {
        joinOwnNetworkRefusal(conflict, on: instance)
            ?? .conflict(
                vm: summary(instance), with: summary(conflict.other), reason: conflict.reason)
    }

    /// The refusal a running VM's network change onto a network another
    /// active VM uses its MAC address on raises when the VM could join a
    /// network of its own there instead — `nil` otherwise.
    ///
    /// Offers that one change alone: a new address or no network changes the
    /// hardware a live session is built from. A door re-issues its edit with
    /// the membership isolated.
    func joinOwnNetworkRefusal(
        _ conflict: VMMACAddressRegistry.MACAddressConflict, on instance: VMInstance
    ) -> CommandError? {
        guard conflict.reason == .macAddress,
            macAddressRemedyRefusal(.ownNetwork, for: conflict.target, holdingSavedState: false)
                == nil
        else { return nil }
        let vm = "\u{201C}\(instance.name)\u{201D}"
        let other = "\u{201C}\(conflict.other.name)\u{201D}"
        return .macAddressRemedyRequired(
            MACAddressRemedyPrompt(
                vm: summary(instance), other: summary(conflict.other), verb: .setConfiguration,
                title: ConflictReason.macAddress.title,
                message: "\(vm) has the same MAC address as \(other), "
                    + (conflict.other.heldByAnotherCopy
                        ? "which another copy of Kernova is using. "
                        : "which is active. ")
                    + "Two virtual machines with the same MAC address must not run on the same network at once. "
                    + "\(vm) can join a network of its own in that mode instead.",
                offers: [
                    MACAddressRemedyOffer(
                        remedy: .ownNetwork, title: "Join a Network of Its Own", isDestructive: false)
                ],
                dismissTitle: "Cancel"))
    }

    // MARK: - Taking a Remedy

    /// The remedy a bring-up the request decided as `decision` takes, `nil`
    /// when it takes none — refusing, before anything is written, whatever the
    /// bring-up would refuse once the remedy landed.
    ///
    /// A remedy given where `decision` is no MAC address conflict is logged
    /// and ignored: the conflict it answered has gone, or never was. The
    /// remedied configuration is decided against every other active VM, so a
    /// machine identity that still needs the user's confirmation is asked for
    /// now rather than after the change. `accountFor` names the start whose
    /// guest account the bring-up would ask about once the remedy landed —
    /// `nil` for a bring-up that answered for the account itself.
    func macAddressRemedyToTake(
        _ remedy: MACAddressRemedy?, answering decision: VMAdmission.Decision,
        on instance: VMInstance, identity: VMIdentityOverride, holdingSavedState: Bool,
        accountFor recovery: Bool?, verb: VMVerb
    ) throws -> MACAddressRemedy? {
        guard let remedy else { return nil }
        guard case .refuse(.identityConflict(let conflict)) = decision, conflict.reason == .macAddress
        else {
            #log(
                Self.logger, .notice,
                "Ignoring the MAC address remedy \(remedy.rawValue, privacy: .public) for '\(instance.name, privacy: .public)': its bring-up meets no MAC address conflict"
            )
            return nil
        }
        if let refusal = macAddressRemedyRefusal(
            remedy, for: conflict.configuration, holdingSavedState: holdingSavedState)
        {
            throw refusal
        }
        var remedied = conflict.configuration
        Self.apply(remedy, to: &remedied)
        if let remaining = library.identityConflict(
            for: instance, bringingUp: remedied, override: identity)
        {
            throw admissionRefusal(.identityConflict(remaining), on: instance, verb: verb)
        }
        if let recovery {
            let keeps = holdingSavedState && !Self.discardsSavedState(remedy)
            let facts = instance.admissionFacts
            _ = try guestProvisioning(
                for: instance,
                work: VMAdmission.startWork(
                    recovery: recovery, facts: keeps ? facts : facts.discardingSavedState()))
        }
        return remedy
    }

    /// Writes `remedy`'s change to `instance`'s configuration at rest,
    /// discarding the saved state it holds in the same operation when the
    /// change does not restore it.
    ///
    /// The write is the library's ordinary settings write, so the MAC address
    /// registry and the field classes still judge it. It stays whatever the
    /// bring-up that follows does: it is a change to the VM's configuration.
    func takeMACAddressRemedy(
        _ remedy: MACAddressRemedy, on instance: VMInstance, verb: VMVerb
    ) throws {
        let holdsSavedState = instance.hasSaveFile
        if let refusal = macAddressRemedyRefusal(
            remedy, for: instance.configuration, holdingSavedState: holdsSavedState)
        {
            throw refusal
        }
        let change: (inout VMConfiguration) -> Void = { Self.apply(remedy, to: &$0) }
        if holdsSavedState, Self.discardsSavedState(remedy) {
            var written = false
            do {
                try lifecycle.discardSavedState(instance) { permit in
                    try requireSaved(
                        library.updateConfiguration(permit, mutate: change), of: instance, verb: verb)
                    written = true
                }
            } catch {
                guard written else { throw failure(error, verb: verb, on: instance) }
                throw CommandError.operationFailed(
                    verb: verb,
                    message:
                        "\u{201C}\(instance.name)\u{201D}\u{2019}s network was changed, but its saved state could not be deleted. That state can no longer be restored \u{2014} discard it to start the virtual machine."
                )
            }
        } else {
            let classes: VMEditClasses = remedy == .ownNetwork ? .networkMembership : .machineKeys
            try edit(classes, on: instance, verb: verb) { permit in
                try requireSaved(
                    library.updateConfiguration(permit, mutate: change), of: instance, verb: verb)
            }
        }
        #log(
            Self.logger, .notice,
            "Took the MAC address remedy \(remedy.rawValue, privacy: .public) on '\(instance.name, privacy: .public)'\(holdsSavedState && Self.discardsSavedState(remedy) ? ", discarding its saved state" : "", privacy: .public)"
        )
    }
}
