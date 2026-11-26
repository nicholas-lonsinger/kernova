import Foundation
import KernovaCommandModel
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

    /// Every configuration key `configuration` and `setConfiguration` address,
    /// in presentation order.
    ///
    /// Addresses no VM: the keyspace is the same for all of them, and which
    /// keys a particular VM answers for is what ``configuration(_:keys:)``
    /// reports.
    package func configurationKeys() -> [ConfigurationKeyDescriptor] {
        VMConfigurationKeyRegistry.keys.map(\.descriptor)
    }

    // MARK: - Read

    /// The VM's values for `keys`, or for every key that applies to it when
    /// `keys` is `nil`.
    ///
    /// Each value is written the way ``setConfiguration(_:assignments:consent:)``
    /// parses it back.
    package func configuration(_ selector: VMSelector, keys: [String]?) throws -> [ConfigurationEntry] {
        let settings = try currentSettings(of: selector)
        guard let keys else {
            // A key the guest cannot have is left out rather than reported with
            // a value no `set` would take back.
            return VMConfigurationKeyRegistry.keys
                .filter { $0.applies(settings.configuration) }
                .map { Self.entry($0, in: settings) }
        }
        return try keys.map { try entry(named: $0, in: settings) }
    }

    /// The VM's value for `key`, refusing a key the keyspace does not hold and
    /// one this guest cannot have.
    ///
    /// The value is written the way ``setConfiguration(_:assignments:consent:)``
    /// parses it back.
    package func configuration(_ selector: VMSelector, key: String) throws -> ConfigurationEntry {
        try entry(named: key, in: currentSettings(of: selector))
    }

    /// What the VM's bundle holds now.
    private func currentSettings(of selector: VMSelector) throws -> VMSettings {
        let instance = try resolve(selector)
        instance.activity.refreshFromBundle()
        return instance.settings
    }

    private func entry(named name: String, in settings: VMSettings) throws -> ConfigurationEntry {
        Self.entry(try requireKey(named: name, on: settings.configuration), in: settings)
    }

    /// `key`'s value in `settings`, in the spelling ``setConfiguration(_:assignments:consent:)``
    /// parses back.
    private static func entry(_ key: VMConfigurationKey, in settings: VMSettings) -> ConfigurationEntry {
        ConfigurationEntry(key: key.name, value: key.read(settings))
    }

    // MARK: - Write

    /// Applies every assignment or none, in the order given, answering the
    /// values the assigned keys ended up holding.
    ///
    /// Each key's gate and value is checked before anything is written, so a
    /// batch naming one key the VM's state will not take, or one value it
    /// cannot parse, changes nothing. A configuration key's assignment that
    /// leaves its value where it is is taken in any state; a host-state key's
    /// gate is asked whether its value moves or not, so naming one is refused
    /// wherever that key is pinned, a snapshot capture among them.
    /// `consent` supplies what the assignments that ask for it need — turning
    /// automatic clipboard passthrough on, and pinning the Ephemeral baseline
    /// every shutdown returns the VM to.
    ///
    /// A gate that refuses names every assignment it refused. Each gate names
    /// an edit class (``VMConfigurationKey/editClasses(writing:)``); the
    /// write holds a permit for the classes of the named keys the VM takes, and
    /// an assignment that moves a field those classes may not write
    /// (``VMStateFieldClasses``) is refused.
    ///
    /// Each file's assignments apply once, to what that file holds rather than
    /// to memory, so a field another process changed since this one last read
    /// survives — and whether an assignment moves a value is judged there too.
    /// The configuration's refusals are judged on its result, so turning
    /// clipboard sharing on in the same call as passthrough works whichever
    /// order they arrive in; a host-state key's own refusal is judged before
    /// either file is touched, on the host state the batch makes of what the
    /// VM holds, and only when its value moves. A key whose write derives
    /// another key's value — `network.mode` minting a MAC address — sees the
    /// batch in the order given.
    @discardableResult
    package func setConfiguration(
        _ selector: VMSelector, assignments: [ConfigurationEntry], consent: Consent
    ) throws -> [ConfigurationEntry] {
        let instance = try resolve(selector)
        let edits = try assignments.map {
            (key: try requireKey(named: $0.key, on: instance.configuration), value: $0.value)
        }
        let written = try write(edits, to: instance, consent: consent)
        return edits.map { Self.entry($0.key, in: written) }
    }

    /// Applies `assignment` as ``setConfiguration(_:assignments:consent:)``
    /// applies a batch of one, answering the value its key ended up holding.
    func setConfiguration(
        _ selector: VMSelector, assignment: ConfigurationEntry, consent: Consent
    ) throws -> ConfigurationEntry {
        let instance = try resolve(selector)
        let key = try requireKey(named: assignment.key, on: instance.configuration)
        let written = try write([(key: key, value: assignment.value)], to: instance, consent: consent)
        return Self.entry(key, in: written)
    }

    /// The write both `setConfiguration` forms make, of keys already required
    /// on `instance`, answering the settings it left the VM holding.
    private func write(
        _ edits: [(key: VMConfigurationKey, value: String)], to instance: VMInstance,
        consent: Consent
    ) throws -> VMSettings {
        let context = VMConfigurationWriteContext(instance, in: library)

        var configurationWrites: [ConfigurationWrite] = []
        var hostStateWrites: [HostStateWrite] = []
        for (key, value) in edits {
            switch key.field {
            case .configuration(let field):
                configurationWrites.append(ConfigurationWrite(key: key, field: field, value: value))
            case .hostState(let field):
                hostStateWrites.append(HostStateWrite(key: key, field: field, value: value))
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
        var hostStateCandidate = instance.hostState
        for change in hostStateChanges { change.change(&hostStateCandidate) }
        for change in hostStateChanges
        where change.field.read(hostStateCandidate) != change.field.read(instance.hostState) {
            // Only a key this call moves is judged, as the configuration's are.
            guard let message = change.field.refusalOnResult(hostStateCandidate, context) else { continue }
            throw CommandError.invalidArgument(message)
        }
        try requireEphemeralBaselineConsent(on: instance, becoming: hostStateCandidate, consent: consent)
        // The configuration's gates are judged on what `config.json` holds,
        // inside the write: the permit covers every key the VM takes now, and
        // one that moves a field outside it is refused there.
        let admittedConfigurationEdits = configurationWrites.map { (key: $0.key, value: $0.value) }
            .filter {
                capabilities.accepts($0.key.capability(writing: $0.value), on: instance)
            }
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
                            admittedKeys: admittedKeys, context: context, consent: consent)
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
            logger.log(
                .notice,
                "Changed \(moved.map(\.name).joined(separator: ", "), privacy: .public) on '\(instance.name, privacy: .public)'"
            )
        }
        return instance.settings
    }

    /// One configuration assignment of a ``setConfiguration(_:assignments:consent:)`` batch.
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
        context: VMConfigurationWriteContext, consent: Consent
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
            guard let message = write.field.refusalOnResult(config, context) else { continue }
            throw CommandError.invalidArgument(message)
        }
        try requireClipboardPassthroughConsent(
            on: instance, from: held, to: config, consent: consent)
        if let conflict = library.macAddresses.macAddressConflict(
            on: instance, movingFrom: held, to: config)
        {
            throw macAddressRefusal(conflict, on: instance)
        }
        return moved.map(\.key)
    }

    /// Refuses unless `instance` takes every one of `edits`, naming each
    /// assignment its state refused.
    func requireGates(
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
        let error = refusal(
            for: refused.map { $0.key.capability(writing: $0.value) }, on: instance)
        guard case .invalidState(let vm, let current, let allowed, _, let processEnd) = error else { throw error }
        var settings: [ConfigurationEntry] = []
        for edit in refused {
            let entry = ConfigurationEntry(key: edit.key.name, value: edit.value)
            if !settings.contains(entry) { settings.append(entry) }
        }
        throw CommandError.invalidState(
            vm: vm, current: current, allowed: allowed, settings: settings, processEnd: processEnd)
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
        consent: Consent
    ) throws {
        guard ClipboardPassthroughConsent.isNewlyEffective(from: current, to: candidate),
            !consent.covers(.enableClipboardPassthrough)
        else { return }
        throw CommandError.confirmationRequired(
            ClipboardPassthroughConsent.prompt(vmName: instance.name))
    }

    /// Refuses, without the user's consent, a change that turns Ephemeral Mode
    /// on or points it at another snapshot — the host state becoming
    /// `candidate` — in whatever state the VM is: from then on every shutdown
    /// discards what the VM holds.
    private func requireEphemeralBaselineConsent(
        on instance: VMInstance, becoming candidate: VMHostState, consent: Consent
    ) throws {
        guard candidate.ephemeralModeEnabled,
            let id = candidate.ephemeralBaselineSnapshotID,
            id != instance.ephemeralBaselineSnapshot?.id,
            let baseline = instance.snapshotManifest.snapshot(id: id),
            !consent.covers(.setEphemeralBaseline)
        else { return }
        throw CommandError.confirmationRequired(
            Self.ephemeralBaselinePrompt(
                baseline, on: instance, turningOn: instance.ephemeralBaselineSnapshot == nil))
    }

    /// What turning Ephemeral Mode on with `baseline` — or, with `turningOn`
    /// false, pointing it there — asks first.
    package static func ephemeralBaselinePrompt(
        _ baseline: VMSnapshot, on instance: VMInstance, turningOn: Bool
    ) -> ConfirmationPrompt {
        let vm = "\u{201C}\(instance.name)\u{201D}"
        let snapshot = "\u{201C}\(baseline.name)\u{201D}"
        return ConfirmationPrompt(
            kind: .setEphemeralBaseline,
            title: turningOn
                ? "Turn On Ephemeral Mode for \(vm)?"
                : "Make \(snapshot) the Baseline of \(vm)?",
            message: EphemeralModeCopy.shutdownDiscards(vm: vm, baseline: snapshot),
            confirmTitle: turningOn ? "Turn On" : "Change Baseline",
            dismissTitle: "Cancel")
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
    package func sharedDirectories(of selector: VMSelector) throws -> [SharedDirectorySummary] {
        try (resolve(selector).configuration.sharedDirectories ?? []).map(SharedDirectorySummary.init)
    }

    /// Shares the folder at `path` with the guest, leaving a folder the VM
    /// already shares as it is, and answers the share that folder fills — on
    /// the wire where ``addSharedDirectories(_:paths:)`` is not, so named by
    /// path rather than by pick.
    ///
    /// The share answered is one the guest reaches as `readOnly` says: a
    /// folder any share of which the guest reaches with the other access is
    /// refused, since an add changes no share it finds.
    ///
    /// Resolve, gate, then grant: the VM, its state and what `path` names decide
    /// the answer before the authority is consulted, so a selector no VM
    /// answers to, a VM that takes no added share and a path that is no folder
    /// are all refused without a panel ever going up. The
    /// grant is asked for last because only the app can obtain one for a path a
    /// sandboxed client named, and the bookmark is minted from that path once
    /// it is readable — a share is reopened at every boot.
    ///
    /// `path` is taken standardized, with its links resolved, so a `.` or `..`
    /// hop or a link's name never reaches the stored path or the name a macOS
    /// guest mounts the folder by, whichever door named it.
    ///
    /// The gate is asked again once the panel answers: it stands for as long as
    /// the user leaves it up, and the VM the caller named can have started in
    /// the meantime.
    @discardableResult
    package func addSharedDirectory(
        _ selector: VMSelector, path: String, readOnly: Bool
    ) async throws -> SharedDirectorySummary {
        let instance = try resolve(selector)
        _ = try requireSharedDirectories(.add, on: instance)
        if let shared = try share(at: path, on: instance, sharedReadOnly: readOnly) { return shared }

        let folder = URL(fileURLWithPath: path).standardizedFileURL
        try Self.requireDirectory(folder)
        try await requireSourceAuthority(.editSharedDirectory)
            .requireReadAccess(to: folder, as: .sharedDirectory)
        // A link's bookmark cannot be made while the folder holding the link
        // is one the sandbox does not admit (observed 2026-11-26, macOS
        // 27.2.1), so the share is of the folder the path resolves to.
        let file = PickedFile(picking: folder.resolvingSymlinksInPath())
        try addSharedDirectories([file], readOnly: readOnly, to: instance)
        guard let shared = try share(at: file.path, on: instance, sharedReadOnly: readOnly) else {
            throw itemNotFound(instance, item: "shared directory \u{201C}\(file.path)\u{201D}")
        }
        return shared
    }

    /// The share of the VM the folder at `path` names
    /// (``sharedDirectory(named:on:)``), `nil` when it names none, refused when
    /// the guest reaches any share that answers to it
    /// (``SharedDirectory/answers(to:)``) with the access `readOnly` is not.
    private func share(
        at path: String, on instance: VMInstance, sharedReadOnly readOnly: Bool
    ) throws -> SharedDirectorySummary? {
        let folder = NamedFolder(path)
        let answering = (instance.configuration.sharedDirectories ?? []).filter { $0.answers(to: folder) }
        if let other = answering.first(where: { $0.readOnly != readOnly }) {
            let access = other.readOnly ? "as read only" : "not as read only"
            throw CommandError.invalidArgument(
                "\u{201C}\(instance.name)\u{201D} already shares \u{201C}\(other.path)\u{201D} \(access), and adding it again does not change that."
            )
        }
        return sharedDirectory(named: folder, on: instance).map(SharedDirectorySummary.init)
    }

    /// The share of the VM `selector` names that `path`, a full path, names
    /// (``sharedDirectory(named:on:)``), `nil` when it names none.
    package func sharedDirectory(_ selector: VMSelector, at path: String) throws -> SharedDirectorySummary? {
        sharedDirectory(named: NamedFolder(path), on: try resolve(selector)).map(SharedDirectorySummary.init)
    }

    /// The one share of the VM `folder` names: the first listed at it
    /// (``SharedDirectory/isListed(at:)``), so a listed path names its own
    /// share whatever other share holds the same folder, else the first that
    /// answers to it (``SharedDirectory/answers(to:)``). `nil` when none does.
    private func sharedDirectory(named folder: NamedFolder, on instance: VMInstance) -> SharedDirectory? {
        let directories = instance.configuration.sharedDirectories ?? []
        return directories.first { $0.isListed(at: folder) } ?? directories.first { $0.answers(to: folder) }
    }

    /// Refuses a path naming anything but a folder.
    ///
    /// A VM whose configuration names a file where a share should be refuses to
    /// start at all, so the entry is refused where it is entered rather than
    /// left to fail at the next boot.
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
    package func removeSharedDirectory(_ selector: VMSelector, path: String) throws {
        let instance = try resolve(selector)
        _ = try requireSharedDirectories(.remove, on: instance)
        guard let directory = sharedDirectory(named: NamedFolder(path), on: instance) else {
            throw CommandError.invalidArgument(
                "\u{201C}\(instance.name)\u{201D} does not share \u{201C}\(path)\u{201D}.")
        }
        try removeSharedDirectory(selector, directory: directory.id)
    }
}

extension SharedDirectorySummary {
    /// `share` without the bookmark behind it.
    init(_ share: SharedDirectory) {
        self.init(name: share.name, path: share.path, readOnly: share.readOnly)
    }
}

/// The folder a path names, as shares are asked whether they answer to it
/// (``SharedDirectory/answers(to:)``): the path's
/// ``FileIdentity/spelling(_:)``, and the identity of the folder there, links
/// followed.
struct NamedFolder {
    let spelling: String
    let identity: FileIdentity?

    init(_ path: String) {
        let url = URL(fileURLWithPath: path)
        spelling = FileIdentity.spelling(url)
        identity = FileIdentity(at: url.resolvingSymlinksInPath())
    }
}

extension SharedDirectory {
    /// Whether the share answers to `folder`: it is listed at the folder's
    /// path (``isListed(at:)``), or the file system reports the folder there
    /// to be the share's — the one its bookmark resolves to, else the one at
    /// its listed path, links followed.
    ///
    /// So a share whose folder is gone or unreadable still answers to the path
    /// its listing shows.
    func answers(to folder: NamedFolder) -> Bool {
        guard !isListed(at: folder) else { return true }
        guard let identity = folder.identity else { return false }
        let target = bookmark.flatMap(SecurityScopedBookmark.resolvedTargetPath) ?? path
        return FileIdentity(at: URL(fileURLWithPath: target).resolvingSymlinksInPath()) == identity
    }

    /// Whether the share is listed at `folder`'s path, both as
    /// ``FileIdentity/spelling(_:)`` spells them.
    func isListed(at folder: NamedFolder) -> Bool {
        FileIdentity.spelling(URL(fileURLWithPath: path)) == folder.spelling
    }
}
