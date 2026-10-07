import Foundation
import KernovaKit
import KernovaLogging

/// The set of VMs the app knows about, the arrivals becoming ones, and the
/// bookkeeping that keeps them in step with the bundles on disk: membership
/// and manual ordering, the one ``adopt(_:)`` every bundle enters the library
/// through, the policy every write of a VM's settings and pairings passes on
/// its way to that VM's ``VMBundle``. The library read, the directory-watched
/// reconcile and the arrival pipeline live in `VMLibrary+Membership.swift`.
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
final class VMLibrary: VMInstanceRoster, USBAccessoryPairingWriting, VMAdmissionPeers {
    nonisolated static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMLibrary")

    // MARK: - Services

    let storageService: any VMStorageProviding
    /// What every VM's bundle is built by, over ``configurationPolicy``.
    let bundleFactory: VMBundle.Factory
    /// What every configuration commit to one of this library's bundles
    /// answers to.
    let configurationPolicy: VMLibraryConfigurationPolicy
    let lifecycle: VMLifecycleCoordinator

    /// Where each VM's answer for the account it owes its guest is held — the
    /// half of that account no bundle carries. Keyed by identifier, so a
    /// create's answer is held for its arrival and stays with the VM it becomes.
    private let guestAccountPasswords: any GuestAccountPasswordStoring

    let preferences: AppPreferences

    /// What this build's signature authorizes, as every surface that degrades
    /// without an entitlement reads it.
    let entitlements: EntitlementService

    /// The named networks VMs join together.
    let networks: VMNetworkDirectory

    /// The host interfaces a network naming one is titled from.
    @ObservationIgnored private let bridgedInterfaces: any BridgedInterfaceProviding
    /// The library's smart groups, folders and tags.
    let organization: VMOrganizationDirectory

    // MARK: - Collaborators

    /// Drives a running VM's XHCI removable-media list to what its
    /// configuration asks for, dispatched from
    /// ``VMLibraryConfigurationPolicy/committed(on:from:to:)``.
    @ObservationIgnored let removableMedia: VMRemovableMediaReconciler

    /// The uniqueness of each VM's MAC address across the library.
    @ObservationIgnored let macAddresses: VMMACAddressRegistry

    /// Which identity another live VM already claims, for the refusal every
    /// bring-up passes.
    @ObservationIgnored let liveIdentities: VMLiveIdentities

    /// The address each running VM's guest is seen using on its network.
    @ObservationIgnored let guestAddresses: GuestAddressObserver

    /// Which VM holds each USB accessory passed through to a guest.
    @ObservationIgnored let accessoryHolders = VMAccessoryHolders()

    // MARK: - Adapter Hooks

    /// Receives every failure the library needs a user to see.
    ///
    /// The library presents nothing itself; the adapter routes these to its
    /// presenter, buffering them until one is attached.
    @ObservationIgnored var onFailure: ((_ title: String, _ message: String) -> Void)?

    /// Fires when a VM's guest agent handshakes a current version, for the
    /// installer auto-eject.
    @ObservationIgnored var onAgentBecameCurrent: ((VMInstance) -> Void)?

    /// Fires when a VM powers off, answering the follow-ups the power-off
    /// owes — the Ephemeral Mode baseline revert.
    @ObservationIgnored var onPoweredOff: ((VMInstance) -> [VMFollowUp])?

    /// Fires when an arrival settles as no VM, in the same main-actor step as
    /// — and just before — its row leaves the library, so anything the hook
    /// emits precedes every observer of the removal.
    @ObservationIgnored var onArrivalFailed: ((VMArrival, any Error) -> Void)?

    /// Fires when a VM reaches a state a device can be attached to, answering
    /// the attaches of the accessories paired with it.
    @ObservationIgnored var onSessionBecameAttachable: ((VMInstance) -> [VMFollowUp])?

    /// Fires when a read of the library finds a config file it cannot read
    /// that no earlier read reported — the cue to put the config check in
    /// front of the user.
    @ObservationIgnored var onUnreadableFilesFound: (() -> Void)?

    // MARK: - Capabilities

    /// Every per-VM capability predicate, derived from this library — what a
    /// verb's own guard asks and what each surface enables its controls from.
    var capabilities: VMCapabilityCatalog { VMCapabilityCatalog(library: self) }

    // MARK: - State

    /// Every row of the library in manual order, each identifier at most
    /// once: the VMs, and the arrivals becoming ones.
    ///
    /// Written only in this file, where ``adopt(_:)`` is the one path a `.vm`
    /// entry enters by.
    private(set) var entries: [LibraryEntry] = []

    /// The VMs, in manual order.
    var instances: [VMInstance] { entries.compactMap(\.vm) }

    /// The creates, clones and imports still writing their bundles.
    var arrivals: [VMArrival] { entries.compactMap(\.arrival) }

    #if DEBUG
    /// Adds the VM `read` describes to the library as it stands, unwired — a
    /// test's stand-in for a VM a load would have adopted, its bundle built by
    /// ``bundleFactory`` as every VM's is.
    @discardableResult
    func admitForTesting(
        _ read: VMBundleRead, phase: VMLifecyclePhase, preferences: AppPreferences
    ) -> VMInstance {
        let instance = VMInstance(
            bundle: bundleFactory.make(read), phase: phase, preferences: preferences)
        entries.append(.vm(instance))
        return instance
    }
    #endif

    /// Whether the library's first read from disk has finished.
    ///
    /// `false` until then, so UI can tell "no VMs" from "not read yet" — an empty
    /// `entries` means nothing before the first `loadVMs()` applies. Stays
    /// `true` across later reloads, and is set even when the read fails: the
    /// answer is then known to be empty.
    var hasLoadedLibrary = false

    /// The selected sidebar row, whose entry is ``selectedID``.
    ///
    /// The sidebar writes the row the user picks. Everything else selects
    /// through ``selectRevealing(_:)``, which first makes the entry listed.
    var selection: SidebarRowKey? {
        didSet {
            if selectedLibraryEntryID != retainedEntryID {
                retainedEntryID = selectedLibraryEntryID.flatMap { sidebarNarrowingAdmits($0) ? $0 : nil }
            }
            if pendingReveal != selection { pendingReveal = nil }
            if selection != oldValue { preferences.sidebarSelection = selection }
        }
    }

    /// The entry selected in the library section that the section keeps
    /// listing once a change to its own values — a status, a network, its
    /// name — stops the filter or the search admitting it, as Mail keeps a
    /// selected message the filter no longer matches.
    ///
    /// Follows the selection onto any library row the filter and the search
    /// admit, so it lapses as soon as the selection moves off the row — into a
    /// smart group included; a filter or search edit drops it before it
    /// re-applies, so an edit still hides the VM and clears the selection.
    private(set) var retainedEntryID: UUID?

    /// The selected entry when its row is in the library section, the one
    /// section that retains.
    private var selectedLibraryEntryID: UUID? {
        selection?.section == .library ? selection?.entryID : nil
    }

    /// The selected row, while the sidebar still owes it a reveal: opening
    /// the collapsed sections that hide it.
    ///
    /// Set by ``selectRevealing(_:)`` and an arrival's registration, and held
    /// until the sidebar takes it (``takePendingReveal()``) — however long
    /// before the sidebar exists that is. Any other selection drops it, so a
    /// reveal never outlives the selection it was made for, and a restored or
    /// clicked selection opens nothing.
    private(set) var pendingReveal: SidebarRowKey?

    /// The row owed a reveal, which is then no longer owed.
    func takePendingReveal() -> SidebarRowKey? {
        defer { pendingReveal = nil }
        return pendingReveal
    }

    private func sidebarNarrowingAdmits(_ id: UUID) -> Bool {
        guard let entry = entries.first(where: { $0.id == id }) else { return false }
        return sidebarSearch.admits(entry.name)
            && (sidebarContext.subject(of: entry).map(sidebarOptions.filter.admits) ?? true)
    }

    /// The selected entry's identifier.
    ///
    /// Setting a different entry selects its library row; setting the entry
    /// already selected leaves the row it is selected in. Set only here, so
    /// nothing outside the library selects an entry the sidebar hides.
    private(set) var selectedID: UUID? {
        get { selection?.entryID }
        set {
            guard newValue != selection?.entryID else { return }
            selection = newValue.map(SidebarRowKey.library)
        }
    }

    /// How the sidebar narrows, orders and groups the library, read from
    /// ``AppPreferences/sidebarViewOptions`` at init and written back on every
    /// change — whether or not a library window is open.
    ///
    /// Beside ``selection`` because every rule that moves the selection reads
    /// what the sidebar shows: a filter edit that hides the selected VM clears
    /// the selection, and a sort, grouping or details edit keeps it.
    var sidebarOptions: SidebarViewOptions {
        didSet {
            guard sidebarOptions != oldValue else { return }
            preferences.sidebarViewOptions = sidebarOptions
            guard sidebarOptions.filter != oldValue.filter else {
                reconcileSelection()
                return
            }
            renarrow()
        }
    }

    /// What the sidebar's search field narrows every sidebar section to.
    ///
    /// Held beside ``sidebarOptions`` rather than in it, so nothing that
    /// reads or keeps the options — a saved smart group, Clear Filters — takes
    /// the search along. An edit moves the selection as a filter edit does.
    var sidebarSearch = SidebarNameSearch() {
        didSet {
            guard sidebarSearch != oldValue else { return }
            renarrow()
        }
    }

    /// Re-applies a changed filter or search: the retained entry drops first,
    /// so the change hides it like any other, and the selection then left in
    /// the library section is the one retained.
    private func renarrow() {
        retainedEntryID = nil
        reconcileSelection()
        retainedEntryID = selectedLibraryEntryID
    }

    /// Fills the search with `term` and selects the VM it most likely names,
    /// by ``SidebarNameSearch/bestMatch(in:name:)`` over the library's order —
    /// what a search from outside the app shows.
    func showSearchResults(for term: String) {
        sidebarSearch = SidebarNameSearch(text: term)
        if let best = sidebarSearch.bestMatch(in: entries, name: \.name) {
            selectRevealing(best.id)
        }
    }

    /// Makes `edit` to ``sidebarOptions``, leaving the other options as they
    /// stand.
    func editSidebarOptions(_ edit: SidebarViewOptions.Edit) {
        sidebarOptions = sidebarOptions.applying(edit)
    }

    /// Drops `section` from ``AppPreferences/collapsedSidebarSections``, for a
    /// smart group or folder deleted: no section will list it again.
    func forgetCollapsed(_ section: SidebarSectionID) {
        preferences.collapsedSidebarSections.removeAll { $0 == section.rawValue }
    }

    /// The rows the sidebar shows for the library as it stands.
    ///
    /// Reads every value ``sidebarOptions`` filters, orders or groups by, so
    /// an observation computing it tracks exactly those.
    var sidebarLayout: SidebarLayout {
        .project(
            entries: entries, options: sidebarOptions, search: sidebarSearch, retaining: retainedEntryID,
            organization: organization.state.map(\.sections), context: sidebarContext)
    }

    /// Moves the section `id` identifies — a smart group, a folder or the
    /// library — to just before the one `successor` identifies, or after every
    /// other when `successor` is `nil`.
    func moveSection(_ id: SidebarSectionID, before successor: SidebarSectionID?) throws {
        try organization.moveSection(id, before: successor)
    }

    /// What the sidebar's projection, its filter menu and every ``VMInfo``
    /// read besides the entries.
    ///
    /// Each context enumerates the host's interfaces at most once, and only
    /// when a VM's network names one: a pass titles every bridged VM from one
    /// enumeration, and the next pass sees the host as it is then.
    var sidebarContext: SidebarLayout.Context {
        let named = networks.state
        let entitlements = entitlements
        let interfaces = HostInterfaceEnumeration(provider: bridgedInterfaces)
        return SidebarLayout.Context(
            bundledAgentVersion: KernovaMacOSAgentInfo.bundledVersion, networks: named,
            tags: organization.tags ?? [],
            networkTitle: { config in
                NetworkModeChoice.title(
                    of: config, entitlements: entitlements, interfaces: interfaces.interfaces,
                    networks: named)
            })
    }

    /// Moves ``selection`` onto what `layout` — by default the current
    /// ``sidebarLayout`` — shows, by ``SidebarLayout/reconciled(_:libraryHolds:)``.
    func reconcileSelection(with layout: SidebarLayout? = nil) {
        let layout = layout ?? sidebarLayout
        let reconciled = layout.reconciled(selection) { id in entries.contains { $0.id == id } }
        if reconciled != selection { selection = reconciled }
    }

    /// Selects the entry `id`, first dropping each sidebar filter attribute
    /// that hides it, and the search when it does — what every reveal, and
    /// every selection made other than by clicking a row, lands on.
    ///
    /// A VM the sidebar already lists — a retained one included — relaxes
    /// nothing.
    func selectRevealing(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if !sidebarShows(id) {
            if let subject = sidebarContext.subject(of: entry) {
                sidebarOptions.filter = sidebarOptions.filter.admitting(subject)
            }
            if !sidebarSearch.admits(entry.name) { sidebarSearch = SidebarNameSearch() }
        }
        selectedID = id
        pendingReveal = selection
    }

    /// Selects what a library read lands on when nothing listed is selected:
    /// the last-selected row as ``SidebarLayout/resolve(_:)`` finds it, else
    /// the first row. Restoring is no reveal, so it opens no collapsed
    /// section.
    func restoreSelection() {
        guard selectedID == nil || !entries.contains(where: { $0.id == selectedID }) else { return }
        if let saved = preferences.sidebarSelection, let row = sidebarLayout.resolve(saved) {
            selection = row
            #log(Self.logger, .debug, "Restored the last-selected sidebar row for \(row.entryID.uuidString)")
        } else {
            selection = firstShownRow
        }
    }

    /// Whether the sidebar lists the entry `id`.
    func sidebarShows(_ id: UUID) -> Bool {
        sidebarLayout.resolve(.library(id)) != nil
    }

    /// The first row the sidebar lists.
    var firstShownRow: SidebarRowKey? { sidebarLayout.rowKeys.first }

    /// The selected row, whichever kind it is.
    var selectedEntry: LibraryEntry? {
        entries.first { $0.id == selectedID }
    }

    /// The selected row when it is a VM.
    var selectedInstance: VMInstance? { selectedEntry?.vm }

    /// Whether anything is doing work that terminating would destroy rather
    /// than suspend — a bundle still being created, cloned or imported, or a
    /// VM held by an operation that shows a status of its own: a start,
    /// restore, install, save, capture or revert.
    ///
    /// Excludes settled `.running` and `.paused` VMs, which termination
    /// save-suspends, and operations that present the phase they started from.
    var hasUninterruptibleWork: Bool {
        !arrivals.isEmpty
            || instances.contains {
                guard let operation = $0.phase.operation else { return false }
                return operation.kind.declaration.status != .base
            }
    }

    /// Whether a quit has to wait before the process may exit: a VM held by an
    /// operation whose kind declares ``VMOperationDeclaration/Quit/waitOut``,
    /// or an arrival publishing or withdrawing its bundle.
    ///
    /// Narrower than ``hasUninterruptibleWork``, which the window reconcile uses
    /// to hold back a quit nobody asked for.
    var quitMustWaitOut: Bool {
        arrivals.contains { $0.stage == .publishing || $0.stage == .withdrawing }
            || instances.contains { $0.phase.operation?.kind.declaration.quit == .waitOut }
    }

    /// Whether the app's termination has begun — from then on, admission
    /// refuses every operation the termination did not ask for.
    ///
    /// Never cleared: a termination always ends the process.
    private(set) var isTerminating = false

    /// Begins the app's termination.
    func beginTermination() {
        isTerminating = true
    }

    /// Whether this build can pass a host USB accessory through to a guest at
    /// all — the OS and the signature together, answered once by
    /// ``USBAccessorySupport/makeService(entitlements:)``.
    var supportsUSBAccessories: Bool { lifecycle.usbAccessoryService != nil }

    /// The VM claiming the identity (``VMInstance/claimsIdentity``) that
    /// bringing `instance` up under `configuration` would duplicate, unless
    /// `override` waives it.
    func identityConflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration,
        override: VMIdentityOverride
    ) -> VMIdentityConflict? {
        liveIdentities.conflict(for: instance, bringingUp: configuration, override: override)
    }

    var customOrder: [UUID] = []

    /// The unreadable config files already reported through
    /// ``onUnreadableFilesFound``, so a file that stays unreadable does not
    /// open the check again at every read.
    var unreadableReports = UnreadableFileReports()

    /// Whether a read recorded a newly unreadable file that
    /// ``reportNewlyUnreadable()`` has not yet reported.
    var owesUnreadableReport = false

    /// Bundle names already reported as holding an identifier the library
    /// knows at another bundle, so a bundle that stays a duplicate is not
    /// reported at every `reconcileWithDisk()`.
    var reportedDuplicateBundles: Set<String> = []

    // MARK: - Directory Watcher

    var directoryWatcher: VMDirectoryWatcher?

    /// Where the directory watcher observes app activation.
    let activationCenter: NotificationCenter

    // MARK: - Initialization

    init(
        storageService: any VMStorageProviding,
        machineFiles: any VMBundleMachineFileWorking,
        lifecycle: VMLifecycleCoordinator,
        preferences: AppPreferences,
        vmnetNetworks: any VmnetNetworkProviding,
        arpTable: any ARPTableReading,
        entitlements: EntitlementService,
        networks: VMNetworkDirectory,
        organization: VMOrganizationDirectory,
        guestAccountPasswords: any GuestAccountPasswordStoring =
            InMemoryGuestAccountPasswordStore(),
        bridgedInterfaces: any BridgedInterfaceProviding = HostBridgedInterfaceProvider(),
        activationCenter: NotificationCenter = .default
    ) {
        self.storageService = storageService
        self.bridgedInterfaces = bridgedInterfaces
        self.activationCenter = activationCenter
        self.networks = networks
        self.organization = organization
        self.guestAccountPasswords = guestAccountPasswords
        self.lifecycle = lifecycle
        self.preferences = preferences
        self.entitlements = entitlements
        self.sidebarOptions = preferences.sidebarViewOptions
        self.removableMedia = VMRemovableMediaReconciler(lifecycle: lifecycle)
        let guestAddresses = GuestAddressObserver(
            reader: arpTable, vmnetNetworks: vmnetNetworks, entitlements: entitlements)
        self.guestAddresses = guestAddresses
        let macAddresses = VMMACAddressRegistry()
        self.macAddresses = macAddresses
        self.liveIdentities = VMLiveIdentities(macAddresses: macAddresses, preferences: preferences)
        let configurationPolicy = VMLibraryConfigurationPolicy(
            macAddresses: macAddresses, removableMedia: removableMedia,
            guestAddresses: guestAddresses)
        self.configurationPolicy = configurationPolicy
        self.bundleFactory = VMBundle.Factory(
            machineFiles: machineFiles, configurationPolicy: configurationPolicy)

        // Assigned after every stored property is set: each closure — and the
        // roster — references the library, which cannot be named before then.
        removableMedia.onSettle = { [weak self] permit, media in
            self?.settleRemovableMedia(permit, toLive: media)
        }
        removableMedia.onFailure = { [weak self] error in
            self?.presentError(error)
        }
        macAddresses.roster = self
        liveIdentities.roster = self
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
        /// and left out. `existing` is `nil` when the holder is no VM.
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
        case .unreadable(let holder):
            return reportDuplicate(at: url, holderName: holder.name, existing: nil)
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
            instance.rebind(to: bundleFactory.make(scanned.read))
            recordUnreadable(of: scanned.read)
            return .rebound(instance)
        }
    }

    /// Makes `bundles` the library's unreadable rows, answering whether any
    /// row changed.
    ///
    /// Each bundle joins, or replaces its own row when what the read found
    /// changed; a row whose bundle is not among `bundles` leaves — read and
    /// adopted as its VM since, or gone from disk — handing its selection to
    /// the VM its bundle became.
    @discardableResult
    func admitUnreadable(_ bundles: [UnreadableBundle]) -> Bool {
        var changed = false
        for bundle in bundles {
            let id = UnreadableVM.id(for: bundle.url)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                entries.append(.unreadable(UnreadableVM(bundle)))
                changed = true
                continue
            }
            guard let row = entries[index].unreadable,
                row.file != bundle.file || row.bundleURL != bundle.url
            else { continue }
            entries[index] = .unreadable(UnreadableVM(bundle))
            changed = true
        }
        let kept = Set(bundles.map { UnreadableVM.id(for: $0.url) })
        for row in entries.compactMap(\.unreadable) where !kept.contains(row.id) {
            entries.removeAll { $0.id == row.id }
            changed = true
            guard selectedID == row.id else { continue }
            selectedID =
                instances.first { isSameBundle($0.bundleURL, row.bundleURL) }?.id ?? entries.first?.id
        }
        return changed
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
            bundle: bundleFactory.make(scanned.read), phase: scanned.phase, preferences: preferences)
        wireHooks(for: instance)
        recordUnreadable(of: scanned.read)
        return instance
    }

    /// Records the files `read` left in place for the check
    /// (``recordUnreadable(_:under:)``).
    private func recordUnreadable(of read: VMBundleRead) {
        for unreadable in read.unreadableFiles {
            #log(
                Self.logger, .error,
                "'\(read.configuration.name, privacy: .public)' left \(unreadable.fileName, privacy: .public) in place: \(String(describing: unreadable.problems), privacy: .public)"
            )
        }
        recordUnreadable(read.unreadableFiles, under: read.files.url)
    }

    // MARK: - Arrival Rows

    /// Adds `arrival`'s row and selects it.
    ///
    /// Selection moves only when no other arrival holds it, so a second arrival
    /// registering mid-operation can't steal the sidebar's focus from the one the
    /// user is already watching, and only when the sidebar shows the arrival,
    /// so a filter hiding it leaves the selection where the user can see it.
    func register(_ arrival: VMArrival) {
        entries.append(.arriving(arrival))
        sortEntries()
        persistOrder()
        if selectedEntry?.arrival == nil, sidebarShows(arrival.id) {
            selectedID = arrival.id
            pendingReveal = selection
        }
    }

    /// Removes `arrival`'s row — matched by the object, since adoption may
    /// already have replaced it with the VM of the same identifier, which then
    /// stays.
    ///
    /// Only an arrival that became no VM leaves here, so the account answer
    /// held for it, and any folder it was dropped into, go with it.
    func removeArrival(_ arrival: VMArrival) {
        guard let index = entries.firstIndex(where: { $0.arrival === arrival }) else { return }
        entries.remove(at: index)
        persistOrder()
        leaveEveryFolder(arrival.id)
        reconcileSelection()
        guestAccountPasswords.remove(for: arrival.id)
    }

    /// Drops `instance` from the library and its folders, moving the
    /// selection off it onto the first row the sidebar shows.
    func evict(_ instance: VMInstance) {
        entries.removeAll { $0.vm === instance }
        leaveEveryFolder(instance.id)
        reconcileSelection()
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

    /// Sorts rows by custom order, falling back to `createdAt` for unordered
    /// ones, and to the end for an unordered row with no creation date.
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
                return (lhs.configuration?.createdAt ?? .distantFuture)
                    < (rhs.configuration?.createdAt ?? .distantFuture)
            }
        }
    }

    /// Snapshots the current row order into customOrder and persists it via `AppPreferences.vmOrder`.
    func persistOrder() {
        customOrder = entries.map(\.id)
        preferences.vmOrder = customOrder
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
    /// The intent is written first, under `permit`, and the password dropped
    /// only once it landed, so a write that is refused or not saved leaves both
    /// halves as they were — and the caller, whose operation this retraction
    /// is a step of, reports the outcome.
    func retractGuestAccount(_ permit: borrowing VMEditPermit) -> SettingsWrite {
        let instance = permit.instance
        let outcome = updateConfiguration(permit) { $0.pendingGuestAccount = nil }
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
        instance.onUpdateConfiguration = { [weak self] permit, mutate in
            guard let self else { return .refused(.noLibrary) }
            return self.updateConfiguration(permit, mutate: mutate)
        }
        instance.onUpdateSettings = { [weak self] permit, configuration, hostState in
            guard let self else { return .refused(.noLibrary) }
            return self.updateSettings(permit, configuration: configuration, hostState: hostState)
        }
        instance.peers = self
        // Auto-eject the installer disk once the agent handshakes a current version.
        // Wired here so it fires regardless of which window is open.
        instance.onAgentBecameCurrent = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.onAgentBecameCurrent?(instance)
        }
        // An Ephemeral Mode VM goes back to its baseline on every power-off.
        instance.activity.onPoweredOff = { [weak self, weak instance] in
            guard let self, let instance else { return [] }
            return self.onPoweredOff?(instance) ?? []
        }
        // A guest that has just become attachable takes back the accessories
        // paired with it, and is a running guest whose address can be watched.
        instance.activity.onSessionBecameAttachable = { [weak self, weak instance] in
            guard let self, let instance else { return [] }
            self.guestAddresses.watch()
            return self.onSessionBecameAttachable?(instance) ?? []
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
        /// The change puts the VM on a MAC address another VM holds, or — for
        /// a running VM — onto the network another active VM uses it on.
        case macAddressInUse(VMMACAddressRegistry.MACAddressConflict)
        /// The write reached no library: the instance was never wired to one,
        /// or the library that wired it is gone.
        case noLibrary
        /// The change moved fields its permit may not write.
        case outsidePermit(VMStateFieldRefusal)
        /// Another copy of Kernova holds the VM's bundle.
        case heldByAnotherCopy

        var errorDescription: String? {
            switch self {
            case .macAddressInUse: "Another virtual machine holds that MAC address."
            case .noLibrary: "No library is available to write this virtual machine\u{2019}s settings."
            case .outsidePermit:
                "The virtual machine\u{2019}s current state doesn\u{2019}t allow this change."
            case .heldByAnotherCopy:
                "The virtual machine is in use by another copy of Kernova."
            }
        }
    }

    /// Thrown out of a commit when the caller's `mutate` threw, which leaves
    /// the file as it was; the caller's own error travels beside it.
    private struct MutateThrew: Error {}

    /// How a configuration commit ended, before the host-state half of an
    /// ``updateSettings(_:configuration:hostState:)`` runs.
    private enum ConfigurationCommit {
        /// Committed; `wrote` says whether the change moved what the file holds.
        case committed(wrote: Bool)
        /// Refused or not saved.
        case stopped(SettingsWrite)
    }

    /// Commits a mutation of the configuration of the VM `permit` writes
    /// through ``VMBundle/StateFiles/commitConfiguration(_:)``, answering its
    /// refusal or failure as a ``SettingsWrite``.
    ///
    /// `mutate` applies to what `config.json` holds, not to memory, so a field
    /// another process changed since this one last read survives. A refusal
    /// changes nothing and is the caller's to render. A save that fails
    /// is presented, and memory stays equal to the file.
    ///
    /// `mutate` runs inside the coordinated write, so it must be pure. It may
    /// refuse by throwing, judged on what `config.json` holds; the error is
    /// thrown on and nothing changed.
    @discardableResult
    func updateConfiguration<Failure: Error>(
        _ permit: borrowing VMEditPermit, mutate: (inout VMConfiguration) throws(Failure) -> Void
    ) throws(Failure) -> SettingsWrite {
        switch try commitConfiguration(permit, mutate: mutate) {
        case .committed: .saved
        case .stopped(let write): write
        }
    }

    /// Commits a mutation of the configuration as a write of the operation
    /// `context` holds the VM for, then drives a `removableMedia` change into
    /// that operation's live session before answering — the reconcile a
    /// settled live VM launches, run inside the operation.
    func updateConfiguration(
        in context: borrowing VMOperationContext, mutate: (inout VMConfiguration) -> Void
    ) async -> SettingsWrite {
        let old = context.instance.bundle.configuration
        if case .stopped(let write) = commitConfiguration(context.permit, mutate: mutate) {
            return write
        }
        if VMConfiguration.removableMediaChanged(old: old, new: context.instance.bundle.configuration) {
            await removableMedia.reconcile(context)
        }
        return .saved
    }

    /// ``updateConfiguration(_:mutate:)``'s commit, answering whether the
    /// change moved the file; what `mutate` throws leaves the file as it was
    /// and is thrown on.
    private func commitConfiguration<Failure: Error>(
        _ permit: borrowing VMEditPermit,
        mutate: (inout VMConfiguration) throws(Failure) -> Void
    ) throws(Failure) -> ConfigurationCommit {
        let instance = permit.instance
        var wrote = false
        var mutateFailure: Failure?
        do {
            try permit.bundle.commitConfiguration { config in
                let onDisk = config
                do throws(Failure) {
                    try mutate(&config)
                } catch {
                    mutateFailure = error
                    throw MutateThrew()
                }
                wrote = config != onDisk
            }
        } catch let refusal as SettingsRefusal {
            return .stopped(.refused(refusal))
        } catch let refused as VMStateFieldRefusal {
            return .stopped(.refused(outsidePermit(refused, on: instance)))
        } catch let refused as VMAdmissionRefusal where refused.refusal == .heldByAnotherCopy {
            return .stopped(.refused(.heldByAnotherCopy))
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
        return .committed(wrote: wrote)
    }

    /// `refused` as the refusal a settings write answers, logged: a write that
    /// moves a field its permit may not write is a caller's mistake.
    private func outsidePermit(
        _ refused: VMStateFieldRefusal, on instance: VMInstance
    ) -> SettingsRefusal {
        #log(
            Self.logger, .error,
            "Refused a write to '\(instance.name, privacy: .public)' that moved \(refused.fields.joined(separator: ", "), privacy: .public) outside its permit"
        )
        return .outsidePermit(refused)
    }

    /// Commits a change to the configuration of the VM `permit` writes and one
    /// to its host state, each applied once to what its own file holds.
    ///
    /// The configuration commits first, on ``updateConfiguration(_:mutate:)``'s
    /// terms, and a refusal or failed save there leaves the host state
    /// unattempted. `configuration` may also refuse by throwing, judged on
    /// what `config.json` holds; the error is thrown on and nothing changed. A
    /// host-state save that fails reports, in its ``SettingsWriteFailure``,
    /// whether the configuration landed.
    ///
    /// Both changes run inside their coordinated writes, so they must be pure.
    @discardableResult
    func updateSettings<Failure: Error>(
        _ permit: borrowing VMEditPermit,
        configuration: (inout VMConfiguration) throws(Failure) -> Void,
        hostState: (inout VMHostState) -> Void
    ) throws(Failure) -> SettingsWrite {
        switch try commitConfiguration(permit, mutate: configuration) {
        case .stopped(let write):
            return write
        case .committed(let wrote):
            return commitHostState(permit, landed: wrote ? [.configuration] : [], mutate: hostState)
        }
    }

    /// Commits a change to the host state of the VM `permit` writes, applied
    /// to what `host-state.json` holds; a save that fails is presented, and
    /// memory stays equal to the file.
    ///
    /// `mutate` runs inside the coordinated write, so it must be pure.
    @discardableResult
    func updateHostState(
        _ permit: borrowing VMEditPermit, mutate: (inout VMHostState) -> Void
    ) -> SettingsWrite {
        commitHostState(permit, landed: [], mutate: mutate)
    }

    /// The host-state commit both settings writes end in; `landed` is what the
    /// same write already committed, for the failure to report.
    private func commitHostState(
        _ permit: borrowing VMEditPermit, landed: [SettingsWriteFailure.File],
        mutate: (inout VMHostState) -> Void
    ) -> SettingsWrite {
        let instance = permit.instance
        do {
            try permit.bundle.commitHostState(mutate)
        } catch let refused as VMStateFieldRefusal {
            return .refused(outsidePermit(refused, on: instance))
        } catch let refused as VMAdmissionRefusal where refused.refusal == .heldByAnotherCopy {
            return .refused(.heldByAnotherCopy)
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

    /// Points the removable-media list of the VM `permit` writes at what its
    /// live session actually holds, after the session refused some of the
    /// list it was asked for.
    ///
    /// Commits that one field, as a write of the operation the reconcile runs
    /// in: the running VM already holds the list, and the reconcile that
    /// operation runs is the one that drove it there. A save that fails is
    /// presented and leaves the configuration as the bundle holds it; the live
    /// list stays in ``VMInstance/liveRemovableMedia``.
    func settleRemovableMedia(
        _ permit: borrowing VMEditPermit, toLive media: [RemovableMediaItem]?
    ) {
        let instance = permit.instance
        let old = instance.bundle.configuration.removableMedia
        do {
            try permit.bundle.commitConfiguration { $0.removableMedia = media }
        } catch {
            #log(
                Self.logger, .error,
                "Failed to settle the removable media config for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            presentError(error)
            return
        }
        guard instance.bundle.configuration.removableMedia != old else { return }
        #log(
            Self.logger, .notice,
            "Settled the removable media config for '\(instance.name, privacy: .public)' on its live state after a reconcile error"
        )
    }

    /// Commits the configuration a snapshot revert installs, as a write of the
    /// revert `permit` belongs to, ahead of the revert swapping the snapshot's
    /// files into the bundle.
    ///
    /// The snapshot's configuration is applied to what `config.json` holds, so
    /// the VM keeps the name and identity its bundle carries now.
    func commitRevertedConfiguration(
        _ plan: VMSnapshotRestorePlan, _ permit: borrowing VMEditPermit
    ) throws {
        try permit.bundle.commitConfiguration {
            $0 = $0.adoptingSnapshotState(plan.configuration)
        }
    }

    /// The single entry point for any change to what a VM takes its USB
    /// accessories back from — the attach and detach verbs, the prompt's
    /// answer, and the settings row's remove button alike.
    ///
    /// Commits the mutation to the pairings file of the VM `permit` writes; a
    /// mutation that changes nothing writes nothing. Throws when the write
    /// fails, leaving the pairings as the bundle holds them.
    func updateUSBPairings(
        _ permit: borrowing VMEditPermit,
        mutate: (inout USBAccessoryPairingSet) -> Void
    ) throws {
        let instance = permit.instance
        do {
            try permit.bundle.commitUSBPairings(mutate)
        } catch let refused as VMAdmissionRefusal {
            throw refused
        } catch {
            #log(
                Self.logger, .error,
                "Failed to save the USB accessory pairings for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Pairs `pairing` with the VM `permit` writes, moving it off every other
    /// VM that holds it first, each under a ``VMEditClasses/pairingRules``
    /// edit of its own; throws ``PairingMoveRefused`` when one of those VMs'
    /// state refuses the edit, leaving the target unpaired.
    func pairUSBAccessory(_ pairing: USBAccessoryPairing, _ permit: borrowing VMEditPermit) throws {
        for other in instances
        where other !== permit.instance && other.usbPairings.pairing(forKey: pairing.key) != nil {
            do {
                try other.activity.edit(.pairingRules) { otherPermit in
                    try updateUSBPairings(otherPermit) { $0.remove(key: pairing.key) }
                }
            } catch let refused as VMAdmissionRefusal {
                throw PairingMoveRefused(holder: other, refusal: refused)
            }
        }
        try updateUSBPairings(permit) { $0.upsert(pairing) }
    }

    /// A pairing move refused by the state of the VM that held the pairing.
    struct PairingMoveRefused: Error {
        let holder: VMInstance
        let refusal: VMAdmissionRefusal
    }

    // MARK: - Error Handling

    func presentError(_ error: Error) {
        surfaceError(error.localizedDescription)
    }

    /// Hands an error message to ``onFailure``.
    func surfaceError(_ message: String, title: String = "Error") {
        onFailure?(title, message)
    }
}

/// The host's bridgeable interfaces, enumerated on first ask and kept for
/// the one projection pass that asked.
@MainActor
private final class HostInterfaceEnumeration {
    private let provider: any BridgedInterfaceProviding
    private var enumerated: [BridgedInterface]?

    init(provider: any BridgedInterfaceProviding) {
        self.provider = provider
    }

    func interfaces() -> [BridgedInterface] {
        if let enumerated { return enumerated }
        let interfaces = provider.interfaces()
        enumerated = interfaces
        return interfaces
    }
}
