import Foundation
import KernovaKit
import KernovaLogging

/// The configuration verbs — the dotted keyspace `get` and `set` address, the
/// two list edits a caller names by path rather than by id, and the reads that
/// answer those two lists.
///
/// Every write lands as one ``VMLibrary/updateSettings(of:configuration:hostState:)``:
/// the gates and the values are all checked before either file is written, so
/// a batch that names one bad key writes nothing at all.
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
    /// `set` input in any state. A gate that refuses names every key it
    /// refused.
    ///
    /// Each file's assignments apply once, to what that file holds rather than
    /// to memory, so a field another process changed since this one last read
    /// survives. The configuration's refusals are judged on its result, so
    /// turning clipboard sharing on in the same call as passthrough works
    /// whichever order they arrive in. A key whose write derives another key's
    /// value — `network.mode` minting a MAC address — sees the batch in the
    /// order given.
    @discardableResult
    func setConfiguration(
        _ selector: VMSelector, assignments: [ConfigurationEntry], confirmed: Bool
    ) throws -> [ConfigurationEntry] {
        let instance = try resolve(selector)
        let context = VMConfigurationWriteContext(instance)

        var answered: [VMConfigurationKey] = []
        var edits: [(key: VMConfigurationKey, value: String)] = []
        var candidate = instance.settings
        for assignment in assignments {
            let key = try requireKey(named: assignment.key, on: instance.configuration)
            answered.append(key)
            let before = candidate
            do {
                try key.apply(assignment.value, to: &candidate, context: context)
            } catch {
                // Still an edit: the gate answers it before the write below
                // refuses the value.
                edits.append((key, assignment.value))
                continue
            }
            if candidate != before { edits.append((key, assignment.value)) }
        }
        try requireGates(for: edits, on: instance)
        guard !edits.isEmpty else {
            let held = instance.settings
            return answered.map { ConfigurationEntry(key: $0.name, value: $0.read(held)) }
        }

        var configurationWrites: [(field: VMConfigurationKey.ConfigurationField, value: String)] =
            []
        var hostStateChanges: [(inout VMHostState) -> Void] = []
        for edit in edits {
            switch edit.key.field {
            case .configuration(let field): configurationWrites.append((field, edit.value))
            case .hostState(let field): hostStateChanges.append(try field.change(edit.value, context))
            }
        }

        try requireSaved(
            library.updateSettings(
                of: instance,
                configuration: { config in
                    let held = config
                    for write in configurationWrites {
                        try write.field.write(write.value, &config, context)
                    }
                    for write in configurationWrites
                    where write.field.read(config) != write.field.read(held) {
                        // Only a key this call actually moved is judged: writing
                        // back what a read answered has to stay a no-op, so `get`
                        // output is `set` input on a VM whose stored value is
                        // already inert.
                        guard let message = write.field.refusalOnResult(config) else { continue }
                        throw CommandError.invalidArgument(message)
                    }
                    try requireClipboardPassthroughConsent(
                        on: instance, from: held, to: config, confirmed: confirmed)
                    if let conflict = library.macAddresses.macAddressConflict(
                        on: instance, movingFrom: held, to: config)
                    {
                        throw CommandError.conflict(
                            vm: summary(instance), with: summary(conflict.other),
                            reason: conflict.reason)
                    }
                },
                hostState: { hostState in
                    for change in hostStateChanges { change(&hostState) }
                }),
            of: instance, verb: .setConfiguration)
        #log(
            Self.logger, .notice,
            "Changed \(edits.map(\.key.name).joined(separator: ", "), privacy: .public) on '\(instance.name, privacy: .public)'"
        )
        let written = instance.settings
        return answered.map { ConfigurationEntry(key: $0.name, value: $0.read(written)) }
    }

    /// Refuses unless `instance` takes every one of `edits`, naming each key
    /// its state refused.
    private func requireGates(
        for edits: [(key: VMConfigurationKey, value: String)], on instance: VMInstance
    ) throws {
        let refused = edits.filter {
            !capabilities.accepts($0.key.capability(writing: $0.value), on: instance)
        }
        guard !refused.isEmpty else { return }
        let error = refusal(for: refused.map { $0.key.capability(writing: $0.value) }, on: instance)
        guard case .invalidState(let vm, let current, let allowed, _) = error else { throw error }
        var names: [String] = []
        for edit in refused where !names.contains(edit.key.name) { names.append(edit.key.name) }
        throw CommandError.invalidState(vm: vm, current: current, allowed: allowed, settings: names)
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
