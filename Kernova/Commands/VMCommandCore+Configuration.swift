import Foundation
import KernovaKit
import KernovaLogging

/// The configuration verbs — the dotted keyspace `get` and `set` address, the
/// two list edits a caller names by path rather than by id, and the reads that
/// answer those two lists.
///
/// Every write lands as one ``VMLibrary/updateSettings(_:configuration:hostState:)``,
/// under a permit for the edit classes its keys' gates name: the gates and the
/// values are all checked before either file is written, so a batch that names
/// one bad key writes nothing at all.
extension VMCommandCore {
    // MARK: - Keys

    func configurationKeys() -> [ConfigurationKeyDescriptor] {
        VMConfigurationKeyRegistry.keys.map(\.descriptor)
    }

    // MARK: - Read

    func configuration(_ selector: VMSelector, keys: [String]?) throws -> [ConfigurationEntry] {
        let instance = try resolve(selector)
        let settings = instance.settings
        guard let keys else {
            // A key the guest cannot have is left out rather than reported with
            // a value no `set` would take back.
            return VMConfigurationKeyRegistry.keys
                .filter { $0.applies(settings.configuration) }
                .map { ConfigurationEntry(key: $0.name, value: $0.read(settings)) }
        }
        return try keys.map { name in
            let key = try requireKey(named: name, on: settings.configuration)
            return ConfigurationEntry(key: key.name, value: key.read(settings))
        }
    }

    // MARK: - Write

    /// Applies every assignment or none, in the order given, answering the
    /// values the assigned keys ended up holding.
    ///
    /// An assignment that leaves the VM's settings where they are is no edit:
    /// no gate applies to it and nothing is written for it, so `get` output is
    /// `set` input in any state. A gate that refuses names every assignment it
    /// refused. Each gate names an edit class (``VMConfigurationKey/editClasses(writing:)``);
    /// the write holds a permit for the classes of the named keys the VM takes,
    /// and an assignment that moves a field those classes may not write
    /// (``VMStateFieldClasses``) is refused.
    ///
    /// Each file's assignments apply once, to what that file holds rather than
    /// to memory, so a field another process changed since this one last read
    /// survives — and whether an assignment moves a value is judged there too.
    /// The configuration's refusals are judged on its result, so turning
    /// clipboard sharing on in the same call as passthrough works whichever
    /// order they arrive in. A key whose write derives another key's value —
    /// `network.mode` minting a MAC address — sees the batch in the order
    /// given.
    @discardableResult
    func setConfiguration(
        _ selector: VMSelector, assignments: [ConfigurationEntry], confirmed: Bool
    ) throws -> [ConfigurationEntry] {
        let instance = try resolve(selector)
        let context = VMConfigurationWriteContext(instance)

        var answered: [VMConfigurationKey] = []
        var configurationWrites: [ConfigurationWrite] = []
        var hostStateWrites: [HostStateWrite] = []
        for assignment in assignments {
            let key = try requireKey(named: assignment.key, on: instance.configuration)
            answered.append(key)
            switch key.field {
            case .configuration(let field):
                configurationWrites.append(
                    ConfigurationWrite(key: key, field: field, value: assignment.value))
            case .hostState(let field):
                hostStateWrites.append(HostStateWrite(key: key, field: field, value: assignment.value))
            }
        }
        // Before either file is touched: host state commits after the
        // configuration, where nothing may refuse.
        let hostStateEdits = hostStateWrites.map { (key: $0.key, value: $0.value) }
        try requireGates(for: hostStateEdits, on: instance)
        let hostStateChanges = try hostStateWrites.map { write in
            HostStateChange(
                key: write.key, field: write.field, change: try write.field.change(write.value, context))
        }
        // The configuration's gates are judged on what `config.json` holds,
        // inside the write: the permit covers every key the VM takes now, and
        // one that moves a field outside it is refused there.
        let admittedConfigurationEdits = configurationWrites.map { (key: $0.key, value: $0.value) }
            .filter { capabilities.accepts($0.key.capability(writing: $0.value), on: instance) }
        let classes = (hostStateEdits + admittedConfigurationEdits).reduce(into: VMEditClasses()) {
            $0.formUnion($1.key.editClasses(writing: $1.value))
        }
        let admittedKeys = Set(admittedConfigurationEdits.map(\.key.name))

        var moved: [VMConfigurationKey] = []
        try edit(classes, on: instance, verb: .setConfiguration) { permit in
            try requireSaved(
                library.updateSettings(
                    permit,
                    configuration: { config in
                        moved = try apply(
                            configurationWrites, to: &config, on: instance, within: permit.authority,
                            admittedKeys: admittedKeys, context: context, confirmed: confirmed)
                    },
                    hostState: { hostState in
                        for change in hostStateChanges {
                            let before = change.field.read(hostState)
                            change.change(&hostState)
                            if change.field.read(hostState) != before { moved.append(change.key) }
                        }
                    }),
                of: instance, verb: .setConfiguration)
        }
        if !moved.isEmpty {
            #log(
                Self.logger, .notice,
                "Changed \(moved.map(\.name).joined(separator: ", "), privacy: .public) on '\(instance.name, privacy: .public)'"
            )
        }
        let written = instance.settings
        return answered.map { ConfigurationEntry(key: $0.name, value: $0.read(written)) }
    }

    /// One configuration assignment of a ``setConfiguration(_:assignments:confirmed:)`` batch.
    private struct ConfigurationWrite {
        let key: VMConfigurationKey
        let field: VMConfigurationKey.ConfigurationField
        let value: String
    }

    /// One host-state assignment of the same batch.
    private struct HostStateWrite {
        let key: VMConfigurationKey
        let field: VMConfigurationKey.HostStateField
        let value: String
    }

    /// A ``HostStateWrite`` parsed into the change it makes.
    private struct HostStateChange {
        let key: VMConfigurationKey
        let field: VMConfigurationKey.HostStateField
        let change: (inout VMHostState) -> Void
    }

    /// One assignment that moved the configuration, or whose value its key
    /// refused.
    private struct MovedAssignment {
        let key: VMConfigurationKey
        let value: String
        /// The fields it moved that `authority` may not write, when it moved
        /// any; `nil` for a value its key refused, which moved nothing.
        let refusedFields: [String]?
    }

    /// Lands `writes` on `config`, answering the assignments that moved it —
    /// one whose value its key refuses counts as moving it, so its gate is
    /// asked before its value is — and the first value refusal.
    private static func moved(
        _ writes: [ConfigurationWrite], applyingTo config: inout VMConfiguration,
        within authority: VMEditPermit.Authority, context: VMConfigurationWriteContext
    ) -> (assignments: [MovedAssignment], valueRefusal: (any Error)?) {
        var moved: [MovedAssignment] = []
        var valueRefusal: (any Error)?
        for write in writes {
            let before = config
            do {
                try write.field.write(write.value, &config, context)
            } catch {
                valueRefusal = valueRefusal ?? error
                moved.append(MovedAssignment(key: write.key, value: write.value, refusedFields: nil))
                continue
            }
            guard config != before else { continue }
            moved.append(
                MovedAssignment(
                    key: write.key, value: write.value,
                    refusedFields: VMConfiguration.fieldClasses.refused(
                        from: before, to: config, by: authority)))
        }
        return (moved, valueRefusal)
    }

    /// Lands `writes` on `config` — what `config.json` holds — refusing unless
    /// `authority` may write every field they move, answering the keys that
    /// moved.
    ///
    /// The gate answers an assignment whose value this key refuses too — one
    /// admission did not take (`admittedKeys`) — so a VM whose state pins the
    /// key says so rather than naming the value.
    private func apply(
        _ writes: [ConfigurationWrite], to config: inout VMConfiguration, on instance: VMInstance,
        within authority: VMEditPermit.Authority, admittedKeys: Set<String>,
        context: VMConfigurationWriteContext, confirmed: Bool
    ) throws -> [VMConfigurationKey] {
        let held = config
        let (moved, valueRefusal) = Self.moved(
            writes, applyingTo: &config, within: authority, context: context)
        try requireGates(
            refusing: moved.filter { assignment in
                guard let refusedFields = assignment.refusedFields else {
                    return !admittedKeys.contains(assignment.key.name)
                }
                return !refusedFields.isEmpty
            }.map { (key: $0.key, value: $0.value) },
            on: instance)
        if let valueRefusal { throw valueRefusal }
        for write in writes where write.field.read(config) != write.field.read(held) {
            // Only a key this call actually moved is judged: writing back what
            // a read answered has to stay a no-op, so `get` output is `set`
            // input on a VM whose stored value is already inert.
            guard let message = write.field.refusalOnResult(config) else { continue }
            throw CommandError.invalidArgument(message)
        }
        try requireClipboardPassthroughConsent(
            on: instance, from: held, to: config, confirmed: confirmed)
        if let conflict = library.macAddresses.macAddressConflict(
            on: instance, movingFrom: held, to: config)
        {
            throw CommandError.conflict(
                vm: summary(instance), with: summary(conflict.other), reason: conflict.reason)
        }
        return moved.map(\.key)
    }

    /// Refuses unless `instance` takes every one of `edits`, naming each
    /// assignment its state refused.
    private func requireGates(
        for edits: [(key: VMConfigurationKey, value: String)], on instance: VMInstance
    ) throws {
        try requireGates(
            refusing: edits.filter {
                !capabilities.accepts($0.key.capability(writing: $0.value), on: instance)
            },
            on: instance)
    }

    /// Refuses `refused` unless it is empty, naming each assignment and why
    /// the VM's state turned its gate away.
    private func requireGates(
        refusing refused: [(key: VMConfigurationKey, value: String)], on instance: VMInstance
    ) throws {
        guard !refused.isEmpty else { return }
        let error = refusal(for: refused.map { $0.key.capability(writing: $0.value) }, on: instance)
        guard case .invalidState(let vm, let current, let allowed, _) = error else { throw error }
        var settings: [ConfigurationEntry] = []
        for edit in refused {
            let entry = ConfigurationEntry(key: edit.key.name, value: edit.value)
            if !settings.contains(entry) { settings.append(entry) }
        }
        throw CommandError.invalidState(
            vm: vm, current: current, allowed: allowed, settings: settings)
    }

    /// Refuses a change that turns automatic clipboard passthrough on without
    /// the user's consent.
    ///
    /// The gate itself is ``ClipboardPassthroughConsent``, so a sharing enable
    /// over a passthrough flag already set confirms exactly as a passthrough
    /// enable does. A caller supplies the consent as a parameter; the settings
    /// pane gathers it in an alert.
    private func requireClipboardPassthroughConsent(
        on instance: VMInstance, from current: VMConfiguration, to candidate: VMConfiguration,
        confirmed: Bool
    ) throws {
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

    // MARK: - Shared Directories

    /// The folders the VM shares with its guest, in the order it carries them.
    ///
    /// Each entry is the stored path and its access, without the bookmark
    /// behind it. Nothing on disk is opened, so a folder that has moved is
    /// answered the way the VM carries it rather than left out.
    func sharedDirectories(of selector: VMSelector) throws -> [SharedDirectorySummary] {
        try (resolve(selector).configuration.sharedDirectories ?? [])
            .map { SharedDirectorySummary(path: $0.path, readOnly: $0.readOnly) }
    }

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

        try writeConfiguration(of: instance, as: .editSharedDirectories, verb: .editSharedDirectory) { config in
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
    /// (docs/NETWORKING.md, refuse at entry what cannot take effect) rather
    /// than left to fail at the next boot.
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
}
