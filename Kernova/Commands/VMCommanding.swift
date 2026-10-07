import Foundation
import KernovaKit

/// Every VM verb Kernova offers, typed end to end.
///
/// One method per verb, addressing VMs by ``VMSelector`` and refusing with
/// ``CommandError``. Every front door reaches VMs through this and nothing
/// else — the AppKit UI in process, a wire client through
/// ``VMCommandEnvelopeRouter`` — so each inherits identical addressing, state
/// gates, and consent semantics.
///
/// A verb refuses what it needs rather than asking for it, and the refusal says
/// what that is: a destructive verb called without consent refuses with
/// ``CommandError/confirmationRequired(_:)``, and a start of a VM still owing
/// its guest the macOS account it was set up with refuses with
/// ``CommandError/guestAccountPasswordRequired(_:)``. The first is answered by
/// re-issuing the call with the consent it takes as a parameter, the second by
/// the verb that supplies the answer and then a plain start. Implementations
/// present nothing.
///
/// `@MainActor` is a decision, not an accident: library state is UI-adjacent,
/// all VZ work already runs on per-VM `VMSession` actors, and command traffic is
/// human-scale. The `await` at each call site makes the isolation an
/// implementation detail — if it is ever revisited, only the implementation
/// moves.
///
/// A verb that completes synchronously is spelled synchronously. A create,
/// clone or import registers its arrival before its first suspension point,
/// whether or not it then waits: a batch's destination reservations have to
/// see each other's arrivals, which one suspension point between them would
/// break.
@MainActor
protocol VMCommanding: AnyObject {
    // MARK: - Reads

    /// The VMs `selection` admits, in its order — each one the sidebar would
    /// list under the same filter, an arrival included. ``VMLibrarySelection/all``
    /// is every VM in library order.
    func list(_ selection: VMLibrarySelection) -> [VMSummary]

    /// `query` with every name in it resolved.
    ///
    /// - Throws: ``CommandError/itemNotFoundOnHost(item:)`` for a network or
    ///   group `query` names that the library does not list, and
    ///   ``CommandError/invalidArgument(_:)`` for a network text naming both a
    ///   mode and a named network.
    func selection(for query: VMListQuery, verb: VMVerb) throws -> VMLibrarySelection

    /// The library's smart groups, then its folders, each in the order the
    /// sidebar lists them, with their members — in library order, a folder's
    /// in its own.
    func groups() throws -> [GroupSummary]

    func info(_ selector: VMSelector) throws -> VMInfo

    /// What the guest's address resolves to on the network its mode joins.
    func ipAddress(of selector: VMSelector) throws -> GuestIPAddress

    /// The VM's named restore points, newest first.
    func snapshots(of selector: VMSelector) throws -> [SnapshotSummary]

    /// The size of each of this VM's snapshots, read off the main
    /// actor — the read walks every file each snapshot holds.
    func snapshotSizes(of selector: VMSelector) async throws -> [UUID: SnapshotSize]

    /// The folders the VM shares with its guest, in the order it carries them.
    func sharedDirectories(of selector: VMSelector) throws -> [SharedDirectorySummary]

    /// The external (non-bundle) files referenced by the VM that the delete
    /// sheet offers to trash, each annotated with whether it is still there and
    /// which other VMs name the same file.
    func externalAttachments(of selector: VMSelector) async throws -> [ExternalAttachment]

    /// Names of other VMs in the library naming the same file as
    /// `(path, bookmark)`.
    ///
    /// Only external paths count — a bundle-relative one is per-VM by
    /// construction. The VM `selector` names is excluded, so a file is never
    /// reported as shared with itself.
    func sharingVMNames(_ selector: VMSelector, path: String, bookmark: Data?) async throws
        -> [String]

    // MARK: - Lifecycle

    /// Starts the VM, running whatever guest setup it still owes first.
    ///
    /// A VM already coming up is not refused: the call joins the bring-up in
    /// flight and answers by its outcome. `recovery` cold-boots a stopped macOS
    /// guest into macOS Recovery, and asks for a different guest than a boot
    /// already under way, so it refuses that one as busy rather than joining.
    ///
    /// Puts nothing in front of the user: a bring-up is not a request to look
    /// at the guest, which is what ``open(_:)`` asks for.
    ///
    /// A VM still owing its guest the macOS account it was set up with refuses
    /// with ``CommandError/guestAccountPasswordRequired(_:)``, which each door
    /// turns into the question it can ask (``VMConsentPolicy``) and answers with
    /// ``provideGuestAccountPassword(_:password:)`` or
    /// ``skipGuestAccount(_:)`` before starting again. A recovery boot asks
    /// nothing: it is not the boot macOS reads an account on.
    ///
    /// Another active VM sharing the machine identity refuses it, asking for
    /// ``ConfirmationKind/startBesideSharedMachineIdentity`` instead where the
    /// user allows starting one anyway; `consent` carries that answer.
    ///
    /// Another active VM using the VM's MAC address on the network it would
    /// join refuses it with ``CommandError/macAddressRemedyRequired(_:)`` where
    /// someone can be asked, offering changes to the VM's network;
    /// `macAddressRemedy` carries the one chosen, which lands as a change to
    /// the VM's configuration before the bring-up — and stays if that fails.
    func start(
        _ selector: VMSelector, recovery: Bool, consent: Consent,
        macAddressRemedy: MACAddressRemedy?
    ) async throws

    /// Removes the entry a failed start or resume named — a storage disk, a
    /// removable medium, or a shared folder — leaving the file or folder itself
    /// untouched: the removal half of the start-failed alert's offer.
    ///
    /// Starts nothing: a caller that wants the VM running follows this with
    /// ``start(_:recovery:consent:macAddressRemedy:)``.
    ///
    /// A VM that has left the library and an entry already gone are both quiet
    /// no-ops: what the removal was for is already true, so neither is a failure
    /// to report.
    func removeStartFailedAttachment(
        _ selector: VMSelector, attachment: StartFailedAttachment
    ) async throws

    /// Holds `password` as the answer for the macOS account the VM owes its
    /// guest, so the next start creates it.
    ///
    /// Refuses ``CommandError/invalidArgument(_:)`` with Virtualization's own
    /// wording for a password macOS will not take, and for a VM that owes no
    /// account — there is nothing for the password to complete. Sets or
    /// replaces: an answer lost with the start that failed to spend it is
    /// supplied again the same way.
    ///
    /// In process only, as ``skipGuestAccount(_:)`` is: a password crossing a
    /// transport would be written into whatever the client keeps — a script's
    /// source, a shortcut's saved parameters, a shell history — so the app's own
    /// sheet is the one surface that gathers it.
    func provideGuestAccountPassword(_ selector: VMSelector, password: String) throws

    /// Ends the macOS account the VM owes its guest, so the next start creates
    /// none and asks nothing.
    ///
    /// macOS asks for an account in Setup Assistant instead. Refuses a VM that
    /// owes none, as ``provideGuestAccountPassword(_:password:)`` does, and is
    /// in process for the reason stated there: the two are one answer.
    func skipGuestAccount(_ selector: VMSelector) throws

    /// Cancels the guest setup a first start is running — a macOS install, or a
    /// Linux installer image being fetched or verified.
    ///
    /// The bundle is preserved and the VM returns to `.initialBoot`, so a later
    /// start resumes it. A VM with no setup in flight refuses.
    func cancelGuestSetup(_ selector: VMSelector, consent: Consent) throws

    /// Stops the VM the way `disposition` names.
    ///
    /// A live-paused guest cannot receive an ACPI shutdown, so `.graceful`
    /// there refuses for confirmation and offers the two dispositions that can.
    /// `.force` always asks: it discards unsaved guest state.
    ///
    /// `timeout` seconds bounds a wait for the guest to actually power off,
    /// refusing with ``CommandError/timedOut(vm:verb:seconds:)`` and touching
    /// nothing when it expires; `nil` returns as soon as the guest has been
    /// asked to go down.
    func stop(
        _ selector: VMSelector, disposition: StopDisposition, consent: Consent,
        timeout: TimeInterval?
    ) async throws

    func pause(_ selector: VMSelector) async throws

    /// Resumes the VM, presenting nothing as
    /// ``start(_:recovery:consent:macAddressRemedy:)`` does — and joining a
    /// restore already in flight, and asking about a shared machine identity
    /// and a MAC address, the same way.
    func resume(
        _ selector: VMSelector, consent: Consent, macAddressRemedy: MACAddressRemedy?
    ) async throws

    /// Save-suspends the VM to its bundle's suspend slot.
    func suspend(_ selector: VMSelector) async throws

    /// Shuts the guest down and starts it again once it has powered off,
    /// bringing it back up the way ``start(_:recovery:consent:macAddressRemedy:)``
    /// would.
    ///
    /// `timeout` seconds bounds the shutdown half alone. A guest still up when
    /// it expires refuses with ``CommandError/timedOut(vm:verb:seconds:)`` and
    /// is not started again; `nil` waits as long as the guest takes.
    ///
    /// Another active VM sharing the machine identity or the MAC address is
    /// asked about before the guest goes down, as
    /// ``start(_:recovery:consent:macAddressRemedy:)`` asks; `consent` and
    /// `macAddressRemedy` carry the answers to the boot.
    func restart(
        _ selector: VMSelector, timeout: TimeInterval?, consent: Consent,
        macAddressRemedy: MACAddressRemedy?
    ) async throws

    /// Brings the VM's display to the front — the detached window for a
    /// pop-out or fullscreen VM, else keyboard focus in the inline display.
    func open(_ selector: VMSelector) throws

    /// Brings the VM in front of the user whatever state it is in: its display
    /// where ``open(_:)`` would surface one, else its row in the library.
    ///
    /// Refuses nothing but a selector no VM answers to — what Spotlight's Open
    /// on a found VM needs, where the VM is stopped as often as not.
    func reveal(_ selector: VMSelector) throws

    /// Selects the VM's bundle in the Finder.
    ///
    /// A create, clone or import still writing its bundle is no VM yet, so it
    /// refuses.
    func showInFinder(_ selector: VMSelector) throws

    // MARK: - Snapshots

    /// Captures a snapshot; `asEphemeralBaseline` also turns Ephemeral Mode on
    /// with it as the baseline, written inside the capture.
    @discardableResult
    func takeSnapshot(
        _ selector: VMSelector, name: String, notes: String, asEphemeralBaseline: Bool
    ) async throws -> SnapshotSummary

    /// Returns the VM to a snapshot, optionally capturing the current state
    /// first so the revert is reversible.
    ///
    /// A revert that resumes asks about a MAC address as
    /// ``start(_:recovery:consent:macAddressRemedy:)`` does.
    func revertToSnapshot(
        _ selector: VMSelector, snapshot: UUID, takingCheckpoint: Bool, consent: Consent,
        macAddressRemedy: MACAddressRemedy?
    ) async throws

    func deleteSnapshot(_ selector: VMSelector, snapshot: UUID, consent: Consent) async throws

    func renameSnapshot(_ selector: VMSelector, snapshot: UUID, to newName: String) throws

    func setSnapshotNotes(_ selector: VMSelector, snapshot: UUID, notes: String) throws

    // MARK: - Library

    /// Writes a new VM's bundle and disk image, answering the row the write
    /// fills.
    ///
    /// `startAfterCreate` boots the VM once its bundle is on disk; a failed
    /// write starts nothing.
    ///
    /// `guestAccountPassword` answers for the macOS account `configuration`
    /// names, and is held for the VM as
    /// ``provideGuestAccountPassword(_:password:)`` holds one — whether or not
    /// anything is started, so a Start taken later in the session asks nothing
    /// either. A parameter rather than a call the caller makes afterwards
    /// because the chained start is this verb's own, and one it refused would
    /// reach the user as a failure nobody asked for.
    ///
    /// Refuses what that verb refuses: a password macOS will not take, and one
    /// given for a configuration naming no account.
    @discardableResult
    func create(
        configuration: VMConfiguration, startAfterCreate: Bool,
        guestAccountPassword: String?
    ) throws -> VMSummary

    /// Copies the VM's bundle into a new one, as `outcome` — `nil` follows the
    /// app's clone preference (``AppPreferences/cloneOutcome(for:)``). New
    /// Machine is refused for a VM that does not offer it
    /// (``VMConfiguration/offersNewMachineClone``).
    ///
    /// `waitForOutcome` answers the VM the copy became, throwing the copy's
    /// failure to this call alone; without it the arrival's row is answered at
    /// once, and a failure reaches ``VMCommandCore/onFailure``. Either way the
    /// arrival is registered before this call first suspends.
    @discardableResult
    func clone(
        _ selector: VMSelector, outcome: CloneOutcome?, waitForOutcome: Bool
    ) async throws -> VMSummary

    /// The clone nobody waits on, which never suspends: the arrival is
    /// registered and its row answered in the caller's own turn.
    /// ``clone(_:outcome:waitForOutcome:)`` without `waitForOutcome`
    /// is this.
    @discardableResult
    func beginClone(
        _ selector: VMSelector, outcome: CloneOutcome?
    ) throws -> VMSummary

    func rename(_ selector: VMSelector, to newName: String) throws

    /// Deletes the VM's bundle and the external files named in `alsoRemoving`.
    ///
    /// `permanently` bypasses the Trash. Files shared with another VM are never
    /// deleted even when their id is passed. Once the VM is gone, any named file
    /// that stayed throws ``CommandError/filesKept(_:)``.
    func delete(
        _ selector: VMSelector, permanently: Bool, alsoRemoving: Set<UUID>, consent: Consent
    ) async throws

    /// Copies a `.kernova` bundle into the library — answering the existing
    /// row when the bundle is already in the library, and joining the import
    /// already copying it when there is one.
    ///
    /// `waitForOutcome` is ``clone(_:outcome:waitForOutcome:)``'s.
    @discardableResult
    func importVM(from url: URL, waitForOutcome: Bool) async throws -> VMSummary

    /// The import nobody waits on, which never suspends — so a batch's
    /// destinations, and two overlapping triggers', are reserved against each
    /// other's arrivals. ``importVM(from:waitForOutcome:)`` without
    /// `waitForOutcome` is this.
    @discardableResult
    func beginImport(from url: URL) throws -> VMSummary

    /// The same import, named the way a caller holding no grant for the file
    /// names it: the implementation obtains one for `path` first.
    @discardableResult
    func importVM(atPath path: String, waitForOutcome: Bool) async throws -> VMSummary

    /// Cancels a create, clone or import so it becomes no VM: what it wrote is
    /// removed, or, once it is publishing, its published bundle is moved to
    /// the Trash. Refuses a selector naming a VM.
    func cancelPreparing(_ selector: VMSelector, consent: Consent) throws

    // MARK: - Storage Disks

    /// Appends the picked files to the VM's storage-disk list, skipping paths
    /// it already carries.
    ///
    /// Takes files rather than opening a panel: a pick carries a
    /// security-scoped bookmark only an in-process open panel can mint, which
    /// is why no wire verb offers this.
    func attachStorageDisks(_ selector: VMSelector, paths files: [PickedFile]) throws

    /// Writes a new sparse image inside the VM's bundle and appends it.
    func createStorageDisk(_ selector: VMSelector, sizeInGB: Int) async throws

    /// Drops a storage disk's entry, and with `trashFile` the file behind it.
    ///
    /// A file another VM still references is never trashed, however `trashFile`
    /// is set. A VM's only storage disk is refused, whichever file backs it: a
    /// VM keeps at least one. Any disk with a sibling goes, `Disk.asif` included.
    /// A file that stays once the entry is gone throws
    /// ``CommandError/filesKept(_:)``.
    func removeStorageDisk(
        _ selector: VMSelector, disk: UUID, trashFile: Bool, consent: Consent
    ) async throws

    /// Replaces a storage disk's user-facing label; an empty label is a no-op.
    func renameStorageDisk(_ selector: VMSelector, disk: UUID, to newLabel: String) throws

    /// Replaces a storage disk's note. An empty note is a legitimate value —
    /// it clears the note.
    func setStorageDiskNotes(_ selector: VMSelector, disk: UUID, notes: String) throws

    func setStorageDiskReadOnly(_ selector: VMSelector, disk: UUID, readOnly: Bool) throws

    /// Rewrites the boot order; disks `order` does not name keep their relative
    /// order behind those it does.
    func reorderStorageDisks(_ selector: VMSelector, order: [UUID]) throws

    // MARK: - Removable Media

    /// Appends the picked files to the VM's removable-media list, skipping
    /// paths it already carries — off the wire for the reason
    /// ``attachStorageDisks(_:paths:)`` states.
    func attachRemovableMedia(_ selector: VMSelector, paths files: [PickedFile]) throws

    /// Writes a new sparse image at a destination the user chose and attaches
    /// it as a hot-pluggable removable disk.
    ///
    /// Off the wire: the write rides a live save-panel grant, which is also
    /// what the entry's bookmark is minted from.
    func createRemovableMedia(
        _ selector: VMSelector, sizeInGB: Int, destinationURL: URL
    ) async throws

    /// Drops a removable medium's entry, and with `trashFile` the file behind
    /// it.
    ///
    /// The bundled Guest Agent installer and files shared with another VM are
    /// never trashed. A file that stays once the entry is gone throws
    /// ``CommandError/filesKept(_:)``.
    func removeRemovableMedia(
        _ selector: VMSelector, item: UUID, trashFile: Bool, consent: Consent
    ) async throws

    /// Detaches a removable medium and keeps its file — what a running guest
    /// sees as an eject.
    func ejectRemovableMedia(_ selector: VMSelector, item: UUID) throws

    /// Replaces a removable medium's label; an empty label is a no-op.
    func renameRemovableMedia(_ selector: VMSelector, item: UUID, to newLabel: String) throws

    /// Replaces a removable medium's note. An empty note clears it.
    func setRemovableMediaNotes(_ selector: VMSelector, item: UUID, notes: String) throws

    func setRemovableMediaReadOnly(_ selector: VMSelector, item: UUID, readOnly: Bool) throws

    // MARK: - Shared Directories

    /// Appends the picked folders to the VM's shared-directory list, skipping
    /// paths it already carries — off the wire for the reason
    /// ``attachStorageDisks(_:paths:)`` states.
    func addSharedDirectories(_ selector: VMSelector, paths files: [PickedFile]) throws

    /// Shares one folder with the guest, leaving a folder the VM already shares
    /// as it is.
    ///
    /// On the wire where ``addSharedDirectories(_:paths:)`` is not, and named by
    /// path rather than by pick: a share is reopened at every boot, so the
    /// implementation obtains the grant for the path a client named — after the
    /// VM and its state have decided the answer — and mints the bookmark that
    /// outlives the session.
    func addSharedDirectory(_ selector: VMSelector, path: String, readOnly: Bool) async throws

    /// Drops a shared directory's entry, leaving the folder itself alone.
    func removeSharedDirectory(_ selector: VMSelector, directory: UUID) throws

    /// Drops the share the folder at `path` fills — the same edit named the way
    /// a caller with no ids to hand names it.
    func removeSharedDirectory(_ selector: VMSelector, path: String) throws

    func setSharedDirectoryReadOnly(
        _ selector: VMSelector, directory: UUID, readOnly: Bool
    ) throws

    // MARK: - USB Accessories

    /// The accessories the VM's guest is holding right now, each named by the
    /// attachment a detach takes back.
    func usbAccessories(of selector: VMSelector) throws -> [USBAccessorySummary]

    /// The accessories macOS has assigned to Kernova that no guest is holding.
    ///
    /// Addresses no VM: the user assigns an accessory to the app rather than to
    /// a guest, so which VM could take it is the caller's question, not the
    /// list's.
    func availableUSBAccessories() throws -> [USBAccessorySummary]

    /// The accessories one VM takes back automatically, or every VM's when
    /// `selector` is `nil`.
    ///
    /// Unlike the two listings above, these rows describe hardware that is
    /// usually not plugged in — which is the whole reason they can be listed
    /// and removed at all.
    func usbPairings(of selector: VMSelector?) throws -> [USBPairingSummary]

    /// Stops the VM taking the accessory `key` names back.
    func forgetUSBPairing(_ selector: VMSelector, key: String) throws

    /// Passes the accessory `accessory` names through to the VM's running
    /// guest.
    func attachUSBAccessory(_ selector: VMSelector, accessory: UInt64) async throws

    /// Takes the passthrough device `device` names back off the guest.
    func detachUSBAccessory(_ selector: VMSelector, device: UUID) async throws

    // MARK: - Configuration

    /// Every configuration key `configuration` and `setConfiguration` address,
    /// in presentation order.
    ///
    /// Addresses no VM: the keyspace is the same for all of them, and which
    /// keys a particular VM answers for is what ``configuration(_:keys:)``
    /// reports.
    func configurationKeys() -> [ConfigurationKeyDescriptor]

    /// The VM's values for `keys`, or for every key that applies to it when
    /// `keys` is `nil`.
    ///
    /// Each value is written the way ``setConfiguration(_:assignments:consent:)``
    /// parses it back.
    func configuration(_ selector: VMSelector, keys: [String]?) throws -> [ConfigurationEntry]

    /// Applies every assignment or none, answering the values the assigned keys
    /// ended up holding.
    ///
    /// Each key's gate and value is checked before anything is written, so a
    /// batch naming one key the VM's state will not take, or one value it
    /// cannot parse, changes nothing. A configuration key's assignment that
    /// leaves its value where it is is taken in any state; a host-state key's
    /// gate is asked whether its value moves or not, so naming one is refused
    /// wherever that key is pinned, a snapshot capture among them.
    /// `consent` supplies what the one assignment that asks for it needs —
    /// turning automatic clipboard passthrough on.
    @discardableResult
    func setConfiguration(
        _ selector: VMSelector, assignments: [ConfigurationEntry], consent: Consent
    ) throws -> [ConfigurationEntry]

    // MARK: - Networks

    /// The library's named networks, ordered by name, each with the VMs on it.
    ///
    /// Addresses no VM: a network is the library's, and a VM joins one through
    /// its `network.membership` key.
    func networks() -> [NetworkSummary]

    /// Lists a new network named `name`, whose VMs run in `kind`. Refuses a
    /// name another network has, ignoring case, and one a membership value
    /// already spells.
    @discardableResult
    func createNetwork(name: String, kind: NetworkKind) throws -> NetworkSummary

    /// Renames the network `network` names, by identifier or by name. A VM
    /// names its network by identifier, so no VM changes.
    func renameNetwork(_ network: String, to newName: String) throws

    /// Stops listing the network `network` names, first moving each VM on it
    /// to a network of its own, which narrows what it reaches and widens
    /// nothing (docs/NETWORKING.md).
    ///
    /// Every move or none: a VM whose state takes no change to its membership
    /// refuses the whole delete, naming it. A snapshot taken on the network
    /// still names it, and a revert puts the VM back on it, unlisted.
    func deleteNetwork(_ network: String) throws

    // MARK: - Guest Agent Disk

    /// Puts the bundled guest-agent installer image in front of the guest,
    /// answering which bus it reached the guest on.
    ///
    /// A guest that already carries the image attaches nothing and says so.
    @discardableResult
    func mountGuestAgentDisk(_ selector: VMSelector) throws -> GuestAgentDiskMountOutcome

    /// Takes the bundled installer image away again.
    func unmountGuestAgentDisk(_ selector: VMSelector) throws

    // MARK: - Application

    /// Quits Kernova — the explicit quit every out-of-process door shares,
    /// save-suspending running and paused VMs on the way out.
    ///
    /// Presents nothing and asks nothing: the caller typed the quit, so there
    /// is no consent left to gather.
    func quit()

    // MARK: - Observation

    /// A stream of library changes, for callers that cannot observe the model.
    ///
    /// Each element is every change one pass over the library found, in the
    /// order found, so a launch or a batch import lands as one element. Each
    /// call returns its own stream; ending iteration drops it.
    func events() -> AsyncStream<[VMLibraryEvent]>
}

/// The unbounded spelling of `stop`.
///
/// Only a door whose caller is sitting there waiting supplies a deadline — the
/// `kernova` tool's `--timeout`. An in-process door spells the verb without
/// one: a user watching a window can see the guest is taking its time and stop
/// it themselves.
extension VMCommanding {
    func stop(_ selector: VMSelector, disposition: StopDisposition, consent: Consent) async throws {
        try await stop(selector, disposition: disposition, consent: consent, timeout: nil)
    }
}

extension VMCommanding {
    @discardableResult
    func takeSnapshot(_ selector: VMSelector, name: String, notes: String) async throws
        -> SnapshotSummary
    {
        try await takeSnapshot(selector, name: name, notes: notes, asEphemeralBaseline: false)
    }
}
