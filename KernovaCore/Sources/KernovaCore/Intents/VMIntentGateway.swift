import AppIntents
import Foundation
import KernovaCommandModel
import KernovaKit
import KernovaLogging

/// The App Intents front door: everything Shortcuts and Spotlight ask of
/// Kernova passes through here and reaches ``VMCommandCore``.
///
/// Two things every intent needs, in one place. **Readiness:** an intent can be
/// delivered while the app's first library read is still in flight, and a verb
/// run against a library that has not landed yet refuses with "no virtual
/// machine named…" — so every read and every verb awaits ``ready()`` first.
/// **Addressing:** a ``VMEntity`` already carries the resolved identifier, so
/// this addresses VMs by ``VMSelector/id(_:)`` alone and the ambiguity refusal
/// can never fire from this surface.
///
/// It presents nothing: a refusal leaves as the ``CommandError`` the core threw,
/// which each intent renders in the framework's idiom.
@MainActor
package final class VMIntentGateway {
    private let commands: VMCommandCore
    /// The app's first library read, shared with every other front door.
    private let readiness: LibraryReadiness
    /// Where the library is written for Spotlight to match a searched name in.
    private let index: any VMEntityIndexing
    /// Holds the identifiers already written to the index.
    private let record: VMIndexRecord
    /// Fills the library's search with a term and puts the library window in
    /// front of the user.
    private let showSearchResults: @MainActor (String) -> Void
    /// Readies the app to put up a surface, once Shortcuts has brought it
    /// forward.
    private let prepareToSurface: @MainActor @Sendable () -> Void
    private let logger = KernovaLogger(subsystem: "app.kernova", category: "VMIntentGateway")

    /// The library subscription that keeps the Spotlight index current.
    private var libraryEvents: Task<Void, Never>?

    /// VMs a refused write left unindexed, joining the next index write.
    private var pendingIndex: Set<UUID> = []
    /// VMs a refused write left in the index, joining the next index write.
    private var pendingRemove: Set<UUID> = []

    /// Whether Spotlight took the most recent index write; `true` until one is
    /// refused. Only ``write(_:_:)`` changes it, and only its transitions are
    /// logged above debug.
    private(set) var indexAcceptsWrites = true

    package init(
        commands: VMCommandCore,
        readiness: LibraryReadiness,
        index: any VMEntityIndexing = SpotlightVMEntityIndex(),
        record: VMIndexRecord = VMIndexRecord(),
        showSearchResults: @escaping @MainActor (String) -> Void = { _ in },
        prepareToSurface: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        self.commands = commands
        self.readiness = readiness
        self.index = index
        self.record = record
        self.showSearchResults = showSearchResults
        self.prepareToSurface = prepareToSurface
        // Weakly, one main-actor call at a time: an owner that goes away
        // between two batches is what ends the subscription.
        libraryEvents = Task { [weak self] in
            guard let batches = await self?.subscribeOnceReady() else { return }
            await self?.syncWholeLibrary()
            for await batch in batches {
                await self?.apply(batch)
            }
        }
    }

    deinit {
        libraryEvents?.cancel()
    }

    // MARK: - Readiness

    /// Returns once the app's first library read has landed.
    func ready() async {
        await readiness.ready()
    }

    // MARK: - Reads

    /// ``everyVM()``, once the library's first read has landed.
    func vms() async -> [VMEntity] {
        await ready()
        return everyVM()
    }

    /// The VMs a Find's `conditions` admit as `mode` combines them, in
    /// library order.
    ///
    /// Each condition is resolved, a listing's refusal included, in the same
    /// main-actor step as the read it narrows, so it answers for exactly the
    /// VMs read. An `or` over no conditions keeps every VM: a Shortcut that
    /// names no filter is asking for the library, not for nothing.
    func vms(
        meeting conditions: [VMEntityQuery.Condition], mode: EntityQueryComparatorMode
    ) async throws -> [VMEntity] {
        try await perform(.list, on: nil) {
            let predicates = try conditions.map(self.predicate(for:))
            return self.everyVM().filter { vm in
                switch mode {
                case .and: predicates.allSatisfy { $0(vm) }
                case .or: predicates.isEmpty || predicates.contains { $0(vm) }
                @unknown default: true
                }
            }
        }
    }

    /// What `condition` admits.
    private func predicate(for condition: VMEntityQuery.Condition) throws -> (VMEntity) -> Bool {
        switch condition {
        case .admits(let admits):
            return admits
        case .listed(let query, let negated):
            let listed = Set(commands.list(try commands.selection(for: query, verb: .list)).map(\.id))
            return { listed.contains($0.id) != negated }
        case .naming(let network, let holds):
            return try predicate(for: holds(try commands.namedNetwork(network, verb: .list).id))
        case .spelling(let membership, let holds):
            return try predicate(for: holds(try commands.networkMembership(spelledBy: membership)))
        }
    }

    /// Every VM in the library, in library order, each read in full.
    ///
    /// A ``VMEntity`` carries the whole `info` read, so the listing pairs each
    /// row with its own. Both calls are synchronous main-actor reads of state
    /// already in memory, with no suspension between them — a row that lists
    /// and then fails to read is a programming error, not a race, so it is
    /// asserted and skipped rather than being taken for a VM that left.
    private func everyVM() -> [VMEntity] {
        commands.list(.all).compactMap { entity(for: $0.id) }
    }

    /// When the id a VM is read by was named, against when it is read.
    private enum Naming {
        /// In the same synchronous step, so a VM with no read is a programming
        /// error.
        case sameStep
        /// Before a suspension, which the VM may not have outlived.
        case beforeSuspension
    }

    /// One VM's whole read, `nil` for a VM with none: quietly for one named
    /// before a suspension that has since left the library, and otherwise
    /// asserted.
    private func entity(for id: UUID, named: Naming = .sameStep) -> VMEntity? {
        do {
            return VMEntity(try commands.info(.id(id)))
        } catch CommandError.notFound where named == .beforeSuspension {
            return nil
        } catch {
            logger.log(
                .fault,
                "Listed VM \(id.uuidString, privacy: .public) has no info read: \(error.localizedDescription, privacy: .public)"
            )
            assertionFailure("Listed VM \(id.uuidString) has no info read: \(error)")
            return nil
        }
    }

    /// The VMs `ids` names, in library order, skipping any that have since left.
    func vms(withIDs ids: [UUID]) async -> [VMEntity] {
        let wanted = Set(ids)
        return await vms().filter { wanted.contains($0.id) }
    }

    /// Every VM the library's search for `text` admits
    /// (``SidebarNameSearch/admits(_:)``), matched the way a person types it
    /// rather than the way the core's `.name` selector matches — a typed
    /// "sonoma" has neither the case nor the whole of the display name.
    func vms(matching text: String) async -> [VMEntity] {
        let search = SidebarNameSearch(text: text)
        return await vms().filter { search.admits($0.name) }
    }

    func info(_ id: UUID) async throws -> VMInfo {
        try await perform(.info, on: id) { try self.commands.info(.id(id)) }
    }

    func ipAddress(of id: UUID) async throws -> String? {
        try await perform(.ipAddress, on: id) {
            try self.commands.ipAddress(of: .id(id)).address
        }
    }

    /// The VM's named restore points, newest first.
    func snapshots(ofVM id: UUID) async throws -> [SnapshotEntity] {
        try await perform(.snapshots, on: id) {
            try self.commands.snapshots(of: .id(id)).map { SnapshotEntity($0, vm: id, sizes: self) }
        }
    }

    /// ``VMCommandCore/snapshotSize(of:snapshot:)`` of the snapshot `id`
    /// names.
    func snapshotSize(_ id: SnapshotEntityID) async throws -> SnapshotSize? {
        try await perform(.snapshotSizes, on: id.vm) {
            try await self.commands.snapshotSize(of: .id(id.vm), snapshot: id.snapshot)
        }
    }

    /// The VM's disks in attachment order, each measured from its image.
    func storageDisks(ofVM id: UUID) async throws -> [StorageDiskEntity] {
        try await perform(.storageDisks, on: id) {
            try await self.commands.storageDisks(of: .id(id)).map(StorageDiskEntity.init)
        }
    }

    // MARK: - Lifecycle

    func start(_ id: UUID, recovery: Bool, consent: Consent) async throws {
        try await perform(.start, on: id) {
            try await self.commands.start(.id(id), recovery: recovery, consent: consent)
        }
    }

    func stop(
        _ id: UUID, disposition: StopDisposition, consent: Consent,
        givingUpAfter timeout: TimeInterval?
    ) async throws {
        try await perform(.stop, on: id) {
            try await self.commands.stop(
                .id(id), disposition: disposition, consent: consent, timeout: timeout)
        }
    }

    func pause(_ id: UUID) async throws {
        try await perform(.pause, on: id) { try await self.commands.pause(.id(id)) }
    }

    func resume(_ id: UUID, consent: Consent) async throws {
        try await perform(.resume, on: id) {
            try await self.commands.resume(.id(id), consent: consent)
        }
    }

    func suspend(_ id: UUID) async throws {
        try await perform(.suspend, on: id) { try await self.commands.suspend(.id(id)) }
    }

    func restart(
        _ id: UUID, disposition: StopDisposition, consent: Consent,
        givingUpAfter timeout: TimeInterval?
    ) async throws {
        try await perform(.restart, on: id) {
            try await self.commands.restart(
                .id(id), disposition: disposition, timeout: timeout, consent: consent)
        }
    }

    /// ``VMCommandCore/wait(_:until:timeout:)``, answering the VM as it stood
    /// when it met `condition`.
    func wait(
        _ id: UUID, until condition: WaitCondition, givingUpAfter timeout: TimeInterval?
    ) async throws -> VMEntity {
        try await perform(.wait, on: id) {
            VMEntity(try await self.commands.wait(.id(id), until: condition, timeout: timeout))
        }
    }

    /// Brings the VM in front of the user whatever state it is in — its display
    /// where there is one, else its row in the library.
    func reveal(_ id: UUID) async throws {
        try await perform(.reveal, on: id) { try self.commands.reveal(.id(id)) }
    }

    /// Shows the library searched for `term`, once the library has landed.
    ///
    /// An adapter closure rather than a verb: no VM is addressed, so there is
    /// nothing for ``VMCommandCore`` to resolve or refuse.
    func showSearchResults(for term: String) async {
        await ready()
        showSearchResults(term)
    }

    func cancelGuestSetup(_ id: UUID, consent: Consent) async throws {
        try await perform(.cancelGuestSetup, on: id) {
            try self.commands.cancelGuestSetup(.id(id), consent: consent)
        }
    }

    // MARK: - Application

    /// Quits Kernova, save-suspending running and paused VMs.
    ///
    /// Readiness first, like every verb: the library read is what the save pass
    /// has to run over, and a quit racing it would take the process down with
    /// nothing to suspend.
    func quit() async {
        await ready()
        commands.quit()
    }

    // MARK: - Snapshots

    /// Captures a snapshot of the VM, answering the snapshot it took.
    func takeSnapshot(_ id: UUID, name: String, notes: String) async throws -> SnapshotEntity {
        try await perform(.takeSnapshot, on: id) {
            let taken = try await self.commands.takeSnapshot(
                .id(id), name: name, notes: notes, asEphemeralBaseline: false)
            return SnapshotEntity(taken, vm: id, sizes: self)
        }
    }

    func revertToSnapshot(_ id: UUID, snapshot: SnapshotEntityID, consent: Consent) async throws {
        try await perform(.revertToSnapshot, on: id) {
            let listed = try self.listedSnapshot(snapshot, on: id)
            try await self.commands.revertToSnapshot(.id(id), snapshot: listed, consent: consent)
        }
    }

    func deleteSnapshot(_ id: UUID, snapshot: SnapshotEntityID, consent: Consent) async throws {
        try await perform(.deleteSnapshot, on: id) {
            let listed = try self.listedSnapshot(snapshot, on: id)
            try await self.commands.deleteSnapshot(
                .id(id), snapshot: listed, consent: consent)
        }
    }

    func renameSnapshot(_ id: UUID, snapshot: SnapshotEntityID, to newName: String) async throws {
        try await perform(.renameSnapshot, on: id) {
            let named = try VMCommandCore.requireName(newName)
            let listed = try self.listedSnapshot(snapshot, on: id)
            try self.commands.renameSnapshot(.id(id), snapshot: listed, to: named)
        }
    }

    func setSnapshotNotes(_ id: UUID, snapshot: SnapshotEntityID, notes: String) async throws {
        try await perform(.setSnapshotNotes, on: id) {
            let listed = try self.listedSnapshot(snapshot, on: id)
            try self.commands.setSnapshotNotes(.id(id), snapshot: listed, notes: notes)
        }
    }

    /// The snapshot `picked` names, refusing a pick from another VM
    /// (``requirePicked(from:on:kind:)``) and one the VM does not list under
    /// that identifier.
    ///
    /// The snapshot itself can have been deleted or dropped by a revert since
    /// the pick was made, so the identifier resolves against the named VM's own
    /// listing, for every snapshot verb rather than only the ones the core
    /// happens to catch. A revert or delete would be refused there anyway; a
    /// rename or a note edit would not, because both are documented no-ops for
    /// an identifier the manifest does not list, so the miss would report
    /// success having changed nothing.
    ///
    /// The VM is checked as well as the listing because a clone carries its
    /// source's snapshot identifiers: one the named VM lists can still be a
    /// pick made in the VM it was copied from.
    private func listedSnapshot(_ picked: SnapshotEntityID, on vm: UUID) throws -> UUID {
        try requirePicked(from: picked.vm, on: vm, kind: "snapshot")
        guard try commands.snapshots(of: .id(vm)).contains(where: { $0.id == picked.snapshot }) else {
            throw CommandError.itemNotFound(
                vm: try summary(of: vm), item: "snapshot with the identifier \(picked.snapshot.uuidString)")
        }
        return picked.snapshot
    }

    // MARK: - Shared Directories

    /// The folders the VM shares with its guest, in the order it shares them.
    func sharedDirectories(ofVM id: UUID) async throws -> [SharedDirectoryEntity] {
        try await perform(.sharedDirectories, on: id) {
            try self.commands.sharedDirectories(of: .id(id)).map { SharedDirectoryEntity($0, vm: id) }
        }
    }

    /// ``VMCommandCore/addSharedDirectory(_:path:readOnly:)`` of the folder at
    /// `path` (``requireFullPath(_:)``), answering the share the folder chosen
    /// fills.
    ///
    /// `bringForward` asks Shortcuts to bring Kernova forward. It is this
    /// verb's ``ActivationRequester``, so it runs only when the core is about
    /// to put up the open panel for a folder Kernova can't read, before the
    /// panel; a throw from it fails the verb with no panel shown.
    func addSharedDirectory(
        _ id: UUID, path: String, readOnly: Bool,
        bringingForward bringForward: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> SharedDirectoryEntity {
        try await perform(.editSharedDirectory, on: id) {
            let folder = try Self.requireFullPath(path)
            let requester = ActivationRequester(awaiting: { [prepareToSurface] in
                try await bringForward()
                prepareToSurface()
            })
            let shared = try await ActivationRequester.$current.withValue(requester) {
                try await self.commands.addSharedDirectory(.id(id), path: folder, readOnly: readOnly)
            }
            return SharedDirectoryEntity(shared, vm: id)
        }
    }

    /// Stops sharing the folder `picked` names, refusing a pick from another
    /// VM (``requirePicked(from:on:kind:)``).
    func removeSharedDirectory(_ id: UUID, directory picked: SharedDirectoryEntityID) async throws {
        try await perform(.editSharedDirectory, on: id) {
            try self.requirePicked(from: picked.vm, on: id, kind: "shared directory")
            try self.commands.removeSharedDirectory(.id(id), path: picked.path)
        }
    }

    // MARK: - USB Accessories

    /// The accessories the VM's guest holds.
    func usbAccessories(attachedTo id: UUID) async throws -> [USBAccessoryEntity] {
        try await perform(.usbAccessories, on: id) {
            try self.commands.usbAccessories(of: .id(id)).map(USBAccessoryEntity.init)
        }
    }

    /// The accessories macOS has assigned to Kernova that no guest holds.
    func availableUSBAccessories() async throws -> [USBAccessoryEntity] {
        try await perform(.availableUSBAccessories, on: nil) {
            try self.commands.availableUSBAccessories().map(USBAccessoryEntity.init)
        }
    }

    /// The accessories `ids` names, among every one Kernova holds now
    /// (``VMCommandCore/everyUSBAccessory()``).
    func usbAccessories(withIDs ids: [USBAccessoryEntityID]) async throws -> [USBAccessoryEntity] {
        let wanted = Set(ids)
        return try await perform(.availableUSBAccessories, on: nil) {
            try self.commands.everyUSBAccessory().map(USBAccessoryEntity.init).filter {
                wanted.contains($0.id)
            }
        }
    }

    /// Passes the accessory `picked` names through to the VM's guest, refusing
    /// one that is not among the accessories no guest holds — `name` is what
    /// that refusal calls it.
    func attachUSBAccessory(
        _ id: UUID, accessory picked: USBAccessoryEntityID, named name: String
    ) async throws {
        try await perform(.editUSBAccessory, on: id) {
            guard
                let listed = try self.accessory(
                    picked, keyed: { try self.commands.availableUSBAccessory(withKey: $0) },
                    listed: { try self.commands.availableUSBAccessories() })
            else {
                throw CommandError.itemNotFoundOnHost(
                    item: "USB accessory \u{201C}\(name)\u{201D} available to attach")
            }
            try await self.commands.attachUSBAccessory(.id(id), accessory: listed.registryID)
        }
    }

    /// Takes the accessory `picked` names back off the VM's guest, refusing
    /// one the guest does not hold — `name` is what that refusal calls it.
    func detachUSBAccessory(
        _ id: UUID, accessory picked: USBAccessoryEntityID, named name: String
    ) async throws {
        try await perform(.editUSBAccessory, on: id) {
            guard
                let held = try self.accessory(
                    picked, keyed: { try self.commands.usbAccessory(withKey: $0, heldBy: .id(id)) },
                    listed: { try self.commands.usbAccessories(of: .id(id)) }),
                let device = held.deviceID
            else {
                throw CommandError.itemNotFound(
                    vm: try self.summary(of: id), item: "USB accessory \u{201C}\(name)\u{201D} attached")
            }
            try await self.commands.detachUSBAccessory(.id(id), device: device)
        }
    }

    /// The accessory `picked` names: by its durable key through `keyed`, which
    /// refuses a key that may name another unit, or — for one with none — by
    /// this run's registry ID among `listed`.
    private func accessory(
        _ picked: USBAccessoryEntityID, keyed: (String) throws -> USBAccessorySummary?,
        listed: () throws -> [USBAccessorySummary]
    ) throws -> USBAccessorySummary? {
        switch picked {
        case .key(let key): try keyed(key)
        case .registryID: try listed().first { USBAccessoryEntityID($0) == picked }
        }
    }

    /// The accessories the VM takes back automatically.
    func rememberedUSBAccessories(ofVM id: UUID) async throws -> [RememberedUSBAccessoryEntity] {
        try await perform(.usbPairings, on: id) {
            try self.commands.usbPairings(of: .id(id)).map { RememberedUSBAccessoryEntity($0, vm: id) }
        }
    }

    /// Stops the VM taking the accessory `picked` names back, refusing a pick
    /// from another VM (``requirePicked(from:on:kind:)``).
    func forgetUSBAccessory(_ id: UUID, accessory picked: RememberedUSBAccessoryEntityID) async throws {
        try await perform(.forgetUSBPairing, on: id) {
            try self.requirePicked(from: picked.vm, on: id, kind: "remembered USB accessory")
            try self.commands.forgetUSBPairing(.id(id), key: picked.key)
        }
    }

    // MARK: - Library

    /// ``VMCommandCore/clone(_:outcome:waitForOutcome:)``, answering the whole
    /// `info` read of the VM it answers.
    func clone(_ id: UUID, outcome: CloneOutcome?, waitForOutcome: Bool) async throws -> VMEntity {
        try await perform(.clone, on: id) {
            let copy = try await self.commands.clone(
                .id(id), outcome: outcome, waitForOutcome: waitForOutcome)
            return VMEntity(try self.commands.info(.id(copy.id)))
        }
    }

    /// Copies a bundle outside the library into it, answering the VM the copy
    /// became once it has settled.
    ///
    /// Always waited, unlike ``clone(_:outcome:waitForOutcome:)``: the
    /// authority to read `url` is the caller's, held only for the span of this
    /// call, and the copy reads the source for as long as it runs.
    func importVM(from url: URL) async throws -> VMEntity {
        try await perform(.importVM, on: nil) {
            let grant = SandboxFileGrants.shared.startAccessing(url)
            defer { grant?.release() }
            let settled = try await self.commands.importVM(from: url, waitForOutcome: true)
            return VMEntity(try self.commands.info(.id(settled.id)))
        }
    }

    func rename(_ id: UUID, to newName: String) async throws {
        try await perform(.rename, on: id) {
            try self.commands.rename(.id(id), to: VMCommandCore.requireName(newName))
        }
    }

    /// Moves the VM's bundle to the Trash, or `permanently` deletes it.
    ///
    /// The external files a delete can also remove are left to the app's own
    /// sheet, which is the one surface that shows the user which files those
    /// are.
    func delete(_ id: UUID, permanently: Bool, consent: Consent) async throws {
        try await perform(.delete, on: id) {
            try await self.commands.delete(
                .id(id), permanently: permanently, alsoRemoving: [], consent: consent)
        }
    }

    func cancelPreparing(_ id: UUID, consent: Consent) async throws {
        try await perform(.cancelPreparing, on: id) {
            try self.commands.cancelPreparing(.id(id), consent: consent)
        }
    }

    // MARK: - Configuration

    /// Every configuration key, in presentation order.
    func configurationKeys() async -> [VMSettingKeyEntity] {
        await ready()
        return commands.configurationKeys().map(VMSettingKeyEntity.init)
    }

    /// The keys `names` names, in presentation order, skipping any the
    /// keyspace no longer holds.
    func configurationKeys(named names: [String]) async -> [VMSettingKeyEntity] {
        let wanted = Set(names)
        return await configurationKeys().filter { wanted.contains($0.id) }
    }

    /// Every key whose name contains `text`, ignoring case.
    func configurationKeys(matching text: String) async -> [VMSettingKeyEntity] {
        await configurationKeys().filter { $0.id.localizedCaseInsensitiveContains(text) }
    }

    /// ``VMCommandCore/configuration(_:key:)``, answering the value alone.
    func configuration(_ id: UUID, key: String) async throws -> String {
        try await perform(.configuration, on: id) {
            try self.commands.configuration(.id(id), key: key).value
        }
    }

    /// ``VMCommandCore/setConfiguration(_:assignment:consent:)``, answering
    /// the value alone.
    func setConfiguration(_ id: UUID, key: String, value: String, consent: Consent) async throws -> String {
        try await perform(.setConfiguration, on: id) {
            try self.commands.setConfiguration(
                .id(id), assignment: ConfigurationEntry(key: key, value: value), consent: consent
            ).value
        }
    }

    // MARK: - Networks

    /// Every named network, ordered by name, each with the VMs on it read in
    /// full — read the same way as ``vms()``.
    func networks() async throws -> [NetworkEntity] {
        try await perform(.networks, on: nil) { try self.commands.networks().map(self.entity(for:)) }
    }

    /// The networks `ids` names, skipping any that have since been deleted.
    func networks(withIDs ids: [UUID]) async throws -> [NetworkEntity] {
        let wanted = Set(ids)
        return try await networks().filter { wanted.contains($0.id) }
    }

    /// Every network whose name contains `text`, ignoring case.
    func networks(matching text: String) async throws -> [NetworkEntity] {
        try await networks().filter { $0.name.localizedCaseInsensitiveContains(text) }
    }

    func createNetwork(name: String, kind: NetworkKind) async throws -> NetworkEntity {
        try await perform(.createNetwork, on: nil) {
            self.entity(for: try self.commands.createNetwork(name: name, kind: kind))
        }
    }

    func renameNetwork(_ id: UUID, to newName: String) async throws {
        try await perform(.renameNetwork, on: id) {
            try self.commands.renameNetwork(id.uuidString, to: newName)
        }
    }

    /// Deletes the network; refused while a VM is set to join it.
    func deleteNetwork(_ id: UUID) async throws {
        try await perform(.deleteNetwork, on: id) {
            try self.commands.deleteNetwork(id.uuidString)
        }
    }

    private func entity(for network: NetworkSummary) -> NetworkEntity {
        NetworkEntity(network) { entity(for: $0.id) }
    }

    // MARK: - Groups

    /// The library's smart groups, then its folders, each with the VMs in it
    /// read in full — read the same way as ``vms()``.
    func groups() async throws -> [VMGroupEntity] {
        try await perform(.groups, on: nil) {
            try self.commands.groups().map { group in
                VMGroupEntity(group) { self.entity(for: $0.id) }
            }
        }
    }

    /// Every group whose name the library's search for `text` admits
    /// (``SidebarNameSearch/admits(_:)``) — matched as ``vms(matching:)``
    /// matches a VM.
    func groups(matching text: String) async throws -> [VMGroupEntity] {
        let search = SidebarNameSearch(text: text)
        return try await groups().filter { search.admits($0.name) }
    }

    /// Takes `action` on every VM in `group`, answering the VMs it was done to,
    /// in the group's order and as they stand once it is done — less any
    /// deleted since its turn, which has nothing left to read.
    ///
    /// A VM the action concerned and left undone fails the intent, with one
    /// line per such VM — what the `kernova` tool's exit 10 and the app's
    /// summary alert report.
    func groupAction(_ action: VMGroupAction, on group: VMGroupReference) async throws -> [VMEntity] {
        try await perform(action.verb, on: nil) {
            let report = try await self.commands.groupAction(action, on: group)
            guard report.undone.isEmpty else {
                throw CommandError.operationFailed(
                    verb: action.verb, title: report.undoneTitle,
                    message: report.undoneMessage(in: .shortcuts))
            }
            return report.results.compactMap { result in
                guard case .done = result.outcome else { return nil }
                return self.entity(for: result.vm.id, named: .beforeSuspension)
            }
        }
    }

    // MARK: - Arguments

    /// Refuses an item picked from the list of the VM `pickedVM` when the
    /// action names the VM `vm`.
    ///
    /// A pick is only as current as the run that made it: the Shortcut can have
    /// been re-pointed at another VM since, which can list an item the pick
    /// would match — a folder both VMs share — and the pick does not name that
    /// item.
    private func requirePicked(from pickedVM: UUID, on vm: UUID, kind: String) throws {
        guard pickedVM != vm else { return }
        let named = try summary(of: vm)
        throw CommandError.invalidArgument(
            "That \(kind) was picked from another virtual machine, not \u{201C}\(named.name)\u{201D}.")
    }

    /// The VM `id` names, as a refusal names it.
    private func summary(of id: UUID) throws -> VMSummary {
        guard let summary = commands.list(.all).first(where: { $0.id == id }) else {
            throw CommandError.notFound(.id(id))
        }
        return summary
    }

    /// `path` as a full path, a leading `~` read as the user's home folder
    /// (``UserHome``), refusing any other path that does not start at `/`.
    ///
    /// The `kernova` tool reads a relative path against the directory it is
    /// typed in; an action has none to read it against.
    private static func requireFullPath(_ path: String) throws -> String {
        if path == "~" { return UserHome.path }
        if path.hasPrefix("~/") { return UserHome.path + path.dropFirst() }
        guard path.hasPrefix("/") else {
            throw CommandError.invalidArgument(
                "A folder is named by its full path, which starts with \u{201C}/\u{201D} or \u{201C}~/\u{201D}.")
        }
        return path
    }

    // MARK: - Dispatch

    /// Runs `verb` once the library read has landed, logging any refusal, and
    /// any other failure — Shortcuts declining to bring Kernova forward among
    /// them.
    ///
    /// The log line is the only trace an App Intents failure leaves: the
    /// framework shows it to whoever ran the intent and reports it nowhere
    /// else — no alert, no window, nothing a later session can read back.
    ///
    /// `id` names the VM the verb addresses — the network, for a network
    /// verb — and is `nil` for one that addresses neither, as a listing of the
    /// library or of the Mac's USB accessories does, or neither yet: an import
    /// names a file, and neither the row it fills nor the network a create
    /// lists has an identifier until the core has made it.
    private func perform<T>(
        _ verb: VMVerb, on id: UUID?, _ body: () async throws -> T
    ) async throws -> T {
        await ready()
        let subject = id.map { " for \($0.uuidString)" } ?? ""
        do {
            return try await body()
        } catch let failure as CommandError {
            logger.log(
                .notice,
                "Intent \(verb.rawValue, privacy: .public) refused\(subject, privacy: .public): \(failure.message(in: .log), privacy: .public)"
            )
            throw failure
        } catch {
            logger.log(
                .notice,
                "Intent \(verb.rawValue, privacy: .public) failed\(subject, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    // MARK: - Library Tracking

    /// Subscribes to library changes once the app's first read has landed.
    ///
    /// The subscription is taken on the turn readiness resolves on, with
    /// nothing awaited in between: the core seeds its diff from the library as
    /// it stands when the first subscriber arrives, so subscribing behind the
    /// first read leaves the load itself emitting nothing — which is what
    /// ``syncWholeLibrary()`` then covers.
    private func subscribeOnceReady() async -> AsyncStream<[VMLibraryEvent]> {
        await ready()
        return commands.events()
    }

    /// Writes every VM into the index, then drops the records of VMs the index
    /// still holds from an earlier run.
    ///
    /// The index is never emptied: writing first and pruning second, by
    /// identifier, is what keeps the library findable through a process that
    /// ends between the two. A refused write leaves both the index and the
    /// recorded identifiers as they stand, so the previous run's records answer
    /// until the retry lands.
    private func syncWholeLibrary() async {
        let all = await vms()
        let current = all.map(\.id)
        let stale = record.indexedVMIDs.subtracting(current)
        guard await write("indexing every VM", { try await self.index.index(all) }) else {
            pendingIndex.formUnion(current)
            return
        }
        pendingIndex.subtract(current)
        record.indexedVMIDs = Set(current)
        if !stale.isEmpty { await removeFromIndex(Array(stale)) }
    }

    /// Brings the index up to what one pass over the library found, with
    /// whatever an earlier write was refused joining the write it makes.
    ///
    /// One batch is at most one write of each kind.
    private func apply(_ batch: [VMLibraryEvent]) async {
        var present: [UUID] = []
        var absent: [UUID] = []
        for event in batch {
            switch event {
            case .added(let summary): present.append(summary.id)
            case .renamed(let id, _, _): present.append(id)
            case .removed(let id, _): absent.append(id)
            }
        }
        let removing = absent.appending(pendingRemove)
        if !removing.isEmpty { await removeFromIndex(removing) }
        let indexing = present.appending(pendingIndex)
        if !indexing.isEmpty { await addToIndex(indexing) }
    }

    /// Writes the VMs `ids` names, dropping any that has since left the library.
    private func addToIndex(_ ids: [UUID]) async {
        let entities = await vms(withIDs: ids)
        guard !entities.isEmpty else {
            pendingIndex.subtract(ids)
            return
        }
        guard
            await write(
                "indexing \(entities.count) VMs", { try await self.index.index(entities) })
        else {
            pendingIndex.formUnion(ids)
            return
        }
        pendingIndex.subtract(ids)
        record.indexedVMIDs.formUnion(entities.map(\.id))
    }

    /// Drops the records the VMs `ids` names.
    private func removeFromIndex(_ ids: [UUID]) async {
        guard
            await write(
                "removing \(ids.count) VMs from the index",
                { try await self.index.remove(ids) })
        else {
            pendingRemove.formUnion(ids)
            return
        }
        pendingRemove.subtract(ids)
        record.indexedVMIDs.subtract(ids)
    }

    /// Runs one index write, answering whether it landed, and logs the index
    /// starting to refuse writes or taking them again.
    ///
    /// Spotlight is how a searched name is matched, never how a verb runs: a
    /// refusal must neither fail an intent nor end the subscription that would
    /// carry the next write. The caller keeps the identifiers a refused write
    /// covered, and they join the next write the library's content calls for,
    /// or the next launch's.
    private func write(_ operation: String, _ body: () async throws -> Void) async -> Bool {
        do {
            try await body()
            if !indexAcceptsWrites {
                indexAcceptsWrites = true
                logger.log(
                    .notice, "Spotlight took an index write again, \(operation, privacy: .public)")
            }
            return true
        } catch {
            let level: KernovaLogLevel = indexAcceptsWrites ? .warning : .debug
            indexAcceptsWrites = false
            logger.log(
                level,
                "Spotlight failed \(operation, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }
}

extension Array where Element == UUID {
    /// Self, followed by every element of `others` it does not already carry.
    fileprivate func appending(_ others: Set<UUID>) -> [UUID] {
        var seen = Set(self)
        return self + others.filter { seen.insert($0).inserted }
    }
}
