import Foundation
import KernovaKit
import KernovaLogging
import Virtualization

/// The AppKit adapter over ``VMCommanding``: the sheets and alerts that gather
/// consent for a verb, the routing of a refused verb to the right surface, and
/// the inline-rename editing state.
///
/// It runs no verb itself. Each method here does three things and stops: show
/// the sheet if one is owed, call the facade with explicit consent, and route
/// whatever ``CommandError`` comes back through ``present(_:for:)``.
///
/// Owns the library and the core, routes ``VMLibrary/onFailure`` and the core's
/// own failures to the presenter, and forwards the library's reads so a view
/// controller holding a view model still sees one surface.
@MainActor
@Observable
final class VMLibraryViewModel {
    nonisolated private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMLibraryViewModel")

    // MARK: - Services

    /// Which VMs exist, and everything that keeps that set in step with disk.
    let library: VMLibrary

    /// Every VM verb, headless. The one path from this adapter to a VM.
    let commands: any VMCommanding

    /// The same object ``commands`` is, kept concretely for the one hook the
    /// residency controller wires after construction.
    private let core: VMCommandCore

    let storageService: any VMStorageProviding
    let diskImageService: any DiskImageProviding
    let snapshotStore: any VMSnapshotStoring
    let lifecycle: VMLifecycleCoordinator

    /// Pauses running VMs for system sleep and resumes them on wake.
    ///
    /// Held rather than read: the sleep watcher it installs is what drives it,
    /// and this is the composition root that owns its lifetime.
    private let sleepWake: VMSleepWakeCoordinator

    /// Watches the USB accessories macOS assigns to Kernova; `nil` when this
    /// build cannot pass accessories through at all.
    ///
    /// Held rather than read, for the reason ``sleepWake`` is.
    private let usbAccessories: USBAccessoryCoordinator?

    /// The preferences store this library session reads and writes.
    let preferences: AppPreferences

    /// What this build's signature authorizes, as every surface that degrades
    /// without an entitlement reads it.
    let entitlements: EntitlementService

    // MARK: - Library Forwarding

    // Reads and library-level operations, forwarded verbatim so every existing
    // holder of a view model keeps working. Observation carries through the
    // computed accessors, which read the library's own stored properties.
    // Nothing here is a VM verb; each is documented on ``VMLibrary``.

    var instances: [VMInstance] {
        get { library.instances }
        set { library.instances = newValue }
    }

    var selectedID: UUID? {
        get { library.selectedID }
        set { library.selectedID = newValue }
    }

    var selectedInstance: VMInstance? { library.selectedInstance }

    var hasLoadedLibrary: Bool { library.hasLoadedLibrary }

    var hasUninterruptibleWork: Bool { library.hasUninterruptibleWork }

    var hasSaveInFlight: Bool { library.hasSaveInFlight }

    var hasRevertInFlight: Bool { library.hasRevertInFlight }

    func isBusy(_ instance: VMInstance) -> Bool { library.isBusy(instance) }

    func hasCloneInFlight(from instance: VMInstance) -> Bool {
        library.hasCloneInFlight(from: instance)
    }

    func startLibrary() async { await library.startLibrary() }

    func loadVMs() async { await library.loadVMs() }

    func reconcileWithDisk() { library.reconcileWithDisk() }

    func cancelAndCleanupPreparing() { library.cancelAndCleanupPreparing() }

    func moveVM(fromOffsets source: IndexSet, toOffset destination: Int) {
        library.moveVM(fromOffsets: source, toOffset: destination)
    }

    func waitForRevertsToSettle() async { await library.waitForRevertsToSettle() }

    func vmNamesSharingMACAddress(with instance: VMInstance) -> [String] {
        library.macAddresses.vmNamesSharingMACAddress(with: instance)
    }

    func guestAddress(for instance: VMInstance) -> GuestIPAddress {
        library.guestAddresses.address(for: instance)
    }

    @discardableResult
    func saveConfiguration(for instance: VMInstance) -> Bool {
        library.saveConfiguration(for: instance)
    }

    @discardableResult
    func updateConfiguration(
        of instance: VMInstance,
        ifNotSaved unsaved: VMLibrary.UnsavedSettings,
        mutate: (inout VMConfiguration) -> Void
    ) -> VMLibrary.SettingsWrite {
        library.updateConfiguration(of: instance, ifNotSaved: unsaved, mutate: mutate)
    }

    @discardableResult
    func updateSettings(
        of instance: VMInstance,
        ifNotSaved unsaved: VMLibrary.UnsavedSettings,
        mutate: (inout VMSettings) -> Void
    ) -> VMLibrary.SettingsWrite {
        library.updateSettings(of: instance, ifNotSaved: unsaved, mutate: mutate)
    }

    // MARK: - Command Forwarding

    // Headless reads and gates the UI enables its commands from, each
    // documented on ``VMCommanding``.
    //
    // A read that resolves its VM refuses only with
    // ``CommandError/notFound(_:)``, which a sheet still up while its VM left
    // the library is the one way to reach: there is nothing for a user to act
    // on, so it reads as empty and is logged.

    /// Every per-VM capability predicate the AppKit surfaces read.
    var capabilities: VMCapabilityCatalog { library.capabilities }

    /// Whether this build can pass a host USB accessory through to a guest —
    /// what decides whether the USB Device menu exists at all.
    var supportsUSBAccessories: Bool { library.supportsUSBAccessories }

    func canDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) -> Bool {
        capabilities.canDeleteSnapshot(snapshot, on: instance)
    }

    func snapshotOnDiskBytes(for instance: VMInstance) async -> [UUID: UInt64] {
        do {
            return try await commands.snapshotOnDiskBytes(of: .id(instance.id))
        } catch {
            #log(
                Self.logger, .debug,
                "No snapshot sizes for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    func externalAttachments(for instance: VMInstance) async -> [ExternalAttachment] {
        do {
            return try await commands.externalAttachments(of: .id(instance.id))
        } catch {
            #log(
                Self.logger, .debug,
                "No external attachments for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    func sharingVMNames(
        forPath path: String, bookmark: Data?, excluding instance: VMInstance
    ) async -> [String] {
        do {
            return try await commands.sharingVMNames(
                .id(instance.id), path: path, bookmark: bookmark)
        } catch {
            #log(
                Self.logger, .debug,
                "No sharing names for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return []
        }
    }

    // MARK: - Attachment Forwarding

    // The settings pane's Storage and Sharing categories, one forward per
    // verb, each documented on ``VMCommanding``. The pane gathers the consent
    // a trashing removal asks for, so the storage and removable-media removals
    // arrive pre-confirmed; a share removal destroys nothing and asks none.

    func attachStorageDisks(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) { try self.commands.attachStorageDisks(.id(instance.id), paths: files) }
    }

    func createStorageDisk(for instance: VMInstance, sizeInGB: Int) async {
        await run(on: instance) {
            try await self.commands.createStorageDisk(.id(instance.id), sizeInGB: sizeInGB)
        }
    }

    func removeStorageDisk(_ disk: UUID, from instance: VMInstance, trashFile: Bool) async {
        await runEdit(on: instance) {
            try await self.commands.removeStorageDisk(
                .id(instance.id), disk: disk, trashFile: trashFile, confirmed: true)
        }
    }

    func renameStorageDisk(_ disk: UUID, newLabel: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.renameStorageDisk(.id(instance.id), disk: disk, to: newLabel)
        }
    }

    func setStorageDiskNotes(_ disk: UUID, notes: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setStorageDiskNotes(.id(instance.id), disk: disk, notes: notes)
        }
    }

    func setStorageDiskReadOnly(_ disk: UUID, readOnly: Bool, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setStorageDiskReadOnly(
                .id(instance.id), disk: disk, readOnly: readOnly)
        }
    }

    func reorderStorageDisks(_ order: [UUID], on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.reorderStorageDisks(.id(instance.id), order: order)
        }
    }

    func attachRemovableMedia(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.attachRemovableMedia(.id(instance.id), paths: files)
        }
    }

    func createRemovableMedia(
        for instance: VMInstance, sizeInGB: Int, destinationURL: URL
    ) async {
        await run(on: instance) {
            try await self.commands.createRemovableMedia(
                .id(instance.id), sizeInGB: sizeInGB, destinationURL: destinationURL)
        }
    }

    func removeRemovableMedia(_ item: UUID, from instance: VMInstance, trashFile: Bool) async {
        await runEdit(on: instance) {
            try await self.commands.removeRemovableMedia(
                .id(instance.id), item: item, trashFile: trashFile, confirmed: true)
        }
    }

    func ejectRemovableMedia(_ item: UUID, from instance: VMInstance) {
        runEdit(on: instance) { try self.commands.ejectRemovableMedia(.id(instance.id), item: item) }
    }

    func renameRemovableMedia(_ item: UUID, newLabel: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.renameRemovableMedia(.id(instance.id), item: item, to: newLabel)
        }
    }

    func setRemovableMediaNotes(_ item: UUID, notes: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setRemovableMediaNotes(.id(instance.id), item: item, notes: notes)
        }
    }

    func setRemovableMediaReadOnly(_ item: UUID, readOnly: Bool, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setRemovableMediaReadOnly(
                .id(instance.id), item: item, readOnly: readOnly)
        }
    }

    /// Wires what turns a path an out-of-process client named into a URL this
    /// sandboxed process may read.
    ///
    /// Set rather than injected: the panel behind it has to bring the app
    /// forward, which only the residency controller can do.
    func attachSourceAuthority(_ authority: any SandboxSourceAuthorizing) {
        core.sourceAuthority = authority
    }

    func addSharedDirectories(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.addSharedDirectories(.id(instance.id), paths: files)
        }
    }

    func removeSharedDirectory(_ directory: UUID, from instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.removeSharedDirectory(.id(instance.id), directory: directory)
        }
    }

    func setSharedDirectoryReadOnly(_ directory: UUID, readOnly: Bool, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setSharedDirectoryReadOnly(
                .id(instance.id), directory: directory, readOnly: readOnly)
        }
    }

    /// Cancels a guest setup from the confirmation `GuestSetupProgressViewController`
    /// already gathered, so this always calls the facade pre-confirmed.
    func cancelGuestSetup(_ instance: VMInstance) {
        do {
            try commands.cancelGuestSetup(.id(instance.id), confirmed: true)
        } catch let error as CommandError {
            // Setup finishing between the button appearing and the click is a
            // normal race, not something to alert the user about.
            #log(
                Self.logger, .notice,
                "Nothing to cancel for '\(instance.name, privacy: .public)': \(error.message, privacy: .public)"
            )
        } catch {
            surfaceError(error.localizedDescription)
        }
    }

    // MARK: - State

    /// Whether the sidebar's guest-agent install nudge is turned off for every
    /// VM, overriding each VM's own `agentInstallNudgeDismissed` flag without
    /// touching it.
    ///
    /// The single write path for `AppPreferences.agentInstallPromptDisabled`,
    /// mirrored here because the sidebar and the VM Settings pane refresh from
    /// `withObservationTracking`, which a bare `UserDefaults` read never wakes.
    var agentInstallPromptDisabled: Bool {
        didSet {
            guard agentInstallPromptDisabled != oldValue else { return }
            #log(
                Self.logger, .notice,
                "Setting app-wide agent install prompt disabled=\(self.agentInstallPromptDisabled, privacy: .public)"
            )
            preferences.agentInstallPromptDisabled = agentInstallPromptDisabled
        }
    }

    /// Whether closing the last window (or a GUI-origin quit) leaves Kernova
    /// resident in the menu bar instead of quitting it.
    ///
    /// The single write path for `AppPreferences.keepInMenuBarOnQuit`, mirrored
    /// here because `AppDelegate` reconciles the status item and the activation
    /// policy from `withObservationTracking`, which a bare `UserDefaults` read
    /// never wakes.
    var keepInMenuBarOnQuit: Bool {
        didSet {
            guard keepInMenuBarOnQuit != oldValue else { return }
            #log(
                Self.logger, .notice,
                "Setting keep in menu bar=\(self.keepInMenuBarOnQuit, privacy: .public)"
            )
            preferences.keepInMenuBarOnQuit = keepInMenuBarOnQuit
        }
    }

    /// Presentation delegate for alerts, sheets, and the creation wizard.
    ///
    /// Presentations raised before a presenter is attached — the library read
    /// starts in `applicationWillFinishLaunching`, ahead of any window — are
    /// buffered and flushed when one is set.
    @ObservationIgnored weak var presenter: (any VMLibraryPresenting)? {
        didSet {
            guard presenter != nil else { return }
            drainBufferedPresentations()
            if let id = bufferedDisplayFocus {
                bufferedDisplayFocus = nil
                if let instance = instances.first(where: { $0.id == id }) {
                    presenter?.focusGuestDisplay(for: instance)
                }
            }
        }
    }

    /// A presentation raised with no presenter attached, held as what it is
    /// rather than as the text an alert would have shown: the drain re-runs the
    /// same branch the live call took, so a failure keeps the recovery it
    /// offered.
    private enum BufferedPresentation {
        case error(title: String, message: String)
        /// A start that failed, whatever it failed with. The VM is named by id
        /// and re-resolved on the drain — one that left the library meanwhile
        /// leaves nothing to act on or report.
        case startFailure(StartFailure, vmID: UUID)

        var isStartFailure: Bool {
            if case .startFailure = self { return true }
            return false
        }
    }

    /// How a bring-up failed: with an attachment the alert can offer to detach,
    /// or with only a message to show.
    ///
    /// The attachment case carries either bring-up, because both assemble the
    /// same configuration — a resume restoring a saved state fails over a
    /// missing disk exactly as a boot does. The message case is the start's:
    /// every start failure reaches the status item through it, a guest cap or
    /// a duplicate identity as surely as a missing disk image, and a headless
    /// launch has no other way to say so.
    private enum StartFailure {
        case attachment(StartFailedAttachment)
        case message(title: String, message: String)
    }

    /// What is waiting for a presenter, in the order it was raised.
    ///
    /// Observed — unlike `bufferedDisplayFocus` — because the status item
    /// renders ``bufferedStartFailureCount`` from it.
    private var bufferedPresentations: [BufferedPresentation] = []

    /// How many failed starts are waiting for a window to present them in.
    ///
    /// Non-zero only for a launch that came up headless: the status item is the
    /// one surface such a process has, and clicking its line opens the library,
    /// which attaches the presenter and drains these back to zero.
    var bufferedStartFailureCount: Int {
        bufferedPresentations.lazy.filter(\.isStartFailure).count
    }

    /// The VM an inline surface was asked for before any window existed, focused
    /// when the presenter attaches — the same buffering `bufferedPresentations`
    /// does, for the same reason.
    @ObservationIgnored private var bufferedDisplayFocus: UUID?

    var activeRename: RenameTarget?

    /// Asks for a VM's display window, for a verb that puts the display in
    /// front of the user.
    @ObservationIgnored var onOpenDisplayWindow: ((VMInstance) -> Void)?

    /// Reports that a VM is coming up, so its display can be readied.
    ///
    /// What that costs on screen is the delegate's decision, taken from the
    /// app's own posture — a bring-up is not a request to look at the guest.
    @ObservationIgnored var onReadyDisplay: ((VMInstance) -> Void)?

    /// Asks for the library window, for an inline surface with nowhere to land.
    ///
    /// The inline display lives inside the main window, so a verb surfacing one
    /// on a process that has never opened a window — an intent on the headless
    /// launch path — has to bring that window up first or do nothing at all.
    @ObservationIgnored var onSurfaceLibrary: (() -> Void)?

    /// Asks for the app to be taken down, for the quit verb an automation door
    /// carries. The app delegate answers it with the same full quit the status
    /// item's Quit performs.
    @ObservationIgnored var onRequestQuit: (() -> Void)?

    /// Asks for a VM's bundle to be selected in the Finder, for the verb that
    /// puts it there. The app delegate answers it with the Workspace call.
    @ObservationIgnored var onRevealInFinder: ((VMInstance) -> Void)?

    /// Measures the window or screen a starting VM's display will occupy, for
    /// `displaySizesToWindow`.
    @ObservationIgnored weak var displayBootGeometryProvider: (any DisplayBootGeometryProviding)?

    // MARK: - Initialization

    /// A collaborator over the user's own state — the VMs directory, the
    /// defaults domain, the Trash, the Downloads folder, the host's vmnet
    /// networks and their store, its ARP table, the signature's entitlements —
    /// takes no default: the test host
    /// runs as the app, in its container and with its signature, so a default
    /// would hand that state to every test that left it out. ``AppDelegate``
    /// supplies each.
    init(
        storageService: any VMStorageProviding,
        diskImageService: any DiskImageProviding = DiskImageService(),
        snapshotStore: any VMSnapshotStoring = VMSnapshotStore(),
        virtualizationService: any VirtualizationProviding,
        installService: any MacOSInstallProviding,
        ipswService: any IPSWProviding = IPSWService(),
        removableMediaDeviceService: any RemovableMediaAttaching = RemovableMediaDeviceService(),
        // Supplied by ``AppDelegate``, the one caller that should claim the
        // user's accessories — registering the listener is a side effect on
        // the whole process, and a default would hand it to every test that
        // builds a view model for something else entirely.
        usbAccessoryService: (any USBAccessoryProviding)? = nil,
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService(),
        downloadService: any Downloading = DownloadService(),
        fileSystem: any FileSystemOperating,
        downloadsDirectory: URL?,
        preferences: AppPreferences,
        vmnetNetworks: any VmnetNetworkProviding,
        arpTable: any ARPTableReading,
        entitlements: EntitlementService
    ) {
        self.storageService = storageService
        self.diskImageService = diskImageService
        self.snapshotStore = snapshotStore
        self.preferences = preferences
        self.entitlements = entitlements
        self.agentInstallPromptDisabled = preferences.agentInstallPromptDisabled
        self.keepInMenuBarOnQuit = preferences.keepInMenuBarOnQuit
        let lifecycle = VMLifecycleCoordinator(
            virtualizationService: virtualizationService,
            installService: installService,
            ipswService: ipswService,
            removableMediaDeviceService: removableMediaDeviceService,
            usbAccessoryService: usbAccessoryService,
            linuxImageResolveService: linuxImageResolveService,
            downloadService: downloadService,
            fileSystem: fileSystem,
            downloadsDirectory: downloadsDirectory
        )
        self.lifecycle = lifecycle
        let library = VMLibrary(
            storageService: storageService,
            snapshotStore: snapshotStore,
            lifecycle: lifecycle,
            fileSystem: fileSystem,
            preferences: preferences,
            vmnetNetworks: vmnetNetworks,
            arpTable: arpTable,
            entitlements: entitlements
        )
        self.library = library
        let sleepWake = VMSleepWakeCoordinator(lifecycle: lifecycle, roster: library)
        self.sleepWake = sleepWake
        let usbAccessories = USBAccessoryCoordinator(
            lifecycle: lifecycle, roster: library, pairings: library)
        self.usbAccessories = usbAccessories
        let core = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storageService,
            snapshotStore: snapshotStore,
            diskImageService: diskImageService,
            fileSystem: fileSystem,
            preferences: preferences
        )
        self.commands = core
        self.core = core

        library.onFailure = { [weak self] title, message in
            self?.surfaceError(message, title: title)
        }
        sleepWake.onFailure = { [weak self] error in
            self?.surfaceError(error.localizedDescription)
        }
        // The same routing a call site gets, so a failure nobody awaited still
        // reaches the sheet or the recovery alert its type asks for.
        core.onFailure = { [weak self] failure, instance in
            self?.present(failure, for: instance)
        }
        core.surfaceDisplay = { [weak self] instance in
            self?.surfaceDisplay(for: instance)
        }
        // Straight through: what a bring-up puts on screen is decided from the
        // app's own posture, which only the delegate can read.
        core.readyDisplay = { [weak self] instance in
            self?.onReadyDisplay?(instance)
        }
        core.revealInLibrary = { [weak self] instance in
            self?.revealInLibrary(instance)
        }
        core.revealInFinder = { [weak self] instance in
            self?.onRevealInFinder?(instance)
        }
        core.requestQuit = { [weak self] in
            self?.onRequestQuit?()
        }
        // Through this adapter rather than handed over, so the core retains
        // neither the view model nor the app delegate behind it.
        core.displayBootSurface = { [weak self] instance in
            self?.displayBootGeometryProvider?.displayBootSurface(for: instance)
        }
        // What the user's own attach and detach mean for what a guest takes
        // back on its own. Both hang off the verb rather than the surface, so
        // the menu, the CLI and the prompt's answer write the same rule.
        core.onUserAttachedAccessory = { [weak usbAccessories] instance, accessory in
            usbAccessories?.userAttached(accessory, to: instance)
        }
        core.onUserReleasedAccessory = { [weak usbAccessories] instance, accessory in
            usbAccessories?.userReleased(accessory, from: instance)
        }
        library.onSessionBecameAttachable = { [weak usbAccessories] instance in
            usbAccessories?.sessionBecameAttachable(instance)
        }
        usbAccessories?.onPairingNeeded = { [weak self] request in
            self?.presentUSBAccessoryPairing(request)
        }
    }

    // MARK: - USB Accessory Pairing

    /// Asks which guest a newly assigned accessory should go to, and runs the
    /// attach the answer stands for.
    ///
    /// The answer goes back through ``attachUSBAccessory(_:to:)`` rather than
    /// writing anything here: the pairing is created by the attach verb, on
    /// every surface, so the prompt has one less thing to keep in step.
    private func presentUSBAccessoryPairing(_ request: USBAccessoryPairingRequest) {
        guard let presenter else {
            #log(
                Self.logger, .notice,
                "Holding a USB accessory for the host: no surface is attached to ask which virtual machine should take it"
            )
            request.answer(nil)
            return
        }
        presenter.presentUSBAccessoryPairing(
            USBAccessoryPairingRequest(
                id: request.id, accessory: request.accessory, candidates: request.candidates,
                answer: { [weak self] instance in
                    request.answer(instance)
                    guard let instance else { return }
                    self?.attachUSBAccessory(request.accessory.registryID, to: instance)
                }))
    }

    /// Drops one remembered accessory from `instance`, so it stays with the Mac
    /// next time it is plugged in.
    ///
    /// Not through ``runEdit(on:_:)``: that logs an operation failure and says
    /// nothing, which is right for an attachment edit a live guest refused and
    /// wrong here. A write that did not reach the bundle takes the row off the
    /// list while the rule stays on disk, so the accessory goes back to this VM
    /// at the next launch — the user has to be told, or the list is lying.
    func forgetUSBAccessory(key: String, on instance: VMInstance) {
        do {
            try commands.forgetUSBPairing(.id(instance.id), key: key)
        } catch {
            present(error, for: instance)
        }
    }

    // MARK: - Create

    /// Registers the row a wizard's VM will fill and spawns the bundle write,
    /// optionally auto-starting the VM once it lands.
    ///
    /// The pre-write refusal is thrown rather than presented so the wizard host
    /// can show it on the wizard's own sheet and keep it open for a retry — two
    /// sheets on one window contend, and the sheet is still up at this point. A
    /// failure of the write itself arrives after the sheet is gone, and reaches
    /// the user through ``VMCommandCore/onFailure``.
    func createVM(from wizard: VMCreationViewModel) throws {
        try commands.create(
            configuration: wizard.buildConfiguration(),
            startAfterCreate: wizard.startAfterCreate,
            guestAccountPassword: wizard.guestAccountPasswordForCreate)
    }

    // MARK: - Lifecycle

    /// Puts the surface ``VMCapabilityCatalog/revealSurface(for:)`` names on
    /// screen, and adds the inline keyboard focus the library case owes.
    ///
    /// The library is asked for whether or not a window already exists: the
    /// inline display *is* part of the library window, so one buried behind
    /// another app, miniaturized, or never created has surfaced nothing — and
    /// `focusGuestDisplay` only moves the first responder, which nobody can see.
    private func surfaceDisplay(for instance: VMInstance) {
        switch capabilities.revealSurface(for: instance) {
        case .displayWindow:
            onOpenDisplayWindow?(instance)
        case .library:
            revealInLibrary(instance)
            focusInlineDisplay(for: instance)
        }
    }

    /// Selects the VM and puts the keyboard in its inline guest display — what
    /// an in-app bring-up gesture asks for beyond the verb itself.
    ///
    /// A pop-out or fullscreen VM is left alone: its window is opened by the
    /// bring-up's own readying, and a gesture in the library is not a request
    /// to be taken to another window.
    private func focusInlineDisplay(for instance: VMInstance) {
        guard instance.hostState.displayPreference == .inline else { return }
        selectedID = instance.id
        deliverInlineFocus(to: instance)
    }

    /// Moves the first responder into the selected VM's inline display, holding
    /// the ask until a window exists to move it in.
    private func deliverInlineFocus(to instance: VMInstance) {
        guard let presenter else {
            // No window has ever been created, so there is no inline display to
            // focus yet. The one just asked for focuses when it attaches.
            bufferedDisplayFocus = instance.id
            return
        }
        presenter.focusGuestDisplay(for: instance)
    }

    /// Selects the VM and asks for the library window — what a reveal lands on
    /// when there is no display to surface.
    private func revealInLibrary(_ instance: VMInstance) {
        selectedID = instance.id
        onSurfaceLibrary?()
    }

    /// The door every in-app start gesture funnels through: the verb, plus the
    /// look at the guest the gesture also asked for.
    ///
    /// Every caller is somebody in the library clicking Start — the toolbar,
    /// the menus, the sidebar's context menu, the display window's Resume — so
    /// the VM becomes the selected one and the keyboard lands in its display,
    /// ahead of the boot rather than at the end of it. A start arriving from
    /// anywhere else goes through ``VMCommanding`` and moves nothing.
    func start(_ instance: VMInstance, bootIntoRecovery: Bool = false) async {
        focusInlineDisplay(for: instance)
        await runGatheringGuestAccount(on: instance) {
            try await self.commands.start(.id(instance.id), recovery: bootIntoRecovery)
        }
    }

    /// Confirmed action of the start-failed alert: the removal it offered, then
    /// the Start the user was reaching for.
    ///
    /// A refused removal surfaces and ends it there: the click consented to the
    /// removal alone.
    ///
    /// Alerts are serialized, so this click can land long after the VM was
    /// deleted. Neither half runs then, and nothing is put on screen about it.
    func removeStartFailedAttachmentAndStart(
        _ failure: StartFailedAttachment, on instance: VMInstance
    ) async {
        guard instances.contains(where: { $0 === instance }) else {
            #log(
                Self.logger, .debug,
                "Start-failed recovery for '\(instance.name, privacy: .public)' arrived after it left the library"
            )
            return
        }
        do {
            try await commands.removeStartFailedAttachment(
                .id(instance.id), attachment: failure)
        } catch {
            present(error, for: instance)
            return
        }
        await start(instance)
    }

    /// What a user walking away from the account question raises, so the door
    /// that asked can tell it from a refusal worth an alert.
    private struct GuestAccountPromptDismissed: Error {}

    /// Runs a start through ``VMConsentPolicy/runGatheringGuestAccount(prompting:_:)``,
    /// raising the sheet for the account it refuses without.
    ///
    /// Asking is the door's job and deciding is the verb's: this presents the
    /// sheet and hands the answer to the verb that holds it, writing nothing
    /// itself. A VM with no account outstanding never sees the sheet, because the
    /// verb never refuses.
    ///
    /// A cancelled sheet ends the start with nothing on screen — the user just
    /// said no to it — while every other refusal takes the ordinary error
    /// surface, including the account refusal itself when no window exists to
    /// ask in.
    private func runGatheringGuestAccount(
        on instance: VMInstance, _ verb: () async throws -> Void
    ) async {
        do {
            try await VMConsentPolicy.runGatheringGuestAccount(
                prompting: { try await self.askForGuestAccount($0) }, verb)
        } catch is GuestAccountPromptDismissed {
            #log(
                Self.logger, .notice,
                "Start of '\(instance.name, privacy: .public)' cancelled at the account password"
            )
        } catch {
            present(error, for: instance)
        }
    }

    /// Puts the account question on screen and supplies the one answer it gives.
    ///
    /// - Throws: ``GuestAccountPromptDismissed`` when the user walked away, the
    ///   refusal itself when there is no presenter to ask through — a door with
    ///   nobody to ask says so by not answering — and whatever the verb that
    ///   takes the answer refuses with.
    private func askForGuestAccount(_ prompt: GuestAccountPrompt) async throws {
        guard let presenter else { throw CommandError.guestAccountPasswordRequired(prompt) }
        let answer = await withCheckedContinuation { continuation in
            presenter.presentGuestAccountPassword(
                GuestAccountPasswordRequest(
                    prompt: prompt, answer: { continuation.resume(returning: $0) }))
        }
        switch answer {
        case .password(let password):
            try commands.provideGuestAccountPassword(.id(prompt.vm.id), password: password)
        case .skip:
            try commands.skipGuestAccount(.id(prompt.vm.id))
        case .cancelled:
            throw GuestAccountPromptDismissed()
        }
    }

    func stop(_ instance: VMInstance) async {
        // Unconfirmed: a live-paused guest cannot take an ACPI shutdown, and
        // the core says so by refusing — which is what raises the sheet.
        await run(on: instance) {
            try await self.commands.stop(
                .id(instance.id), disposition: .graceful, confirmed: false)
        }
    }

    /// Resumes a paused VM then requests a graceful ACPI shutdown — the
    /// stop-paused sheet's default action.
    func resumeAndStop(_ instance: VMInstance) async {
        await run(on: instance) {
            try await self.commands.stop(
                .id(instance.id), disposition: .resumeThenShutDown, confirmed: true)
        }
    }

    func forceStop(_ instance: VMInstance) async {
        await run(on: instance) {
            try await self.commands.stop(.id(instance.id), disposition: .force, confirmed: true)
        }
    }

    /// Opens the Force Stop / Discard Saved State confirmation.
    func requestForceStop(_ instance: VMInstance) {
        presenter?.presentForceStop(for: instance)
    }

    /// Opens the confirmation for booting a stopped macOS guest into macOS
    /// Recovery.
    func requestStartInRecovery(_ instance: VMInstance) {
        presenter?.presentRecoveryBoot(for: instance)
    }

    func pause(_ instance: VMInstance) async {
        await run(on: instance) { try await self.commands.pause(.id(instance.id)) }
    }

    /// The resume half of the in-app door, surfacing what ``start(_:bootIntoRecovery:)``
    /// surfaces for the same reason.
    func resume(_ instance: VMInstance) async {
        focusInlineDisplay(for: instance)
        await run(on: instance) {
            try await self.commands.resume(.id(instance.id))
        }
    }

    func save(_ instance: VMInstance) async {
        await run(on: instance) { try await self.commands.suspend(.id(instance.id)) }
    }

    /// Saves VM state, throwing on failure (used by suspend-on-quit in AppDelegate).
    func trySave(_ instance: VMInstance) async throws {
        try await commands.suspend(.id(instance.id))
    }

    /// Force-stops a VM, throwing on failure (used by suspend-on-quit fallback in AppDelegate).
    func tryForceStop(_ instance: VMInstance) async throws {
        try await commands.stop(.id(instance.id), disposition: .force, confirmed: true)
    }

    // MARK: - Snapshots

    /// Opens the Take Snapshot sheet.
    func requestTakeSnapshot(_ instance: VMInstance) {
        guard capabilities.isAvailable(.takeSnapshot, on: instance) else { return }
        presenter?.presentTakeSnapshotSheet(for: instance)
    }

    /// Captures a snapshot from the Take Snapshot sheet's confirm.
    ///
    /// The returned Task lets tests await the capture.
    @discardableResult
    func takeSnapshot(_ instance: VMInstance, name: String, notes: String = "") -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.run(on: instance) {
                _ = try await self.commands.takeSnapshot(
                    .id(instance.id), name: name, notes: notes)
            }
        }
    }

    /// Opens the revert confirmation.
    func requestRevert(_ instance: VMInstance, to snapshot: VMSnapshot) {
        guard capabilities.isAvailable(.revertToSnapshot, on: instance) else { return }
        presenter?.presentRevertSnapshot(snapshot, for: instance)
    }

    /// Passes a host USB accessory through to `instance`'s guest.
    ///
    /// No confirmation: the user already consented to Kernova holding this
    /// accessory in Apple's *Virtual Machine Accessories* menu, and a detach is
    /// one action away.
    func attachUSBAccessory(_ registryID: UInt64, to instance: VMInstance) {
        guard capabilities.isAvailable(.editUSBAccessories, on: instance) else { return }
        Task {
            await run(on: instance) {
                try await self.commands.attachUSBAccessory(
                    .id(instance.id), accessory: registryID)
            }
        }
    }

    /// Takes a passed-through accessory back off `instance`'s guest.
    func detachUSBAccessory(deviceID: UUID, from instance: VMInstance) {
        guard capabilities.isAvailable(.editUSBAccessories, on: instance) else { return }
        Task {
            await run(on: instance) {
                try await self.commands.detachUSBAccessory(.id(instance.id), device: deviceID)
            }
        }
    }

    /// Reverts to `snapshot`, optionally check-pointing the current state
    /// first — the revert confirmation's two actions.
    func revert(
        _ instance: VMInstance, to snapshot: VMSnapshot, takingCheckpoint: Bool = false
    ) async {
        await run(on: instance) {
            try await self.commands.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id, takingCheckpoint: takingCheckpoint,
                confirmed: true)
        }
    }

    /// Opens the delete-snapshot confirmation.
    func requestDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) {
        guard canDeleteSnapshot(instance, snapshot: snapshot) else {
            #log(
                Self.logger, .notice,
                "Refusing to delete snapshot '\(snapshot.name, privacy: .public)': it is the Ephemeral baseline of '\(instance.name, privacy: .public)'"
            )
            return
        }
        presenter?.presentDeleteSnapshot(snapshot, for: instance)
    }

    /// Trashes a snapshot's captured files and drops it from the manifest.
    ///
    /// The returned Task lets tests await the trash.
    @discardableResult
    func deleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.run(on: instance) {
                try await self.commands.deleteSnapshot(
                    .id(instance.id), snapshot: snapshot.id, confirmed: true)
            }
        }
    }

    /// Renames a snapshot; an empty or unchanged name is a no-op.
    func renameSnapshot(_ snapshot: VMSnapshot, newName: String, on instance: VMInstance) {
        runSync(on: instance) {
            try self.commands.renameSnapshot(
                .id(instance.id), snapshot: snapshot.id, to: newName)
        }
    }

    /// Replaces a snapshot's note; an unchanged value is a no-op.
    func setSnapshotNotes(_ snapshot: VMSnapshot, notes: String, on instance: VMInstance) {
        runSync(on: instance) {
            try self.commands.setSnapshotNotes(
                .id(instance.id), snapshot: snapshot.id, notes: notes)
        }
    }

    // MARK: - Delete

    /// Opens the delete-VM sheet.
    ///
    /// `permanently` selects the destructive variant: `false` (the default) moves
    /// the bundle and the chosen externals to Trash, `true` deletes them
    /// immediately, bypassing it.
    func requestDelete(_ instance: VMInstance, permanently: Bool = false) {
        presenter?.presentDeleteSheet(for: instance, permanently: permanently)
    }

    /// Deletes the VM bundle and the chosen external files, either to the
    /// Trash or immediately (bypassing it).
    func delete(
        _ instance: VMInstance, deletingExternalIDs: Set<UUID> = [], permanently: Bool = false
    ) async {
        do {
            try await commands.delete(
                .id(instance.id), permanently: permanently, alsoRemoving: deletingExternalIDs,
                confirmed: true)
        } catch let error as CommandError {
            // A second sheet for a VM the first already removed, or one whose
            // state moved while the sheet was up: refused rather than run, and
            // there is nothing to tell the user about a delete they can retry.
            switch error {
            case .notFound, .invalidState, .busy:
                #log(
                    Self.logger, .notice,
                    "Refusing delete of '\(instance.name, privacy: .public)': \(error.message, privacy: .public)"
                )
            default:
                present(error, for: instance)
            }
        } catch {
            surfaceError(error.localizedDescription)
        }
    }

    // MARK: - Import

    /// Filters `urls` to `.kernova` bundles and imports the batch.
    ///
    /// Each bundle's destination is reserved and its phantom row registered synchronously (see
    /// ``VMCommandCore/importVM(from:)``), so two overlapping triggers never collide on a
    /// destination name and never wait behind each other's copies.
    ///
    /// Returns whether any bundle was accepted for import — `true` means at least one
    /// bundle was reserved, not that every import will succeed.
    @discardableResult
    func importVMs(fromDroppedURLs urls: [URL]) -> Bool {
        let bundles = urls.filter { VMStorageService.isBundleURL($0) }
        guard !bundles.isEmpty else { return false }
        #log(Self.logger, .notice, "Importing \(bundles.count, privacy: .public) bundle(s)")
        for url in bundles {
            runSync(on: nil) { _ = try self.commands.importVM(from: url) }
        }
        return true
    }

    #if DEBUG
    /// Test-only seam awaiting every in-flight preparing (create/clone/import) task.
    func awaitPreparingForTesting() async {
        for task in instances.compactMap({ $0.preparingState?.task }) {
            await task.value
        }
    }
    #endif

    // MARK: - Show in Finder

    /// Selects the VM's bundle in the Finder.
    func showVMInFinder(_ instance: VMInstance) {
        runSync(on: instance) { try self.commands.showInFinder(.id(instance.id)) }
    }

    // MARK: - Clone

    /// The Option-alternate Clone: performs the opposite of the
    /// `cloneGeneratesNewMachineID` preference for this one clone.
    func cloneVMWithOppositeMachineIdentity(_ instance: VMInstance) {
        cloneVM(instance, generateNewMachineID: !preferences.cloneGeneratesNewMachineID)
    }

    /// Clones `instance`. `generateNewMachineID: nil` follows the
    /// `cloneGeneratesNewMachineID` preference; the Option-alternate menu items
    /// pass the opposite explicitly via `cloneVMWithOppositeMachineIdentity`.
    func cloneVM(_ instance: VMInstance, generateNewMachineID: Bool? = nil) {
        let identity: CloneMachineIdentity
        switch generateNewMachineID {
        case .none: identity = .followPreference
        case .some(true): identity = .new
        case .some(false): identity = .keep
        }
        do {
            _ = try commands.clone(.id(instance.id), machineIdentity: identity)
        } catch let error as CommandError {
            if case .invalidState = error {
                #log(
                    Self.logger, .debug,
                    "Clone skipped for '\(instance.name, privacy: .public)': status '\(instance.status.displayName, privacy: .public)' does not allow editing"
                )
            } else {
                present(error, for: instance)
            }
        } catch {
            surfaceError(error.localizedDescription)
        }
    }

    // MARK: - Cancel Preparing

    /// Opens the cancel-create/clone/import confirmation.
    func requestCancelPreparing(_ instance: VMInstance) {
        presenter?.presentCancelPreparing(for: instance)
    }

    /// Cancels an in-flight create, clone or import from that confirmation's confirm.
    func cancelPreparing(_ instance: VMInstance) {
        do {
            try commands.cancelPreparing(.id(instance.id), confirmed: true)
        } catch let error as CommandError {
            // The row went while the confirmation was up — a settled copy is
            // cleaned up rather than refused, so what reaches here is a VM that
            // is no longer in the library, or one that is no longer at rest.
            #log(
                Self.logger, .notice,
                "Nothing to cancel for '\(instance.name, privacy: .public)': \(error.message, privacy: .public)"
            )
        } catch {
            surfaceError(error.localizedDescription)
        }
    }

    // MARK: - Rename

    enum RenameTarget: Equatable {
        case sidebar(UUID)
        case detail(UUID)
    }

    /// One of the two inline-rename surfaces, without the instance baked in.
    ///
    /// Commit/cancel call sites pass the surface and the instance separately so an
    /// instance/target id mismatch is unrepresentable.
    enum RenameSurface {
        case sidebar
        case detail

        fileprivate func target(for instance: VMInstance) -> RenameTarget {
            switch self {
            case .sidebar: .sidebar(instance.id)
            case .detail: .detail(instance.id)
            }
        }
    }

    func renameVMInSidebar(_ instance: VMInstance) {
        #log(Self.logger, .debug, "Starting sidebar rename for '\(instance.name, privacy: .public)'")
        activeRename = .sidebar(instance.id)
    }

    func renameVMInDetail(_ instance: VMInstance) {
        #log(Self.logger, .debug, "Starting detail rename for '\(instance.name, privacy: .public)'")
        activeRename = .detail(instance.id)
    }

    /// Commits the rename text from one of the two rename surfaces.
    ///
    /// The marker is only cleared while it still belongs to `surface`'s rename of
    /// `instance`: a commit can fire from a field editor resigning *because* a rename
    /// just started on the other surface (its `makeFirstResponder` synchronously ends
    /// the pending session), and clearing unconditionally would wipe the newer
    /// rename's marker before its UI ever opened.
    func commitRename(for instance: VMInstance, newName: String, from surface: RenameSurface) {
        do {
            try commands.rename(.id(instance.id), to: newName)
        } catch let error as CommandError where error.isOperationFailure {
            // The configuration funnel already told the user the write failed;
            // the verb throws so a wire client hears about it, and a second
            // alert saying the same thing is not what the user needs.
            #log(
                Self.logger, .error,
                "Rename of '\(instance.name, privacy: .public)' did not persist: \(error.message, privacy: .public)"
            )
        } catch {
            present(error, for: instance)
        }
        clearRename(ifOwnedBy: surface.target(for: instance))
    }

    /// Cancels the rename that `surface` has open on `instance`, leaving a rename
    /// that has since moved to the other surface untouched.
    func cancelRename(for instance: VMInstance, from surface: RenameSurface) {
        clearRename(ifOwnedBy: surface.target(for: instance))
    }

    private func clearRename(ifOwnedBy target: RenameTarget) {
        if activeRename == target {
            activeRename = nil
        }
    }

    // MARK: - Clipboard Policy

    /// Carries an app-wide clipboard paste-ceiling change to every running VM.
    ///
    /// The ceiling lives in `AppPreferences`, so it produces no `VMConfiguration`
    /// diff for `applyLivePolicy` to carry. Two things need it: the guest, which
    /// enforces host→guest pastes against its own copy, and any passthrough
    /// session holding an offer the old ceiling refused. Instances with neither
    /// no-op.
    func applyClipboardPasteLimitChange() {
        for instance in instances {
            instance.resendAgentPolicy()
            instance.republishPassthroughIfCeilingRaised()
        }
    }

    // MARK: - Guest Agent Installer

    /// Mounts the bundled `KernovaMacOSAgent.dmg` so the user can run
    /// `install.command` inside the guest, then shows the next-step alert.
    ///
    /// The alert is the whole action on two of the verb's three paths — an
    /// image already mounted, and a guest that takes it on virtio for the whole
    /// session — so every outcome presents it.
    func mountGuestAgentInstaller(
        on instance: VMInstance, purpose: GuestAgentInstallerPurpose = .install
    ) {
        runEdit(on: instance) {
            let outcome = try self.commands.mountGuestAgentDisk(.id(instance.id))
            self.presenter?.presentInstallerMounted(
                vmName: instance.name, purpose: purpose, delivery: outcome.delivery)
        }
    }

    /// Removes the bundled guest agent installer entry from `removableMedia` if
    /// currently present. The reconcile flow performs the runtime detach.
    func unmountGuestAgentInstaller(from instance: VMInstance) {
        runEdit(on: instance) { try self.commands.unmountGuestAgentDisk(.id(instance.id)) }
    }

    /// Marks this VM's `.waiting` install nudge as dismissed and persists the choice.
    ///
    /// `.outdated`, `.unresponsive`, and `.expectedMissing` still surface — those imply
    /// something more urgent than "you could install this".
    func dismissAgentInstallNudge(for instance: VMInstance) {
        setAgentInstallNudgeDismissed(true, for: instance)
    }

    /// Sets whether this VM's agent-install nudge is dismissed and persists the
    /// choice.
    ///
    /// The single path a user's choice for the per-VM
    /// `agentInstallNudgeDismissed` flag takes: `true` silences the `.waiting`
    /// nudge, `false` re-arms it.
    func setAgentInstallNudgeDismissed(_ dismissed: Bool, for instance: VMInstance) {
        guard instance.hostState.agentInstallNudgeDismissed != dismissed else { return }
        #log(
            Self.logger, .notice,
            "Setting install-agent nudge dismissed=\(dismissed, privacy: .public) for '\(instance.name, privacy: .public)'"
        )
        updateSettings(of: instance, ifNotSaved: .discard) {
            $0.hostState.agentInstallNudgeDismissed = dismissed
        }
    }

    /// Re-arms the agent-install nudge everywhere: clears the app-wide
    /// suppression *and* every VM's dismissed flag, so each VM's `.waiting`
    /// nudge can surface again.
    ///
    /// Each VM's flag lives in its own bundle and is persisted individually;
    /// VMs already armed no-op.
    func resetAllAgentInstallNudges() {
        agentInstallPromptDisabled = false
        for instance in instances {
            setAgentInstallNudgeDismissed(false, for: instance)
        }
    }

    // MARK: - Launch Auto-Start

    /// Names of the macOS VMs marked to start automatically, in library order —
    /// which is the order ``startAutomaticVMsForLaunch()`` reaches them in.
    ///
    /// Feeds the Startup section's capacity warning: macOS caps how many macOS
    /// guests run at once, so a longer list than that cap cannot come up whole.
    var macOSVMNamesMarkedForAutoStart: [String] {
        instances
            .filter {
                $0.configuration.guestOS == .macOS
                    && $0.hostState.startsAutomaticallyOnLaunch
            }
            .map(\.name)
    }

    /// Starts every VM marked to start automatically, one after another.
    ///
    /// Sequential: each guest commits its whole memory allocation at start, and
    /// the duplicate machine-ID and MAC refusals inside the start and resume
    /// verbs compare against VMs that are already live, so they only answer
    /// deterministically once the previous VM has settled.
    ///
    /// Per-VM failures are logged and surfaced by those two methods; the pass
    /// carries on to the next VM either way.
    ///
    /// Cancelling stops it between VMs — a start already inside VZ is left to
    /// finish, since abandoning one mid-flight is worse than completing it.
    ///
    /// Nobody is at the machine for this, so it selects and focuses nothing: it
    /// goes through the verbs rather than the in-app door, and the library is
    /// left showing whatever the user left it on.
    func startAutomaticVMsForLaunch() async {
        let marked = instances.filter { $0.hostState.startsAutomaticallyOnLaunch }
        guard !marked.isEmpty else {
            #log(Self.logger, .debug, "Launch auto-start: no VMs are marked to start automatically")
            return
        }

        #log(Self.logger, .notice, "Launch auto-start: \(marked.count, privacy: .public) VM(s) marked")

        var startedCount = 0
        var skippedCount = 0
        var failedCount = 0
        for instance in marked {
            // A quit cancels the pass; anything left is the terminating app's
            // business, not this one's.
            if Task.isCancelled {
                #log(Self.logger, .notice, "Launch auto-start cancelled — the app is terminating")
                break
            }
            // A boot takes long enough for the user to delete or evict a later
            // VM meanwhile, and `marked` still holds that instance. Starting it
            // would open a display window over a bundle no longer in the library.
            guard instances.contains(where: { $0 === instance }) else {
                #log(
                    Self.logger, .debug,
                    "Launch auto-start: '\(instance.name, privacy: .public)' left the library before its turn"
                )
                skippedCount += 1
                continue
            }
            // Re-read at the moment of acting rather than trusting the snapshot:
            // the user can start a VM by hand while this pass runs, and the
            // previous iteration's boot is what can make the next one a
            // duplicate-identity conflict. The marking is this pass's own
            // criterion; what the VM's state admits is the catalog's.
            guard instance.hostState.startsAutomaticallyOnLaunch,
                let step = capabilities.standingBringUp(for: instance)
            else {
                if capabilities.owesGuestAccountAnswer(instance) {
                    // A login launch has no window to ask in and leaves no
                    // other trace, so this is the only place the user can find
                    // out why a VM they marked did not come up.
                    #log(
                        Self.logger, .notice,
                        "Launch auto-start: '\(instance.name, privacy: .public)' was not started — it creates a macOS account on its first boot and the password for it is only ever held in memory. Start it by hand to enter the password, or to skip setting up the account"
                    )
                } else {
                    #log(
                        Self.logger, .debug,
                        "Launch auto-start: skipped '\(instance.name, privacy: .public)' (\(instance.status.displayName, privacy: .public))"
                    )
                }
                skippedCount += 1
                continue
            }
            // Through the verbs rather than the in-app door: a failure still
            // buffers for the status item, and nothing is selected or focused.
            //
            // Reported rather than merely presented, because a bring-up that
            // leaves the VM resting back on its saved state moves no field
            // ``VMCommandCore/events()`` diffs into a failure — the same reason
            // a transient one does not. Nobody is at the machine for this pass,
            // so a client reading the stream is the one surface that can say a
            // marked VM did not come up.
            do {
                switch step {
                case .start: try await commands.start(.id(instance.id), recovery: false)
                case .resume: try await commands.resume(.id(instance.id))
                }
            } catch {
                let verb: VMVerb = step == .resume ? .resume : .start
                core.reportUnattendedFailure(
                    error as? CommandError
                        ?? .operationFailed(verb: verb, message: error.localizedDescription),
                    on: instance)
            }
            if instance.isActive {
                startedCount += 1
            } else {
                failedCount += 1
            }
        }

        #log(
            Self.logger, .notice,
            "Launch auto-start finished — \(startedCount, privacy: .public) running, \(failedCount, privacy: .public) failed, \(skippedCount, privacy: .public) skipped"
        )
    }

    // MARK: - Error Handling

    /// Runs one verb, routing whatever it refuses with to the right surface.
    private func run(on instance: VMInstance?, _ verb: () async throws -> Void) async {
        do {
            try await verb()
        } catch {
            present(error, for: instance)
        }
    }

    /// The synchronous counterpart of ``run(on:_:)``.
    private func runSync(on instance: VMInstance?, _ verb: () throws -> Void) {
        do {
            try verb()
        } catch {
            present(error, for: instance)
        }
    }

    /// Runs one attachment edit, routing refusals as ``runSync(on:_:)`` does
    /// but logging the failure a race raises instead of alerting on it.
    ///
    /// Two things reach here as
    /// ``CommandError/operationFailed(verb:title:message:recovery:)``: an edit
    /// naming an attachment the list no longer carries — a rename field
    /// committing after its row went, a second alert for a disk the first
    /// already removed — and a configuration write the funnel has already told
    /// the user about. Both were silent before there was a verb to refuse them,
    /// and the verb throws so a wire client hears about it.
    private func runEdit(on instance: VMInstance, _ verb: () throws -> Void) {
        do {
            try verb()
        } catch let error as CommandError where error.isOperationFailure {
            #log(
                Self.logger, .debug,
                "Attachment edit on '\(instance.name, privacy: .public)' did not apply: \(error.message, privacy: .public)"
            )
        } catch {
            present(error, for: instance)
        }
    }

    /// The asynchronous counterpart of ``runEdit(on:_:)``.
    private func runEdit(on instance: VMInstance, _ verb: () async throws -> Void) async {
        do {
            try await verb()
        } catch let error as CommandError where error.isOperationFailure {
            #log(
                Self.logger, .debug,
                "Attachment edit on '\(instance.name, privacy: .public)' did not apply: \(error.message, privacy: .public)"
            )
        } catch {
            present(error, for: instance)
        }
    }

    /// Shows a refusal nobody is waiting for.
    ///
    /// A `kernova:` link has no caller to answer to, so the app is where its
    /// refusal lands — through the same routing every in-app refusal takes,
    /// buffering included, so a refusal raised while the window it will be
    /// shown in is still being built survives to reach it.
    func surfaceUnawaitedFailure(_ failure: CommandError) {
        present(failure, for: nil)
    }

    /// The single place a ``CommandError`` becomes something on screen.
    ///
    /// A consent refusal opens the sheet that gathers it; a failure carrying a
    /// recovery opens the alert that offers it; everything else is an error
    /// alert headed by the refusal's own title.
    private func present(_ error: Error, for instance: VMInstance?) {
        guard let command = error as? CommandError else {
            surfaceError(error.localizedDescription)
            return
        }
        switch command {
        case .confirmationRequired(let prompt):
            presentConfirmation(prompt, for: instance)
        case .operationFailed(let verb, _, let message, let recovery):
            if case .removeStartFailedAttachment(let failure) = recovery, let instance {
                surfaceStartFailure(.attachment(failure), for: instance)
            } else if verb == .start, let instance {
                surfaceStartFailure(
                    .message(title: command.alertTitle, message: message), for: instance)
            } else {
                surfaceError(message, title: command.alertTitle)
            }
        default:
            surfaceError(command.message, title: command.alertTitle)
        }
    }

    /// Opens the sheet that gathers the consent a refusal is asking for.
    ///
    /// Two refusals reach here, both raised by a Stop the user asked for that
    /// only the core can tell is destructive: a live-paused guest that cannot
    /// receive the request, and a cold-paused Ephemeral VM whose stop discards
    /// its suspended session. Every other confirmation is raised by the
    /// `request…` method that opens its own sheet and knows the arguments —
    /// which VM, which snapshot, Trash or immediate — that the prompt alone
    /// does not carry.
    private func presentConfirmation(_ prompt: ConfirmationPrompt, for instance: VMInstance?) {
        guard let instance else { return }
        switch prompt.kind {
        case .stopPaused:
            presenter?.presentStopPaused(for: instance)
        case .forceStop:
            presenter?.presentForceStop(for: instance)
        default:
            #log(
                Self.logger, .debug,
                "No sheet to raise for an unconsented \(prompt.kind.rawValue, privacy: .public)"
            )
        }
    }

    /// Routes an error message to the presenter, buffering it if none is
    /// attached yet.
    private func surfaceError(_ message: String, title: String = "Error") {
        if let presenter {
            presenter.presentError(message, title: title)
        } else {
            bufferedPresentations.append(.error(title: title, message: message))
        }
    }

    /// Routes a start failure to the presenter, buffering the failure itself
    /// when none is attached yet — a headless launch's auto-start pass runs
    /// with no window, and the alert it earns is the one carrying whatever the
    /// failure offered, the detach-and-start-again action included.
    private func surfaceStartFailure(_ failure: StartFailure, for instance: VMInstance) {
        guard let presenter else {
            bufferedPresentations.append(.startFailure(failure, vmID: instance.id))
            return
        }
        switch failure {
        case .attachment(let attachment):
            presenter.presentStartFailedAttachment(attachment, for: instance)
        case .message(let title, let message):
            presenter.presentError(message, title: title)
        }
    }

    /// Re-dispatches everything raised before the presenter attached, through
    /// the same routing a live presentation takes.
    private func drainBufferedPresentations() {
        guard !bufferedPresentations.isEmpty else { return }
        let buffered = bufferedPresentations
        bufferedPresentations.removeAll()
        for presentation in buffered {
            switch presentation {
            case .error(let title, let message):
                surfaceError(message, title: title)
            case .startFailure(let failure, let vmID):
                guard let instance = instances.first(where: { $0.id == vmID }) else {
                    #log(
                        Self.logger, .debug,
                        "Dropped a buffered start failure — its VM left the library before a window arrived"
                    )
                    continue
                }
                surfaceStartFailure(failure, for: instance)
            }
        }
    }
}
