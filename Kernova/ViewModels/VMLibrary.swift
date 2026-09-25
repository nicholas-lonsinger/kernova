import Foundation
import KernovaKit
import KernovaLogging

/// The set of VMs the app knows about, the arrivals becoming ones, and the
/// bookkeeping that keeps them in step with the bundles on disk: membership
/// and sidebar ordering, the one ``adopt(_:)`` every bundle enters the library
/// through, the policy every write of a VM's settings and pairings passes on
/// its way to that VM's ``VMBundle``, and the revert registry. The library
/// read, the directory-watched reconcile and the arrival pipeline live in
/// `VMLibrary+Membership.swift`.
///
/// It also sequences the collaborators it owns — ``macAddresses``,
/// ``removableMedia`` and ``guestAddresses`` — because only the library knows
/// where in a configuration write each of them belongs.
///
/// Headless: it imports no AppKit and holds no presenter. Anything a user has
/// to be told about leaves through ``onFailure``, and the `VMInstance` hooks
/// whose handling belongs elsewhere — ``onAgentBecameCurrent``,
/// ``onPoweredOff`` and ``onSessionBecameAttachable`` — leave through their own
/// closures.
/// ``VMLibraryViewModel`` is the AppKit adapter that owns one of these and
/// wires them all.
@MainActor
@Observable
final class VMLibrary: VMInstanceRoster, USBAccessoryPairingWriting {
    nonisolated static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMLibrary")

    // MARK: - Services

    let storageService: any VMStorageProviding
    /// The file work every bundle's machine files go through.
    let machineFiles: any VMBundleMachineFileWorking
    let lifecycle: VMLifecycleCoordinator

    /// Where each VM's answer for the account it owes its guest is held — the
    /// half of that account no bundle carries. Keyed by identifier, so a
    /// create's answer is held for its arrival and stays with the VM it becomes.
    private let guestAccountPasswords: any GuestAccountPasswordStoring

    let preferences: AppPreferences

    // MARK: - Collaborators

    /// Drives a running VM's XHCI removable-media list to what its
    /// configuration asks for, dispatched from ``applyLivePolicy(for:old:new:)``.
    @ObservationIgnored let removableMedia: VMRemovableMediaReconciler

    /// The uniqueness of each VM's MAC address across the library.
    @ObservationIgnored let macAddresses: VMMACAddressRegistry

    /// Which identity another live VM already claims, for the refusal every
    /// bring-up passes.
    @ObservationIgnored let liveIdentities: VMLiveIdentities

    /// The address each running VM's guest is seen using on its network.
    @ObservationIgnored let guestAddresses: GuestAddressObserver

    // MARK: - Adapter Hooks

    /// Receives every failure the library needs a user to see.
    ///
    /// The library presents nothing itself; the adapter routes these to its
    /// presenter, buffering them until one is attached.
    @ObservationIgnored var onFailure: ((_ title: String, _ message: String) -> Void)?

    /// Fires when a VM's guest agent handshakes a current version, for the
    /// installer auto-eject.
    @ObservationIgnored var onAgentBecameCurrent: ((VMInstance) -> Void)?

    /// Fires when a VM powers off, for the Ephemeral Mode baseline revert.
    @ObservationIgnored var onPoweredOff: ((VMInstance) -> Void)?

    /// Fires when an arrival settles as no VM, in the same main-actor step as
    /// — and just before — its row leaves the library, so anything the hook
    /// emits precedes every observer of the removal.
    @ObservationIgnored var onArrivalFailed: ((VMArrival, any Error) -> Void)?

    /// Fires when a VM reaches a state a device can be attached to, for the
    /// accessories paired with it.
    @ObservationIgnored var onSessionBecameAttachable: ((VMInstance) -> Void)?

    // MARK: - Capabilities

    /// Every per-VM capability predicate, derived from this library — what a
    /// verb's own guard asks and what each surface enables its controls from.
    var capabilities: VMCapabilityCatalog { VMCapabilityCatalog(library: self) }

    // MARK: - State

    /// Every row of the library in sidebar order, each identifier at most
    /// once: the VMs, and the arrivals becoming ones.
    ///
    /// Written only in this file, where ``adopt(_:)`` is the one path a `.vm`
    /// entry enters by.
    private(set) var entries: [LibraryEntry] = []

    /// The VMs, in sidebar order.
    var instances: [VMInstance] { entries.compactMap(\.vm) }

    /// The creates, clones and imports still writing their bundles.
    var arrivals: [VMArrival] { entries.compactMap(\.arrival) }

    #if DEBUG
    /// Adds `instance` to the library as it stands, unwired and unread — a
    /// test's stand-in for a VM a load would have adopted.
    func admitForTesting(_ instance: VMInstance) {
        entries.append(.vm(instance))
    }
    #endif

    /// Whether the library's first read from disk has finished.
    ///
    /// `false` until then, so UI can tell "no VMs" from "not read yet" — an empty
    /// `entries` means nothing before the first `loadVMs()` applies. Stays
    /// `true` across later reloads, and is set even when the read fails: the
    /// answer is then known to be empty.
    var hasLoadedLibrary = false

    var selectedID: UUID? {
        didSet {
            guard selectedID != oldValue else { return }
            preferences.lastSelectedVMID = selectedID
        }
    }

    /// The selected row, whichever kind it is.
    var selectedEntry: LibraryEntry? {
        entries.first { $0.id == selectedID }
    }

    /// The selected row when it is a VM.
    var selectedInstance: VMInstance? { selectedEntry?.vm }

    /// Whether anything is doing work that terminating would destroy rather
    /// than suspend — a bundle still being created, cloned or imported, a VM
    /// mid-save/restore/start/install, or a revert writing a snapshot's files
    /// back over the bundle.
    ///
    /// Excludes settled `.running` and `.paused` VMs, which termination
    /// save-suspends.
    var hasUninterruptibleWork: Bool {
        !arrivals.isEmpty || instances.contains(where: \.isTransitioning)
            || hasRevertInFlight
    }

    /// Whether any VM is mid-save — the one operation an explicit quit has to
    /// wait out rather than terminate through.
    ///
    /// Narrower than ``hasUninterruptibleWork``, which the window reconcile uses
    /// to hold back a quit nobody asked for.
    var hasSaveInFlight: Bool {
        instances.contains { $0.phase.terminationMustWaitOut }
    }

    /// Whether `instance` has work in flight that its sidebar row renders as busy.
    ///
    /// The lifecycle term is the one a pause or resume shows up in: both hold a
    /// status that reads as resting — `.running` for a pause, `.paused` for a
    /// resume — for the whole VZ await, so ``VMStatus`` alone renders nothing
    /// while one is settling.
    func isBusy(_ instance: VMInstance) -> Bool {
        instance.isTransitioning || lifecycle.hasUnsettledOperation(for: instance.id)
    }

    /// Whether `instance` is at rest with nothing in flight against it — the
    /// VMs a reconcile may evict once their bundle is gone.
    func isIdleAtRest(_ instance: VMInstance) -> Bool {
        instance.isAtRest
            && !lifecycle.hasActiveOperation(for: instance.id)
            && !lifecycle.hasUnsettledOperation(for: instance.id)
            && !hasRevertInFlight(for: instance.id)
    }

    /// Whether this build can pass a host USB accessory through to a guest at
    /// all — the OS and the signature together, answered once by
    /// ``USBAccessorySupport/makeService(entitlements:)``.
    var supportsUSBAccessories: Bool { lifecycle.usbAccessoryService != nil }

    /// `true` from the moment a clone of `instance` registers its arrival until
    /// that arrival leaves the library — a cancelled clone stays until its
    /// uninterruptible copy settles, so the lock outlives the cancel by exactly
    /// the copy.
    func hasCloneInFlight(from instance: VMInstance) -> Bool {
        arrivals.contains {
            if case .cloning(let sourceID) = $0.kind { sourceID == instance.id } else { false }
        }
    }

    var customOrder: [UUID] = []

    /// Bundle names whose load failures have already been reported to the user.
    ///
    /// Prevents repeated error dialogs for persistently corrupted bundles across
    /// successive `reconcileWithDisk()` calls.
    var reportedFailedBundles: Set<String> = []

    /// Bundle names already reported as holding an identifier the library
    /// knows at another bundle, for the same reason.
    var reportedDuplicateBundles: Set<String> = []

    // MARK: - Directory Watcher

    var directoryWatcher: VMDirectoryWatcher?

    // MARK: - Initialization

    init(
        storageService: any VMStorageProviding,
        machineFiles: any VMBundleMachineFileWorking,
        lifecycle: VMLifecycleCoordinator,
        preferences: AppPreferences,
        vmnetNetworks: any VmnetNetworkProviding,
        arpTable: any ARPTableReading,
        entitlements: EntitlementService,
        guestAccountPasswords: any GuestAccountPasswordStoring =
            InMemoryGuestAccountPasswordStore()
    ) {
        self.storageService = storageService
        self.machineFiles = machineFiles
        self.guestAccountPasswords = guestAccountPasswords
        self.lifecycle = lifecycle
        self.preferences = preferences
        self.removableMedia = VMRemovableMediaReconciler(lifecycle: lifecycle)
        let guestAddresses = GuestAddressObserver(
            reader: arpTable, vmnetNetworks: vmnetNetworks,
            canObserve: entitlements.supportsGuestAddressObservation,
            isVMNetworkingEntitled: entitlements.hasVMNetworking)
        self.guestAddresses = guestAddresses
        let macAddresses = VMMACAddressRegistry(guestAddresses: guestAddresses)
        self.macAddresses = macAddresses
        self.liveIdentities = VMLiveIdentities(macAddresses: macAddresses, preferences: preferences)

        // Assigned after every stored property is set: each closure — and the
        // roster — references the library, which cannot be named before then.
        removableMedia.onSettle = { [weak self] instance, media in
            self?.settleRemovableMedia(of: instance, toLive: media)
        }
        removableMedia.onFailure = { [weak self] error in
            self?.presentError(error)
        }
        macAddresses.roster = self
        liveIdentities.roster = self
        macAddresses.onFailure = { [weak self] title, message in
            self?.surfaceError(message, title: title)
        }
        guestAddresses.roster = self
    }

    // MARK: - Adoption

    /// One VM bundle as read from disk, before it becomes a `VMInstance`.
    ///
    /// `VMInstance` is `@MainActor`, so the read and the model construction have
    /// to be separable: this is what crosses back from the reading task.
    struct ScannedBundle: Sendable {
        let read: VMBundleRead
        let phase: VMLifecyclePhase

        var url: URL { read.files.url }
    }

    /// What ``adopt(_:publishing:)`` did with a bundle.
    enum Adoption {
        /// The bundle became a VM — a new row, or the arrival that wrote it.
        case adopted(VMInstance)
        /// The VM was already built from this bundle.
        case alreadyAdopted(VMInstance)
        /// A VM whose bundle had moved, or been renamed, was pointed at it.
        case rebound(VMInstance)
        /// The bundle is the one `arrival` is publishing, which only that
        /// arrival's own pipeline adopts.
        case publishing(VMArrival)
        /// Another bundle already holds this identifier; this one was reported
        /// and left out. `existing` is `nil` when the holder is an arrival.
        case duplicate(of: VMInstance?, at: URL)
    }

    /// Turns a bundle read from disk into library membership, keyed by the
    /// identifier it carries — the one decision launch, reconcile and
    /// publication all take.
    ///
    /// An arrival's row becomes a VM only when its own pipeline passes it as
    /// `arrival`, replaced in place to keep its place and selection; that
    /// pipeline is what decides whether a cancel taken during the rename
    /// leaves any VM at all. A VM already built from the bundle is left alone;
    /// a VM whose own bundle has gone, or is this one spelled another way, is
    /// pointed at it; and a second bundle holding a known identifier is
    /// reported once, not adopted.
    func adopt(_ scanned: ScannedBundle, publishing arrival: VMArrival? = nil) -> Adoption {
        let url = scanned.url
        guard let index = entries.firstIndex(where: { $0.id == scanned.read.configuration.id })
        else {
            let instance = makeInstance(scanned)
            entries.append(.vm(instance))
            return .adopted(instance)
        }
        switch entries[index] {
        case .arriving(let holder):
            guard isSameBundle(holder.destinationURL, url) else {
                return reportDuplicate(at: url, holderName: holder.name, existing: nil)
            }
            guard holder === arrival else { return .publishing(holder) }
            let instance = makeInstance(scanned)
            entries[index] = .vm(instance)
            return .adopted(instance)
        case .vm(let instance):
            if VMBundleIdentity.spelling(instance.bundleURL) == VMBundleIdentity.spelling(url) {
                return .alreadyAdopted(instance)
            }
            if let holder = storageService.bundleIdentity(at: instance.bundleURL),
                holder != storageService.bundleIdentity(at: url)
            {
                return reportDuplicate(at: url, holderName: instance.name, existing: instance)
            }
            #log(
                Self.logger, .notice,
                "'\(instance.name, privacy: .public)' moved to \(url.lastPathComponent, privacy: .public) — re-bound to its new bundle"
            )
            instance.rebind(to: VMBundle(scanned.read, machineFiles: machineFiles))
            reportUnreadablePairings(of: scanned.read)
            return .rebound(instance)
        }
    }

    /// Whether two URLs name one bundle on disk, however each is spelled; a URL
    /// with no bundle at it names none.
    func isSameBundle(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let identity = storageService.bundleIdentity(at: lhs) else { return false }
        return identity == storageService.bundleIdentity(at: rhs)
    }

    /// Reports a bundle whose identifier another bundle already holds, once per
    /// bundle name.
    private func reportDuplicate(
        at url: URL, holderName: String, existing: VMInstance?
    ) -> Adoption {
        let bundleName = url.deletingPathExtension().lastPathComponent
        if reportedDuplicateBundles.insert(bundleName).inserted {
            #log(
                Self.logger, .error,
                "\(url.lastPathComponent, privacy: .public) carries the identifier of '\(holderName, privacy: .public)', which the library already holds — left out"
            )
            surfaceError(
                "\u{201C}\(bundleName)\u{201D} has the same identifier as \u{201C}\(holderName)\u{201D}, which is already in the library, so Kernova didn\u{2019}t add it.",
                title: "Duplicate Virtual Machine")
        }
        return .duplicate(of: existing, at: url)
    }

    /// Builds the instance for a bundle read from disk, wired to this library.
    private func makeInstance(_ scanned: ScannedBundle) -> VMInstance {
        let instance = VMInstance(
            bundle: VMBundle(scanned.read, machineFiles: machineFiles), phase: scanned.phase,
            preferences: preferences)
        wireHooks(for: instance)
        reportUnreadablePairings(of: scanned.read)
        return instance
    }

    /// Tells the user about a pairings file a read left in place because it
    /// could not decode it.
    private func reportUnreadablePairings(of read: VMBundleRead) {
        guard let unreadable = read.pairingsUnreadable else { return }
        #log(
            Self.logger, .error,
            "The USB accessory pairings of '\(read.configuration.name, privacy: .public)' could not be read and were left in place: \(unreadable.localizedDescription, privacy: .public)"
        )
        surfaceError(
            "\u{201C}\(read.configuration.name)\u{201D} won\u{2019}t take any USB accessory back automatically. \(unreadable.localizedDescription)",
            title: "USB Accessories Not Read")
    }

    // MARK: - Arrival Rows

    /// Adds `arrival`'s row and selects it.
    ///
    /// Selection moves only when no other arrival holds it, so a second arrival
    /// registering mid-operation can't steal the sidebar's focus from the one the
    /// user is already watching.
    func register(_ arrival: VMArrival) {
        entries.append(.arriving(arrival))
        sortEntries()
        persistOrder()
        if selectedEntry?.arrival == nil {
            selectedID = arrival.id
        }
    }

    /// Removes `arrival`'s row — matched by the object, since adoption may
    /// already have replaced it with the VM of the same identifier, which then
    /// stays.
    ///
    /// Only an arrival that became no VM leaves here, so the account answer
    /// held for it goes with it.
    func removeArrival(_ arrival: VMArrival) {
        guard let index = entries.firstIndex(where: { $0.arrival === arrival }) else { return }
        entries.remove(at: index)
        persistOrder()
        if selectedID == arrival.id {
            selectedID = entries.first?.id
        }
        guestAccountPasswords.remove(for: arrival.id)
    }

    /// Drops `instance` from the library, moving the selection off it.
    func evict(_ instance: VMInstance) {
        entries.removeAll { $0.vm === instance }
        if selectedID == instance.id {
            selectedID = entries.first?.id
        }
        // Nothing left can ask for the account, so nothing may still hold the
        // answer — whichever way the VM left, and whether or not its bundle
        // survived the departure.
        guestAccountPasswords.remove(for: instance.id)
    }

    // MARK: - Reorder

    /// Moves rows in the sidebar list and persists the new order.
    func moveEntries(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        persistOrder()
        #log(Self.logger, .notice, "Reordered VMs in sidebar")
    }

    /// Sorts rows by custom order, falling back to `createdAt` for unordered ones.
    func sortEntries() {
        let orderMap = Dictionary(zip(customOrder, customOrder.indices), uniquingKeysWith: { first, _ in first })
        entries.sort { lhs, rhs in
            switch (orderMap[lhs.id], orderMap[rhs.id]) {
            case let (.some(l), .some(r)):
                return l < r
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.configuration.createdAt < rhs.configuration.createdAt
            }
        }
    }

    /// Snapshots the current row order into customOrder and persists it via `AppPreferences.vmOrder`.
    func persistOrder() {
        customOrder = entries.map(\.id)
        preferences.vmOrder = customOrder
    }

    // MARK: - Revert Registry

    /// One revert in flight, and the VM whose bundle it rewrites.
    struct RevertRegistration {
        let instanceID: UUID
        let task: Task<Void, Never>
    }

    /// Every revert in flight, keyed by a per-request id.
    ///
    /// Keyed by the request rather than the VM: two reverts of one VM would
    /// share a slot and lose one of them, as would two ephemeral VMs powering
    /// off together under a VM-keyed map. Each registration names its VM, so a
    /// caller that only cares about one can still ask.
    ///
    /// The registry is library state — a revert rewrites the bundle a VM in
    /// `instances` is built from — while the verb that fills it belongs to the
    /// command core.
    var revertTasks: [UUID: RevertRegistration] = [:]

    /// Whether any revert is in flight — requested, whether or not it has
    /// reached the copy.
    var hasRevertInFlight: Bool { !revertTasks.isEmpty }

    /// Whether a revert of this VM in particular is in flight.
    ///
    /// The signal is set synchronously when the revert is requested, so a
    /// power-off's baseline revert is visible to anything that looks on the
    /// very next main-actor turn.
    func hasRevertInFlight(for instanceID: UUID) -> Bool {
        revertTasks.values.contains { $0.instanceID == instanceID }
    }

    /// Waits until no revert is in flight, including any a running revert
    /// starts.
    ///
    /// Unbounded, matching the termination pass's other waits: a revert
    /// interrupted mid-write is what the wait exists to prevent.
    ///
    /// A revert of a live VM resumes it once the files are in place, and the
    /// wait spans that resume rather than ending at the copy — so the VM the
    /// revert hands back live is save-suspended by the pass, which is what
    /// termination does with any live VM. Ending at the copy would need a
    /// second signal beside this registry and would leave the guest to die
    /// inside `restoreMachineStateFrom`.
    func waitForRevertsToSettle() async {
        while let registration = revertTasks.values.first { await registration.task.value }
    }

    // MARK: - Guest Account

    /// The password held for the account `instance` owes its guest, or `nil`
    /// when nobody has answered for it yet.
    func heldGuestAccountPassword(for instance: VMInstance) -> GuestAccountPassword? {
        guestAccountPasswords.password(for: instance.id)
    }

    /// Holds `password` as the answer for the account the VM identified by
    /// `id` owes its guest — or will, once the arrival writing it is adopted —
    /// replacing whatever was held.
    func holdGuestAccountPassword(_ password: GuestAccountPassword, for id: UUID) {
        guestAccountPasswords.set(password, for: id)
    }

    /// Ends the account `instance` owes its guest: the persisted intent and the
    /// held password, together.
    ///
    /// One call for both halves, because either left behind outlives the account
    /// it describes — the intent as a question about an account that can never be
    /// created, the password as a secret nothing will ever spend.
    ///
    /// The intent is written first and the password dropped only once it
    /// landed, so a write that is refused or not saved leaves both halves as
    /// they were — and the caller, whose operation this retraction is a step
    /// of, reports the outcome.
    func retractGuestAccount(for instance: VMInstance) -> SettingsWrite {
        let outcome = updateConfiguration(of: instance) { $0.pendingGuestAccount = nil }
        guard case .saved = outcome else {
            #log(
                Self.logger, .notice,
                "Kept the guest account for '\(instance.name, privacy: .public)': the retraction did not land"
            )
            return outcome
        }
        guestAccountPasswords.remove(for: instance.id)
        return outcome
    }

    // MARK: - Settings Writes

    /// Connects `instance`'s hooks to this library.
    ///
    /// Called at every `VMInstance` construction site the library and its
    /// adapter own.
    func wireHooks(for instance: VMInstance) {
        // Every closure is stored on `instance` or on the activity it owns, so it
        // must capture it weakly:
        // a strong capture forms a self-retain cycle that leaks the VMInstance after
        // it's removed from `entries`.
        instance.onUpdateConfiguration = { [weak self, weak instance] mutate in
            guard let self, let instance else { return .refused(.noLibrary) }
            return self.updateConfiguration(of: instance, mutate: mutate)
        }
        instance.onUpdateSettings = { [weak self, weak instance] configuration, hostState in
            guard let self, let instance else { return .refused(.noLibrary) }
            return self.updateSettings(
                of: instance, configuration: configuration, hostState: hostState)
        }
        instance.activity.liveIdentityConflict = { [weak self, weak instance] in
            guard let self, let instance else { return nil }
            return self.liveIdentities.conflict(for: instance)
        }
        // Auto-eject the installer disk once the agent handshakes a current version.
        // Wired here so it fires regardless of which window is open.
        instance.onAgentBecameCurrent = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.onAgentBecameCurrent?(instance)
        }
        // An Ephemeral Mode VM goes back to its baseline on every power-off.
        instance.activity.onPoweredOff = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.onPoweredOff?(instance)
        }
        // A guest that has just become attachable takes back the accessories
        // paired with it, and is a running guest whose address can be watched.
        instance.activity.onSessionBecameAttachable = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.guestAddresses.watch()
            self.onSessionBecameAttachable?(instance)
        }
    }

    /// How a settings write ended.
    enum SettingsWrite {
        /// The change is committed to the bundle — or it changed nothing.
        case saved
        /// Nothing changed.
        case refused(SettingsRefusal)
        /// A file's write failed, which the library has already presented;
        /// memory equals what each file holds.
        case notSaved(SettingsWriteFailure)

        /// Throws whatever kept the write from landing, for a write that is a
        /// step of a larger operation.
        func get() throws {
            switch self {
            case .saved: return
            case .refused(let refusal): throw refusal
            case .notSaved(let failure): throw failure
            }
        }
    }

    /// A settings write that did not land whole: the file whose write failed,
    /// and the files the same write had already committed.
    struct SettingsWriteFailure: LocalizedError {
        enum File: Sendable, Equatable {
            case configuration
            case hostState
        }

        let failed: File
        let landed: [File]
        let underlying: any Error

        var errorDescription: String? {
            guard !landed.isEmpty else { return underlying.localizedDescription }
            return "The change was saved only in part \u{2014} the virtual machine\u{2019}s configuration changed, "
                + "but Kernova\u{2019}s own settings for it did not: \(underlying.localizedDescription)"
        }
    }

    /// Why the library turned a settings write away.
    enum SettingsRefusal: LocalizedError {
        /// The new MAC address is one another VM holds; the refusal was
        /// presented as it was made.
        case macAddressInUse(VMMACAddressRegistry.MACAddressConflict)
        /// The removable-media list changed while the VM's live session is in
        /// a phase no reconcile can drive.
        case sessionNotAttachable
        /// The write reached no library: the instance was never wired to one,
        /// or the library that wired it is gone.
        case noLibrary

        var errorDescription: String? {
            switch self {
            case .macAddressInUse: "Another virtual machine holds that MAC address."
            case .sessionNotAttachable:
                "The virtual machine can\u{2019}t take a removable-media change in its current state."
            case .noLibrary: "No library is available to write this virtual machine\u{2019}s settings."
            }
        }
    }

    /// A refusal thrown out of a configuration commit, which leaves the file as
    /// it was.
    private struct Refused: Error {
        let refusal: SettingsRefusal
    }

    /// Thrown out of a commit when the caller's `mutate` threw, which leaves
    /// the file as it was; the caller's own error travels beside it.
    private struct MutateThrew: Error {}

    /// How a configuration commit ended, before the host-state half of an
    /// ``updateSettings(of:configuration:hostState:)`` runs.
    private enum ConfigurationCommit {
        /// Committed; `wrote` says whether the change moved what the file holds.
        case committed(wrote: Bool)
        /// Refused or not saved.
        case stopped(SettingsWrite)
    }

    /// Commits a mutation of `instance`'s configuration, then dispatches the
    /// live policy and removable-media reconcile for what moved.
    ///
    /// `mutate` applies to what `config.json` holds, not to memory, so a field
    /// another process changed since this one last read survives. Refused
    /// whole — no field it also sets is applied — when it moves the VM onto a
    /// MAC address another VM holds, in its configuration or in one of its
    /// snapshots; and when it changes `removableMedia` while the VM's live
    /// session is not attachable. A save that fails is presented, and memory
    /// stays equal to the file.
    ///
    /// `mutate` runs inside the coordinated write, so it must be pure.
    @discardableResult
    func updateConfiguration(
        of instance: VMInstance, mutate: (inout VMConfiguration) -> Void
    ) -> SettingsWrite {
        switch commitConfiguration(of: instance, mutate: mutate) {
        case .committed: .saved
        case .stopped(let write): write
        }
    }

    /// ``updateConfiguration(of:mutate:)``'s commit, answering whether the
    /// change moved the file; what `mutate` throws leaves the file as it was
    /// and is thrown on.
    private func commitConfiguration<Failure: Error>(
        of instance: VMInstance, mutate: (inout VMConfiguration) throws(Failure) -> Void
    ) throws(Failure) -> ConfigurationCommit {
        let bundle = instance.bundle
        let old = bundle.configuration
        var wrote = false
        var mutateFailure: Failure?
        do {
            try bundle.commitConfiguration(key: ConfigurationWriteKey()) { config in
                let onDisk = config
                do throws(Failure) {
                    try mutate(&config)
                } catch {
                    mutateFailure = error
                    throw MutateThrew()
                }
                guard config != onDisk else { return }
                if let conflict = macAddresses.macAddressConflict(
                    on: instance, movingFrom: onDisk, to: config)
                {
                    throw Refused(refusal: .macAddressInUse(conflict))
                }
                if removableMedia.refuseUnattachableEdit(on: instance, movingFrom: onDisk, to: config) {
                    throw Refused(refusal: .sessionNotAttachable)
                }
                wrote = true
            }
        } catch let refused as Refused {
            if case .macAddressInUse(let conflict) = refused.refusal {
                macAddresses.presentRefusal(conflict, on: instance)
            }
            return .stopped(.refused(refused.refusal))
        } catch {
            if let mutateFailure { throw mutateFailure }
            #log(
                Self.logger, .error,
                "Failed to save the configuration for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
            return .stopped(
                .notSaved(SettingsWriteFailure(failed: .configuration, landed: [], underlying: error)))
        }
        let new = bundle.configuration
        if new != old {
            applyLivePolicy(for: instance, old: old, new: new)
            // A live switch onto an app-managed network starts a guest worth
            // watching without starting a session.
            guestAddresses.watch()
        }
        return .committed(wrote: wrote)
    }

    /// Commits a change to `instance`'s configuration and one to its host
    /// state, each applied once to what its own file holds.
    ///
    /// The configuration commits first, on ``updateConfiguration(of:mutate:)``'s
    /// terms, and a refusal or failed save there leaves the host state
    /// unattempted. `configuration` may also refuse by throwing, judged on
    /// what `config.json` holds; the error is thrown on and nothing changed. A
    /// host-state save that fails reports, in its ``SettingsWriteFailure``,
    /// whether the configuration landed.
    ///
    /// Both changes run inside their coordinated writes, so they must be pure.
    @discardableResult
    func updateSettings<Failure: Error>(
        of instance: VMInstance,
        configuration: (inout VMConfiguration) throws(Failure) -> Void,
        hostState: (inout VMHostState) -> Void
    ) throws(Failure) -> SettingsWrite {
        switch try commitConfiguration(of: instance, mutate: configuration) {
        case .stopped(let write):
            return write
        case .committed(let wrote):
            return commitHostState(
                of: instance, landed: wrote ? [.configuration] : [], mutate: hostState)
        }
    }

    /// Commits a change to `instance`'s host state, applied to what
    /// `host-state.json` holds; a save that fails is presented, and memory
    /// stays equal to the file.
    ///
    /// `mutate` runs inside the coordinated write, so it must be pure.
    @discardableResult
    func updateHostState(
        of instance: VMInstance, mutate: (inout VMHostState) -> Void
    ) -> SettingsWrite {
        commitHostState(of: instance, landed: [], mutate: mutate)
    }

    /// The host-state commit both settings writes end in; `landed` is what the
    /// same write already committed, for the failure to report.
    private func commitHostState(
        of instance: VMInstance, landed: [SettingsWriteFailure.File],
        mutate: (inout VMHostState) -> Void
    ) -> SettingsWrite {
        do {
            try instance.bundle.commitHostState(mutate)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to save the host state for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            let failure = SettingsWriteFailure(failed: .hostState, landed: landed, underlying: error)
            presentError(failure)
            return .notSaved(failure)
        }
        return .saved
    }

    /// Points `instance`'s removable-media list at what its live session
    /// actually holds, after the session refused some of the list it was asked
    /// for.
    ///
    /// Commits that one field. It refuses nothing and dispatches nothing to
    /// the running VM, which the list already describes. A save that fails is
    /// presented and leaves the configuration as the bundle holds it; the live
    /// list stays in ``VMInstance/liveRemovableMedia``.
    func settleRemovableMedia(of instance: VMInstance, toLive media: [RemovableMediaItem]?) {
        let bundle = instance.bundle
        let old = bundle.configuration.removableMedia
        do {
            try bundle.commitConfiguration(key: ConfigurationWriteKey()) { $0.removableMedia = media }
        } catch {
            #log(
                Self.logger, .error,
                "Failed to settle the removable media config for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
            return
        }
        guard bundle.configuration.removableMedia != old else { return }
        #log(
            Self.logger, .notice,
            "Settled the removable media config for '\(instance.name, privacy: .public)' on its live state after a reconcile error"
        )
    }

    /// Commits the configuration a snapshot revert installs, ahead of the
    /// revert swapping the snapshot's files into `instance`'s bundle.
    ///
    /// The snapshot's configuration is applied to what `config.json` holds, so
    /// the VM keeps the name and identity its bundle carries now. No live
    /// policy runs — the revert has already ended the session it would apply
    /// to — and nothing is refused: the snapshot's saved state restores only
    /// under the MAC address it was taken with, which ``VMMACAddressRegistry``
    /// keeps for this VM while the snapshot is listed.
    func commitRevertedConfiguration(_ plan: VMSnapshotRestorePlan, on instance: VMInstance) throws {
        try instance.bundle.commitConfiguration(key: ConfigurationWriteKey()) {
            $0 = $0.adoptingSnapshotState(plan.configuration)
        }
    }

    /// The single entry point for any change to what a VM takes its USB
    /// accessories back from — the attach and detach verbs, the prompt's
    /// answer, and the settings row's remove button alike.
    ///
    /// Commits the mutation to the bundle's pairings file; a mutation that
    /// changes nothing writes nothing. Throws when the write fails, leaving the
    /// pairings as the bundle holds them.
    func updateUSBPairings(
        of instance: VMInstance,
        mutate: (inout USBAccessoryPairingSet) -> Void
    ) throws {
        do {
            try instance.bundle.commitUSBPairings(mutate)
        } catch {
            #log(
                Self.logger, .error,
                "Failed to save the USB accessory pairings for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    func pairUSBAccessory(_ pairing: USBAccessoryPairing, with instance: VMInstance) throws {
        for other in instances
        where other !== instance && other.usbPairings.pairing(forKey: pairing.key) != nil {
            try updateUSBPairings(of: other) { $0.remove(key: pairing.key) }
        }
        try updateUSBPairings(of: instance) { $0.upsert(pairing) }
    }

    /// Pushes a configuration change to a running VM.
    ///
    /// Hot-toggleable fields (`agentLogForwardingEnabled`, `clipboardSharingEnabled`)
    /// take effect immediately via `VMInstance.applyLivePolicy`; changes to
    /// `removableMedia` trigger a runtime XHCI list-diff; everything else is
    /// persisted-only and waits for next start.
    func applyLivePolicy(for instance: VMInstance, old: VMConfiguration, new: VMConfiguration) {
        instance.applyLivePolicy(oldConfig: old, newConfig: new)
        removableMedia.apply(for: instance, old: old, new: new)
    }

    // MARK: - Error Handling

    /// Error type for VM loading failures.
    enum LoadError: LocalizedError {
        case bundleLoadFailed(names: [String])

        var errorDescription: String? {
            switch self {
            case .bundleLoadFailed(let names):
                assert(!names.isEmpty, "bundleLoadFailed requires at least one bundle name")
                return
                    "Failed to load the following VMs: \(names.joined(separator: ", ")). They may have corrupted configurations."
            }
        }
    }

    func presentError(_ error: Error) {
        surfaceError(error.localizedDescription)
    }

    /// Hands an error message to ``onFailure``.
    func surfaceError(_ message: String, title: String = "Error") {
        onFailure?(title, message)
    }
}

extension VMLibrary {
    /// What ``VMBundle/commitConfiguration(key:_:)`` asks for, so only this
    /// file can write a VM's configuration past the refusals it owns: the
    /// initializer is `fileprivate`, which `@testable import` does not open.
    struct ConfigurationWriteKey {
        fileprivate init() {}
    }
}
