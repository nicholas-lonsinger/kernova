import Foundation
import KernovaKit

/// The configuration verbs — the dotted keyspace `get` and `set` address, plus
/// the two list edits a caller names by path rather than by id.
///
/// Every write lands as one ``VMLibrary/updateConfiguration(of:mutate:)``: the
/// gates and the values are all checked first, so a batch that names one bad
/// key writes nothing at all.
extension VMCommandCore {
    // MARK: - Keys

    func configurationKeys() -> [ConfigurationKeyDescriptor] {
        VMConfigurationKeyRegistry.keys.map(\.descriptor)
    }

    // MARK: - Read

    func configuration(_ selector: VMSelector, keys: [String]?) throws -> [ConfigurationEntry] {
        let instance = try resolve(selector)
        let config = instance.configuration
        guard let keys else {
            // A key the guest cannot have is left out rather than reported with
            // a value no `set` would take back.
            return VMConfigurationKeyRegistry.keys
                .filter { $0.applies(config) }
                .map { ConfigurationEntry(key: $0.name, value: $0.read(config)) }
        }
        return try keys.map { name in
            let key = try requireKey(named: name, on: config)
            return ConfigurationEntry(key: key.name, value: key.read(config))
        }
    }

    // MARK: - Write

    /// Applies every assignment or none, in the order given, answering the
    /// values the assigned keys ended up holding.
    ///
    /// The cross-key refusals are judged on the result, so turning clipboard
    /// sharing on in the same call as passthrough works whichever order they
    /// arrive in. A key whose write derives another key's value — `network.mode`
    /// minting a MAC address — sees the batch in the order given.
    @discardableResult
    func setConfiguration(
        _ selector: VMSelector, assignments: [ConfigurationEntry], confirmed: Bool
    ) throws -> [ConfigurationEntry] {
        let instance = try resolve(selector)
        let current = instance.configuration

        var resolved: [(key: VMConfigurationKey, value: String)] = []
        for assignment in assignments {
            let key = try requireKey(named: assignment.key, on: current)
            try require(key.capability(writing: assignment.value), on: instance)
            resolved.append((key, assignment.value))
        }

        let context = VMConfigurationWriteContext(snapshots: instance.snapshotManifest)
        var candidate = current
        for entry in resolved {
            try entry.key.write(entry.value, &candidate, context)
        }
        for entry in resolved where entry.key.read(candidate) != entry.key.read(current) {
            // Only a key this call actually moved is judged: writing back what
            // a read answered has to stay a no-op, so `get` output is `set`
            // input on a VM whose stored value is already inert.
            guard let message = entry.key.refusalOnResult(candidate) else { continue }
            throw CommandError.invalidArgument(message)
        }

        try refuseClipboardPassthrough(on: instance, from: current, to: candidate, confirmed: confirmed)
        if let conflict = library.networkSlots.slotConflict(
            on: instance, movingFrom: current, to: candidate)
        {
            throw CommandError.conflict(
                vm: summary(instance), with: summary(conflict.other), reason: conflict.reason)
        }

        // Assigning the whole candidate is safe because nothing between reading
        // `current` and this write awaits — a suspension there would clobber
        // whatever a concurrent writer landed in between.
        try writeConfiguration(of: instance, verb: .setConfiguration) { $0 = candidate }
        Self.logger.notice(
            "Changed \(resolved.map(\.key.name).joined(separator: ", "), privacy: .public) on '\(instance.name, privacy: .public)'"
        )
        let written = instance.configuration
        return resolved.map { ConfigurationEntry(key: $0.key.name, value: $0.key.read(written)) }
    }

    /// Refuses a change that turns automatic clipboard passthrough on without
    /// what it needs: clipboard sharing to ride on, and the user's consent.
    ///
    /// The gate itself is ``ClipboardPassthroughConsent``, which the settings
    /// pane asks too — so a sharing enable over a passthrough flag already set
    /// confirms here exactly as it does there. A headless caller supplies the
    /// consent the pane gathers in an alert as a parameter.
    ///
    /// Setting the flag on a VM with sharing off is refused rather than stored
    /// inert, matching the pane, whose passthrough switch is dead while sharing
    /// is off — but only as a *change*, so a `get` of a VM already in that state
    /// still writes back.
    private func refuseClipboardPassthrough(
        on instance: VMInstance, from current: VMConfiguration, to candidate: VMConfiguration,
        confirmed: Bool
    ) throws {
        if candidate.clipboardPassthroughEnabled, !current.clipboardPassthroughEnabled,
            !candidate.clipboardSharingEnabled
        {
            throw CommandError.invalidArgument(
                "Automatic clipboard passthrough rides on clipboard sharing, which is off. "
                    + "Set clipboard.sharing=true as well.")
        }
        guard ClipboardPassthroughConsent.isNewlyEffective(from: current, to: candidate),
            !confirmed
        else { return }
        throw CommandError.confirmationRequired(
            ClipboardPassthroughConsent.prompt(vmName: instance.name))
    }

    /// The key `name` addresses, refusing a name the keyspace does not hold and
    /// one this guest cannot have.
    private func requireKey(named name: String, on config: VMConfiguration) throws
        -> VMConfigurationKey
    {
        guard let key = VMConfigurationKeyRegistry.key(named: name) else {
            throw CommandError.invalidArgument(
                "There is no setting called \u{201C}\(name)\u{201D}.")
        }
        guard key.applies(config) else {
            throw CommandError.unsupported(capability: "the \(key.name) setting")
        }
        return key
    }

    // MARK: - Shared Directories by Path

    /// Shares the folder at `path` with the guest, leaving a folder the VM
    /// already shares as it is.
    ///
    /// Resolve, gate, then grant: the VM and its state decide the answer before
    /// the authority is consulted, so a selector no VM answers to and a VM whose
    /// device set is already pinned are both refused without a panel ever going
    /// up. The grant is asked for last because only the app can obtain one for a
    /// path a sandboxed client named, and the bookmark is minted from whatever
    /// URL it answers with — a share is reopened at every boot.
    ///
    /// The gate is asked again once the panel answers: it stands for as long as
    /// the user leaves it up, and the VM the caller named can have started in
    /// the meantime.
    func addSharedDirectory(_ selector: VMSelector, path: String, readOnly: Bool) async throws {
        let instance = try resolve(selector)
        try require(.editSharedDirectories, on: instance)
        guard !shares(instance, path) else { return }

        let folder = try await requireSourceAuthority(.editSharedDirectory)
            .readableURL(for: URL(fileURLWithPath: path), as: .sharedDirectory)
        try require(.editSharedDirectories, on: instance)
        try Self.requireDirectory(folder)
        let file = PickedFile(picking: folder)
        // The authority answers whatever the user picked, which can be a folder
        // this VM already shares even when the named one was not.
        guard !shares(instance, file.path) else { return }

        try writeConfiguration(of: instance, verb: .editSharedDirectory) { config in
            var directories = config.sharedDirectories ?? []
            directories.append(
                SharedDirectory(path: file.path, readOnly: readOnly, bookmark: file.bookmark))
            config.sharedDirectories = directories
        }
    }

    /// Whether the VM already shares the folder at `path`.
    private func shares(_ instance: VMInstance, _ path: String) -> Bool {
        let wanted = Self.comparablePath(path)
        return (instance.configuration.sharedDirectories ?? []).contains {
            Self.comparablePath($0.path) == wanted
        }
    }

    /// Refuses a path naming anything but a folder.
    ///
    /// A VM whose configuration names a file where a share should be refuses to
    /// start at all, so the entry is refused where it is entered
    /// (docs/NETWORKING.md §3) rather than left to fail at the next boot.
    private static func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        let path = url.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw CommandError.invalidArgument(
                "A guest shares folders, and \u{201C}\(path)\u{201D} is not one.")
        }
    }

    /// Drops the share the folder at `path` fills, leaving the folder alone.
    func removeSharedDirectory(_ selector: VMSelector, path: String) throws {
        let instance = try resolve(selector)
        try require(.editSharedDirectories, on: instance)
        let wanted = Self.comparablePath(path)
        guard
            let directory = (instance.configuration.sharedDirectories ?? []).first(where: {
                Self.comparablePath($0.path) == wanted
            })
        else {
            throw CommandError.invalidArgument(
                "\u{201C}\(instance.name)\u{201D} does not share \u{201C}\(path)\u{201D}.")
        }
        try removeSharedDirectory(selector, directory: directory.id)
    }

    /// A path in the one spelling two of them are compared in — a trailing
    /// separator and a `..` hop name the same folder as the resolved form.
    ///
    /// Every "does this VM already share it" question in the core is asked in
    /// this spelling, whichever verb asks.
    static func comparablePath(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
            .path(percentEncoded: false)
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }

    // MARK: - Port Forwarding

    /// Adds one host→guest mapping, leaving a rule the VM already carries as it
    /// is.
    ///
    /// A network carries one rule per (transport, host port) across every VM
    /// joined to it, so a port *another* rule already claims is refused rather
    /// than added and silently dropped at declaration time. This VM's own claim
    /// is answered first: the identical rule is the state the caller asked for,
    /// and a different guest port behind the same host port names the rule
    /// standing in the way rather than reporting the VM as its own blocker.
    func addPortForwardingRule(_ selector: VMSelector, rule: PortForwardingRule) throws {
        let instance = try resolve(selector)
        try require(.editPortForwarding, on: instance)
        try Self.requireAddressablePorts(rule)
        if let mine = instance.configuration.portForwardingRules.first(where: {
            $0.hostClaim == rule.hostClaim
        }) {
            guard mine != rule else { return }
            throw CommandError.invalidArgument(
                "\u{201C}\(instance.name)\u{201D} already forwards "
                    + "\(rule.transport.displayName) port \(rule.hostPort) to guest port "
                    + "\(mine.guestPort). Remove that rule first.")
        }
        if let holder = library.networkSlots.vmClaiming(rule.hostClaim) {
            throw CommandError.invalidArgument(
                "\u{201C}\(holder.name)\u{201D} already forwards "
                    + "\(rule.transport.displayName) port \(rule.hostPort).")
        }
        try writeConfiguration(of: instance, verb: .editPortForwarding) {
            $0.portForwardingRules.append(rule)
        }
    }

    /// Refuses a rule naming a port that addresses no service.
    private static func requireAddressablePorts(_ rule: PortForwardingRule) throws {
        let range = PortForwardingRule.portRange
        guard range.contains(Int(rule.hostPort)), range.contains(Int(rule.guestPort)) else {
            throw CommandError.invalidArgument(
                "A forwarded port is \(range.lowerBound) to \(range.upperBound).")
        }
    }

    /// Drops the rule claiming `claim`, refusing when this VM carries none.
    func removePortForwardingRule(_ selector: VMSelector, claim: PortForwardingHostClaim) throws {
        let instance = try resolve(selector)
        try require(.editPortForwarding, on: instance)
        guard instance.configuration.portForwardingRules.contains(where: { $0.hostClaim == claim })
        else {
            throw CommandError.invalidArgument(
                "\u{201C}\(instance.name)\u{201D} does not forward "
                    + "\(claim.transport.displayName) port \(claim.hostPort).")
        }
        try writeConfiguration(of: instance, verb: .editPortForwarding) {
            $0.portForwardingRules.removeAll { $0.hostClaim == claim }
        }
    }
}
