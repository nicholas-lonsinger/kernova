import Foundation
import KernovaKit
import KernovaLogging

/// The AppKit adapter over ``VMCommandCore``: the sheets and alerts that gather
/// consent for a verb, the routing of a refused verb to the right surface, and
/// the inline-rename editing state.
///
/// It runs no verb itself. Each method here does three things and stops: show
/// the sheet if one is owed, call the core with explicit consent, and route
/// whatever ``CommandError`` comes back through ``present(_:about:)``.
///
/// Owns the library and the core, routes ``VMLibrary/onFailure`` and the core's
/// own failures to the presenter, and forwards the library's reads so a view
/// controller holding a view model still sees one surface.
@MainActor
@Observable
package final class VMLibraryViewModel {
    nonisolated static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMLibraryViewModel")

    // MARK: - Services

    /// Which VMs exist, and everything that keeps that set in step with disk.
    package let library: VMLibrary

    /// Every VM verb, headless. The one path from this adapter to a VM.
    package let commands: VMCommandCore

    package let storageService: any VMStorageProviding
    let lifecycle: VMLifecycleCoordinator

    /// Pauses running VMs for system sleep and resumes them on wake.
    ///
    /// Held rather than read: the sleep watcher it is handed is what drives
    /// it, and this is the composition root that owns its lifetime.
    private let sleepWake: VMSleepWakeCoordinator

    /// Watches the USB accessories macOS assigns to Kernova; `nil` when this
    /// build cannot pass accessories through at all.
    ///
    /// Held rather than read, for the reason ``sleepWake`` is.
    private let usbAccessories: USBAccessoryCoordinator?

    /// The preferences store this library session reads and writes.
    package let preferences: AppPreferences

    /// What this build's signature authorizes, as every surface that degrades
    /// without an entitlement reads it.
    package var entitlements: EntitlementService { library.entitlements }
    /// The named networks VMs join together.
    package var networks: VMNetworkDirectory { library.networks }

    // MARK: - Library Forwarding

    // Reads and library-level operations, forwarded verbatim so every existing
    // holder of a view model keeps working. Observation carries through the
    // computed accessors, which read the library's own stored properties.
    // Nothing here is a VM verb; each is documented on ``VMLibrary``.

    package var instances: [VMInstance] { library.instances }

    package var entries: [LibraryEntry] { library.entries }

    package var arrivals: [VMArrival] { library.arrivals }

    package var selectedID: UUID? { library.selectedID }

    package var selection: SidebarRowKey? {
        get { library.selection }
        set { library.selection = newValue }
    }

    package var sidebarOptions: SidebarViewOptions {
        get { library.sidebarOptions }
        set { library.sidebarOptions = newValue }
    }

    package var sidebarLayout: SidebarLayout { library.sidebarLayout }

    package var sidebarContext: SidebarLayout.Context { library.sidebarContext }

    package func reconcileSelection(with layout: SidebarLayout) { library.reconcileSelection(with: layout) }

    package func selectRevealing(_ id: UUID) { library.selectRevealing(id) }

    package var isRevealPending: Bool { library.isRevealPending }

    package func takePendingReveal() -> Bool { library.takePendingReveal() }

    package var selectedInstance: VMInstance? { library.selectedInstance }

    package var selectedEntry: LibraryEntry? { library.selectedEntry }

    package var hasLoadedLibrary: Bool { library.hasLoadedLibrary }

    package var hasUninterruptibleWork: Bool { library.hasUninterruptibleWork }

    package var quitMustWaitOut: Bool { library.quitMustWaitOut }

    package func beginTermination() { library.beginTermination() }

    /// ``VMLibrary/startLibrary()``, answering the VMs its read found marked
    /// to start automatically.
    @discardableResult
    package func startLibrary() async -> Set<UUID> { await library.startLibrary() }

    @discardableResult
    func loadVMs() async -> Set<UUID> { await library.loadVMs() }

    func reconcileWithDisk() { library.reconcileWithDisk() }

    package func abandonArrivalsForTermination() { library.abandonArrivalsForTermination() }

    package func moveEntries(fromOffsets source: IndexSet, toOffset destination: Int) {
        library.moveEntries(fromOffsets: source, toOffset: destination)
    }

    package func vmNamesSharingMACAddress(with instance: VMInstance) -> [String] {
        library.macAddresses.vmNamesSharingMACAddress(with: instance)
    }

    /// The other VMs holding `instance`'s machine identity, in library order —
    /// whatever their MAC addresses.
    package func vmNamesSharingMachineIdentity(with instance: VMInstance) -> [String] {
        instances.filter { $0 !== instance && instance.sharesMachineIdentity(with: $0) }.map(\.name)
    }

    package func guestAddress(for instance: VMInstance) -> GuestIPAddress {
        library.guestAddresses.address(for: instance)
    }

    // MARK: - Configuration Forwarding

    /// How an edit a surface asked for came out.
    package enum EditOutcome: Equatable {
        case applied
        /// Refused or unsaved; nothing changed, and the user has been told
        /// why.
        case refused
        /// The edit needs the user's consent first, which the caller gathers and
        /// then repeats the edit with the prompt's kind in its consent. Nothing
        /// is presented.
        case consentRequired(ConfirmationPrompt)
    }

    /// Applies `assignments` to `instance` through the configuration verb — the
    /// one path a surface's settings edit takes.
    @discardableResult
    package func setConfiguration(
        _ assignments: [ConfigurationEntry], on instance: VMInstance, consent: Consent = .none
    ) -> EditOutcome {
        do {
            try commands.setConfiguration(
                .id(instance.id), assignments: assignments, consent: consent)
            return .applied
        } catch let error as CommandError {
            guard let requirement = error.stepRequirement, !requirement.routes.isEmpty else {
                return route(error, ofEditOn: instance)
            }
            offerRoute(through: requirement, thenSetting: assignments, on: instance, consent: consent)
            return .refused
        } catch {
            return route(error, ofEditOn: instance)
        }
    }

    /// Asks which route through an edit's step refusal to take, takes its
    /// steps, and makes the same edit again — a network change a running VM
    /// was refused over its MAC address, moved to a network of its own first.
    ///
    /// Asked after the refusal returns, since the edit that raised it answers
    /// synchronously; a refusal that could not be asked takes the error path.
    private func offerRoute(
        through requirement: StepRequirement, thenSetting assignments: [ConfigurationEntry],
        on instance: VMInstance, consent: Consent
    ) {
        Task {
            do {
                let route = try await askForRoute(through: requirement, then: nil, about: instance)
                for step in route.steps { try await commands.take(step) }
            } catch is ConfirmationDeclined {
                return
            } catch {
                present(error, about: .vm(instance))
                return
            }
            setConfiguration(assignments, on: instance, consent: consent)
        }
    }

    /// Deletes the network `id` identifies, first moving each VM set to join
    /// it to a network of its own — the route the delete's refusal names, then
    /// the delete again.
    ///
    /// The core offers that route only once every move in it passes its
    /// gates, and the moves and the delete run in one main-actor turn, so
    /// every VM moves and the network goes, or nothing changes; only a failed
    /// save can leave a move made.
    package func deleteNetwork(_ id: UUID) throws {
        do {
            try commands.deleteNetwork(id.uuidString)
        } catch let error as CommandError {
            guard let route = error.stepRequirement?.routes.first,
                error.stepRequirement?.routes.count == 1
            else { throw error }
            let moves = try route.steps.map { step in
                guard case .setConfiguration(let vm, let assignments) = step else { throw error }
                return (vm, assignments)
            }
            for (vm, assignments) in moves {
                try commands.setConfiguration(.id(vm.id), assignments: assignments, consent: .none)
            }
            try commands.deleteNetwork(id.uuidString)
        }
    }

    /// Records the screen `instance`'s display was last full screen on.
    ///
    /// Kernova's own bookkeeping rather than a user's edit, so it takes no key:
    /// a ``VMEditClasses/hostPresentation`` edit, which a VM whose state admits
    /// none leaves unrecorded.
    package func recordLastFullscreenDisplay(_ displayID: UInt32, for instance: VMInstance) {
        do {
            try instance.activity.edit(.hostPresentation) {
                library.updateHostState($0) { $0.lastFullscreenDisplayID = displayID }
            }
        } catch {
            #log(
                Self.logger, .notice,
                "Did not record the fullscreen display of '\(instance.name, privacy: .public)': \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Command Forwarding

    // Headless reads and gates the UI enables its commands from, each
    // documented on ``VMCommandCore``.
    //
    // A read that resolves its VM refuses only with
    // ``CommandError/notFound(_:)``, which a sheet still up while its VM left
    // the library is the one way to reach: there is nothing for a user to act
    // on, so it reads as empty and is logged.

    /// Every per-VM capability predicate the AppKit surfaces read.
    package var capabilities: VMCapabilityCatalog { library.capabilities }

    /// Whether this build can pass a host USB accessory through to a guest —
    /// what decides whether the USB Device menu exists at all.
    package var supportsUSBAccessories: Bool { library.supportsUSBAccessories }

    package func snapshotSizes(for instance: VMInstance) async -> [UUID: SnapshotSize] {
        do {
            return try await commands.snapshotSizes(of: .id(instance.id))
        } catch {
            #log(
                Self.logger, .debug,
                "No snapshot sizes for '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    package func externalAttachments(for instance: VMInstance) async -> [ExternalAttachment] {
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

    package func sharingVMNames(
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
    // verb, each documented on ``VMCommandCore``. The pane gathers the consent
    // a trashing removal asks for, so the storage and removable-media removals
    // arrive pre-confirmed; a share removal destroys nothing and asks none.

    package func attachStorageDisks(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) { try self.commands.attachStorageDisks(.id(instance.id), paths: files) }
    }

    package func createStorageDisk(for instance: VMInstance, sizeInGB: Int) async {
        await run(on: instance) {
            try await self.commands.createStorageDisk(.id(instance.id), sizeInGB: sizeInGB)
        }
    }

    package func removeStorageDisk(_ disk: UUID, from instance: VMInstance, trashFile: Bool) async {
        await runEdit(on: instance) {
            try await self.commands.removeStorageDisk(
                .id(instance.id), disk: disk, trashFile: trashFile,
                consent: Consent([.removeAttachment]))
        }
    }

    package func renameStorageDisk(_ disk: UUID, newLabel: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.renameStorageDisk(.id(instance.id), disk: disk, to: newLabel)
        }
    }

    package func setStorageDiskNotes(_ disk: UUID, notes: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setStorageDiskNotes(.id(instance.id), disk: disk, notes: notes)
        }
    }

    package func setStorageDiskReadOnly(_ disk: UUID, readOnly: Bool, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setStorageDiskReadOnly(
                .id(instance.id), disk: disk, readOnly: readOnly)
        }
    }

    package func reorderStorageDisks(_ order: [UUID], on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.reorderStorageDisks(.id(instance.id), order: order)
        }
    }

    package func attachRemovableMedia(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.attachRemovableMedia(.id(instance.id), paths: files)
        }
    }

    package func createRemovableMedia(
        for instance: VMInstance, sizeInGB: Int, destinationURL: URL
    ) async {
        await run(on: instance) {
            try await self.commands.createRemovableMedia(
                .id(instance.id), sizeInGB: sizeInGB, destinationURL: destinationURL)
        }
    }

    package func removeRemovableMedia(_ item: UUID, from instance: VMInstance, trashFile: Bool) async {
        await runEdit(on: instance) {
            try await self.commands.removeRemovableMedia(
                .id(instance.id), item: item, trashFile: trashFile,
                consent: Consent([.removeAttachment]))
        }
    }

    package func ejectRemovableMedia(_ item: UUID, from instance: VMInstance) {
        runEdit(on: instance) { try self.commands.ejectRemovableMedia(.id(instance.id), item: item) }
    }

    package func renameRemovableMedia(_ item: UUID, newLabel: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.renameRemovableMedia(.id(instance.id), item: item, to: newLabel)
        }
    }

    package func setRemovableMediaNotes(_ item: UUID, notes: String, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setRemovableMediaNotes(.id(instance.id), item: item, notes: notes)
        }
    }

    package func setRemovableMediaReadOnly(_ item: UUID, readOnly: Bool, on instance: VMInstance) {
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
    package func attachSourceAuthority(_ authority: any SandboxSourceAuthorizing) {
        commands.sourceAuthority = authority
    }

    package func addSharedDirectories(_ files: [PickedFile], to instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.addSharedDirectories(.id(instance.id), paths: files)
        }
    }

    package func removeSharedDirectory(_ directory: UUID, from instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.removeSharedDirectory(.id(instance.id), directory: directory)
        }
    }

    package func setSharedDirectoryReadOnly(_ directory: UUID, readOnly: Bool, on instance: VMInstance) {
        runEdit(on: instance) {
            try self.commands.setSharedDirectoryReadOnly(
                .id(instance.id), directory: directory, readOnly: readOnly)
        }
    }

    /// Cancels a guest setup from the confirmation `GuestSetupProgressViewController`
    /// already gathered, so this always calls the core pre-confirmed.
    package func cancelGuestSetup(_ instance: VMInstance) {
        do {
            try commands.cancelGuestSetup(.id(instance.id), consent: Consent([.cancelGuestSetup]))
        } catch let error as CommandError {
            // Setup finishing between the button appearing and the click is a
            // normal race, not something to alert the user about.
            #log(
                Self.logger, .notice,
                "Nothing to cancel for '\(instance.name, privacy: .public)': \(error.message, privacy: .public)"
            )
        } catch {
            present(error, about: .vm(instance))
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
    package var agentInstallPromptDisabled: Bool {
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
    package var keepInMenuBarOnQuit: Bool {
        didSet {
            guard keepInMenuBarOnQuit != oldValue else { return }
            #log(
                Self.logger, .notice,
                "Setting keep in menu bar=\(self.keepInMenuBarOnQuit, privacy: .public)"
            )
            preferences.keepInMenuBarOnQuit = keepInMenuBarOnQuit
        }
    }

    /// Where the alerts and sheets this view model raises are shown.
    ///
    /// Set by the composition root before the library's first read starts, so
    /// nothing raised by a launch goes unpresented; a request with no window to
    /// show on waits in the presenter.
    @ObservationIgnored package weak var presenter: (any VMLibraryPresenting)?

    /// The library window's own surfaces — the creation wizard and the inline
    /// guest display — attached by that window's detail pane.
    ///
    /// A config check or an inline focus asked for before one is attached — the
    /// library read starts in `applicationWillFinishLaunching`, ahead of any
    /// window — is held and delivered when one is.
    @ObservationIgnored package weak var libraryWindowPresenter: (any LibraryWindowPresenting)? {
        didSet {
            guard libraryWindowPresenter != nil else { return }
            if owesConfigCheck {
                owesConfigCheck = false
                onShowConfigCheck?(.automatic)
            }
            if let id = bufferedDisplayFocus {
                bufferedDisplayFocus = nil
                if let instance = instances.first(where: { $0.id == id }) {
                    libraryWindowPresenter?.focusGuestDisplay(for: instance)
                }
            }
        }
    }

    /// The VM an inline surface was asked for before any library window
    /// existed, focused when one attaches.
    @ObservationIgnored private var bufferedDisplayFocus: UUID?

    /// The one rename open: in a sidebar row — held by the library
    /// (``VMLibrary/sidebarRenameID``), which ends it once no row lists the
    /// VM — or in the detail pane.
    package var activeRename: RenameTarget? {
        get { library.sidebarRenameID.map(RenameTarget.sidebar) ?? detailRenameID.map(RenameTarget.detail) }
        set {
            switch newValue {
            case .sidebar(let id):
                detailRenameID = nil
                library.sidebarRenameID = id
            case .detail(let id):
                library.sidebarRenameID = nil
                detailRenameID = id
            case nil:
                library.sidebarRenameID = nil
                detailRenameID = nil
            }
        }
    }

    /// The VM a rename in the detail pane is open on.
    private var detailRenameID: UUID?

    /// Asks for a VM's display window, for a verb that puts the display in
    /// front of the user.
    @ObservationIgnored package var onOpenDisplayWindow: ((VMInstance) -> Void)?

    /// Reports that a VM is coming up, and whether anyone asked for it in
    /// particular, so its display can be readied.
    ///
    /// What that costs on screen is the delegate's decision, taken from the
    /// app's own posture and that presence — a bring-up is not a request to
    /// look at the guest.
    @ObservationIgnored package var onReadyDisplay: ((VMInstance, VMBringUpPresence) -> Void)?

    /// Asks for the library window, for an inline surface with nowhere to land.
    ///
    /// The inline display lives inside the main window, so a verb surfacing one
    /// on a process that has never opened a window — an intent on the headless
    /// launch path — has to bring that window up first or do nothing at all.
    @ObservationIgnored package var onSurfaceLibrary: (() -> Void)?

    /// Asks for the app to be taken down, for the quit verb an automation door
    /// carries. The app delegate answers it with the same full quit the status
    /// item's Quit performs.
    @ObservationIgnored package var onRequestQuit: (() -> Void)?

    /// Asks for a VM's bundle to be selected in the Finder, for the verb that
    /// puts it there. The app delegate answers it with the Workspace call.
    @ObservationIgnored package var onRevealInFinder: ((VMInstance) -> Void)?

    /// Who asked for the config check window.
    package enum ConfigCheckRequest {
        /// The user — a menu, a context menu, a button — so Kernova comes
        /// forward with the window.
        case user
        /// A read that found a newly unreadable file, so the window comes up
        /// without taking focus from the app or window the user is in.
        case automatic
    }

    /// Asks for the config check window, which reads every config file afresh
    /// as it comes up.
    @ObservationIgnored package var onShowConfigCheck: ((ConfigCheckRequest) -> Void)?

    /// Asks for Kernova's Settings window on a destination.
    @ObservationIgnored package var onShowSettings: ((SettingsDestination) -> Void)?

    /// Puts Kernova's Settings window in front of the user on `destination`.
    package func showSettings(at destination: SettingsDestination) {
        onShowSettings?(destination)
    }

    /// Whether a read found a config file it can't read while no library
    /// window was attached: the check comes up when one is.
    @ObservationIgnored private var owesConfigCheck = false

    /// Puts the config check in front of the user — File > Check Config
    /// Files…, and every surface that offers the same.
    package func showConfigCheck() {
        onShowConfigCheck?(.user)
    }

    package func checkConfigFiles() async throws -> [UnreadableConfigFile] {
        try await library.checkConfigFiles()
    }

    package func useDefaults(in files: [UnreadableConfigFile]) async -> [VMLibrary.ConfigFileRepairFailure] {
        await library.useDefaults(in: files)
    }

    /// The folder the library's config files sit under — the VMs folder and
    /// `Networks.json` both — which the check writes their paths relative to;
    /// `nil` when it cannot be resolved.
    package var libraryDirectory: URL? {
        try? storageService.vmsDirectory.deletingLastPathComponent()
    }

    /// Moves the bundle `bundle` was read from to the Trash, whole, telling
    /// the user when the Trash turns it down.
    package func moveToTrash(_ bundle: UnreadableVM) async {
        do {
            try await library.moveToTrash(bundle)
        } catch {
            #log(
                Self.logger, .error,
                "Couldn't move \(bundle.bundleURL.lastPathComponent, privacy: .public) to the Trash: \(error.localizedDescription, privacy: .public)"
            )
            surfaceError(
                error.localizedDescription, title: "Couldn\u{2019}t Move to Trash", about: .library)
        }
    }

    /// Measures the window or screen a starting VM's display will occupy, for
    /// `displaySizesToWindow` — `nil` when it can't be measured, and the VM
    /// then boots at its persisted resolution. The window layer sets it: only
    /// it knows which window or screen a VM's `displayPreference` resolves to.
    @ObservationIgnored package var displayBootSurface: ((VMInstance) -> DisplayBootSurface?)?

    /// The host notifications the library and its surfaces observe.
    @ObservationIgnored package let hostNotifications: HostNotifications

    /// Reads a restore image already on disk, for the creation wizard.
    @ObservationIgnored private let localImageInspector: any LocalRestoreImageInspecting

    /// A creation wizard over this library's Virtualization host and
    /// restore-image lookups.
    package func makeCreationViewModel() -> VMCreationViewModel {
        VMCreationViewModel(
            host: library.virtualizationHost, localImageInspector: localImageInspector,
            ipswService: lifecycle.ipswService)
    }

    // MARK: - Initialization

    /// A collaborator over the user's own state — the VMs directory, the
    /// defaults domain, the Trash, the Downloads folder, the host's vmnet
    /// networks and their store, its ARP table, the signature's entitlements,
    /// the host's notifications and its pasteboard, the app bundle's products
    /// and the disk images made from them — takes no default: a test process
    /// runs unsandboxed in the developer's real home, with a signature of its
    /// own, so a default would hand that state to every test that left it
    /// out. Nor does one the
    /// Virtualization engine makes — the host's answers, the bundle machine
    /// files, the restore-image lookups, the removable-media devices, the
    /// bridged interfaces — which the core cannot build. `KernovaApp`
    /// supplies each.
    package init(
        storageService: any VMStorageProviding,
        diskImageService: any DiskImageProviding,
        machineFiles: any VMBundleMachineFileWorking,
        virtualizationHost: any VirtualizationHostProviding,
        virtualizationService: any VirtualizationProviding,
        installService: any MacOSInstallProviding,
        ipswService: any IPSWProviding,
        localImageInspector: any LocalRestoreImageInspecting,
        removableMediaDeviceService: any RemovableMediaAttaching,
        bridgedInterfaces: any BridgedInterfaceProviding,
        // Supplied by `KernovaApp`, the one caller that should claim the
        // user's accessories — registering the listener is a side effect on
        // the whole process, and a default would hand it to every test that
        // builds a view model for something else entirely.
        usbAccessoryService: (any USBAccessoryProviding)? = nil,
        // Supplied by `KernovaApp` for the reason `usbAccessoryService` is:
        // the power registration is a side effect on the whole process.
        systemSleep: SystemSleepWatcher? = nil,
        linuxImageResolveService: any LinuxImageResolving = LinuxImageResolveService(),
        downloadService: any Downloading = DownloadService(),
        fileSystem: any FileSystemOperating,
        downloadsDirectory: URL?,
        preferences: AppPreferences,
        vmnetNetworks: VmnetNetworkService,
        arpTable: any ARPTableReading,
        entitlements: EntitlementService,
        networks: VMNetworkDirectory = VMNetworkDirectory(fileURL: nil),
        organization: VMOrganizationDirectory = VMOrganizationDirectory(fileURL: nil),
        hostNotifications: HostNotifications,
        hostPasteboard: any ClipboardPasteboard,
        bundleProducts: AppBundleProducts
    ) {
        self.storageService = storageService
        self.localImageInspector = localImageInspector
        self.hostNotifications = hostNotifications
        self.preferences = preferences
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
            machineFiles: machineFiles,
            lifecycle: lifecycle,
            preferences: preferences,
            vmnetNetworks: vmnetNetworks,
            arpTable: arpTable,
            entitlements: entitlements,
            networks: networks,
            organization: organization,
            virtualizationHost: virtualizationHost,
            bridgedInterfaces: bridgedInterfaces,
            appActivation: hostNotifications.appDidBecomeActive,
            hostPasteboard: hostPasteboard,
            bundleProducts: bundleProducts,
            logSink: nil
        )
        self.library = library
        let sleepWake = VMSleepWakeCoordinator(
            lifecycle: lifecycle, roster: library, systemSleep: systemSleep)
        self.sleepWake = sleepWake
        let usbAccessories = USBAccessoryCoordinator(
            lifecycle: lifecycle, library: library)
        self.usbAccessories = usbAccessories
        let commands = VMCommandCore(
            library: library,
            lifecycle: lifecycle,
            storageService: storageService,
            diskImageService: diskImageService,
            fileSystem: fileSystem,
            preferences: preferences,
            logSink: nil
        )
        self.commands = commands

        library.onFailure = { [weak self] title, message, subject in
            self?.surfaceError(message, title: title, about: subject)
        }
        library.onUnreadableFilesFound = { [weak self] in
            guard let self else { return }
            guard self.libraryWindowPresenter != nil else {
                self.owesConfigCheck = true
                return
            }
            self.onShowConfigCheck?(.automatic)
        }
        // Each of its failures names every VM it is about.
        sleepWake.onFailure = { [weak self] error in
            self?.present(error, about: .library)
        }
        // The same routing a call site gets, so a failure nobody awaited still
        // reaches the sheet or the recovery alert its type asks for.
        commands.onFailure = { [weak self] failure, instance in
            self?.present(failure, about: instance.map(AlertSubject.vm) ?? .library)
        }
        commands.surfaceDisplay = { [weak self] instance in
            self?.surfaceDisplay(for: instance)
        }
        // Straight through: what a bring-up puts on screen is decided from the
        // app's own posture, which only the delegate can read.
        commands.readyDisplay = { [weak self] instance, presence in
            self?.onReadyDisplay?(instance, presence)
        }
        commands.revealInLibrary = { [weak self] id in
            self?.revealInLibrary(id)
        }
        commands.revealInFinder = { [weak self] instance in
            self?.onRevealInFinder?(instance)
        }
        commands.requestQuit = { [weak self] in
            self?.onRequestQuit?()
        }
        commands.displayBootSurface = { [weak self] instance in
            self?.displayBootSurface?(instance)
        }
        commands.usbAccessoryPairings = usbAccessories
        library.onSessionBecameAttachable = { [weak usbAccessories] instance in
            usbAccessories?.sessionBecameAttachable(instance) ?? []
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
    package func forgetUSBAccessory(key: String, on instance: VMInstance) {
        do {
            try commands.forgetUSBPairing(.id(instance.id), key: key)
        } catch {
            present(error, about: .vm(instance))
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
    package func createVM(from wizard: VMCreationViewModel) throws {
        try commands.create(
            configuration: wizard.buildConfiguration(),
            diskSizeInGB: wizard.diskSizeInGB,
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
            revealInLibrary(instance.id)
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
        selectRevealing(instance.id)
        deliverInlineFocus(to: instance)
    }

    /// Moves the first responder into the selected VM's inline display, holding
    /// the ask until a window exists to move it in.
    private func deliverInlineFocus(to instance: VMInstance) {
        guard let libraryWindowPresenter else {
            // No library window has ever been created, so there is no inline
            // display to focus yet. The one just asked for focuses when it
            // attaches.
            bufferedDisplayFocus = instance.id
            return
        }
        libraryWindowPresenter.focusGuestDisplay(for: instance)
    }

    /// Selects the row, dropping any sidebar filter that hides it, and asks for
    /// the library window — what a reveal lands on
    /// when there is no display to surface.
    private func revealInLibrary(_ id: UUID) {
        selectRevealing(id)
        onSurfaceLibrary?()
    }

    /// The door every in-app start gesture funnels through: the verb, plus the
    /// look at the guest the gesture also asked for.
    ///
    /// Every caller is somebody in the library clicking Start — the toolbar,
    /// the menus, the sidebar's context menu, the display window's Resume — so
    /// the VM becomes the selected one and the keyboard lands in its display,
    /// ahead of the boot rather than at the end of it. A start arriving from
    /// anywhere else goes through ``VMCommandCore`` and moves nothing.
    package func start(_ instance: VMInstance, bootIntoRecovery: Bool = false) async {
        focusInlineDisplay(for: instance)
        await runAsking(on: instance, then: "Start") { consent in
            try await self.commands.start(
                .id(instance.id), recovery: bootIntoRecovery, consent: consent)
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
    package func removeStartFailedAttachmentAndStart(
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
            present(error, about: .vm(instance))
            return
        }
        await start(instance)
    }

    /// What a user walking away from the account question raises, so the door
    /// that asked can tell it from a refusal worth an alert.
    private struct GuestAccountPromptDismissed: Error {}

    /// What a user declining a confirmation raises, for the same reason.
    private struct ConfirmationDeclined: Error {}

    /// Runs a bring-up through
    /// ``VMConsentPolicy/run(prompting:choosingRoute:taking:_:)`` and, inside
    /// it, ``VMConsentPolicy/runGatheringGuestAccount(prompting:_:)``, asking
    /// on screen for each consent, the route through a step refusal — each
    /// button naming the route and then `verbTitle`, or the start a route ends
    /// with — and the account it refuses without. A route ending in a start
    /// runs that start in place of `verb`.
    ///
    /// Asking is the door's job and deciding is the verb's: this presents the
    /// questions and hands each answer to the verbs, writing nothing itself;
    /// a route's steps are each a verb of their own. A verb that refuses
    /// nothing never shows one.
    ///
    /// A declined question ends the verb with nothing on screen — the user just
    /// said no to it. A question that could not be asked leaves its refusal
    /// standing, and that refusal takes the ordinary error surface like every
    /// other, queued behind whatever is on screen.
    ///
    /// Answers whether the verb ran.
    @discardableResult
    private func runAsking(
        on instance: VMInstance, then verbTitle: String?,
        _ verb: (Consent) async throws -> Void
    ) async -> Bool {
        do {
            try await VMConsentPolicy.run(
                prompting: { try await self.askToConfirm($0, about: instance) },
                choosingRoute: { try await self.askForRoute(through: $0, then: verbTitle, about: instance) },
                taking: { try await self.commands.take($0) }
            ) { consent, ending in
                try await VMConsentPolicy.runGatheringGuestAccount(
                    prompting: { try await self.askForGuestAccount($0) },
                    {
                        switch ending {
                        case .refusedVerb:
                            try await verb(consent)
                        case .start(let vm):
                            try await self.commands.start(.id(vm.id), recovery: false, consent: consent)
                        }
                    })
            }
            return true
        } catch is GuestAccountPromptDismissed {
            #log(
                Self.logger, .notice,
                "Start of '\(instance.name, privacy: .public)' cancelled at the account password"
            )
        } catch is ConfirmationDeclined {
            #log(
                Self.logger, .notice,
                "'\(instance.name, privacy: .public)': the user declined the confirmation it asked for"
            )
        } catch {
            present(error, about: .vm(instance))
        }
        return false
    }

    /// Puts a confirmation a verb on `instance` raised on screen and waits for
    /// the user's answer.
    ///
    /// - Throws: ``ConfirmationDeclined`` when the user walked away, and the
    ///   refusal itself when it could not be asked.
    private func askToConfirm(_ prompt: ConfirmationPrompt, about instance: VMInstance) async throws {
        guard let presenter else { throw CommandError.confirmationRequired(prompt) }
        let answer = await withCheckedContinuation { continuation in
            presenter.presentConfirmationRequest(
                ConfirmationRequest(
                    instance: instance, prompt: prompt,
                    answer: { continuation.resume(returning: $0) }))
        }
        switch answer {
        case .answered(true): return
        case .answered(false): throw ConfirmationDeclined()
        case .unasked: throw CommandError.confirmationRequired(prompt)
        }
    }

    /// Puts the routes a step refusal a verb on `instance` raised names on
    /// screen and waits for the user's choice.
    ///
    /// - Throws: ``ConfirmationDeclined`` when the user walked away, and the
    ///   refusal itself when it could not be asked.
    private func askForRoute(
        through requirement: StepRequirement, then verbTitle: String?, about instance: VMInstance
    ) async throws -> StepRoute {
        guard let presenter else { throw CommandError.stepRequired(requirement) }
        let answer = await withCheckedContinuation { continuation in
            presenter.presentStepRoutes(
                StepRouteRequest(
                    instance: instance, requirement: requirement, verbTitle: verbTitle,
                    answer: { continuation.resume(returning: $0) }))
        }
        switch answer {
        case .answered(let route?): return route
        case .answered(nil): throw ConfirmationDeclined()
        case .unasked: throw CommandError.stepRequired(requirement)
        }
    }

    /// Puts the account question on screen and supplies the one answer it gives.
    ///
    /// - Throws: ``GuestAccountPromptDismissed`` when the user walked away, the
    ///   refusal itself when it could not be asked, and whatever the verb that
    ///   takes the answer refuses with.
    private func askForGuestAccount(_ prompt: GuestAccountPrompt) async throws {
        guard let presenter else { throw CommandError.guestAccountPasswordRequired(prompt) }
        let answer = await withCheckedContinuation { continuation in
            presenter.presentGuestAccountPassword(
                GuestAccountPasswordRequest(
                    prompt: prompt, answer: { continuation.resume(returning: $0) }))
        }
        switch answer {
        case .answered(.password(let password)):
            try commands.provideGuestAccountPassword(.id(prompt.vm.id), password: password)
        case .answered(.skip):
            try commands.skipGuestAccount(.id(prompt.vm.id))
        case .answered(.cancelled):
            throw GuestAccountPromptDismissed()
        case .unasked:
            throw CommandError.guestAccountPasswordRequired(prompt)
        }
    }

    /// A graceful stop, or — for a live-paused guest, which cannot take one —
    /// the sheet offering Resume and Shut Down or Force Stop.
    ///
    /// The pause is read in the same main-actor turn the core reads it in
    /// before refusing, so the two cannot disagree.
    package func stop(_ instance: VMInstance) async {
        guard !instance.isLivePaused else {
            presenter?.presentStopPaused(for: instance)
            return
        }
        await run(on: instance) {
            try await self.commands.stop(
                .id(instance.id), disposition: .graceful, consent: .none)
        }
    }

    /// Resumes a paused VM, then requests a graceful shutdown — the stop-paused
    /// sheet's default action, as two verbs. The resume asks what any resume
    /// asks, and a resume that does not happen stops nothing.
    package func resumeAndStop(_ instance: VMInstance) async {
        let resumed = await runAsking(on: instance, then: "Resume") { consent in
            try await self.commands.resume(.id(instance.id), consent: consent)
        }
        guard resumed else { return }
        await run(on: instance) {
            try await self.commands.stop(
                .id(instance.id), disposition: .graceful, consent: .none)
        }
    }

    package func forceStop(_ instance: VMInstance) async {
        await run(on: instance) {
            try await self.commands.stop(
                .id(instance.id), disposition: .force, consent: Consent([.forceStop]))
        }
    }

    /// Opens the Force Stop / Discard Saved State confirmation.
    package func requestForceStop(_ instance: VMInstance) {
        presenter?.presentForceStop(for: instance)
    }

    /// Opens the confirmation for booting a stopped macOS guest into macOS
    /// Recovery.
    package func requestStartInRecovery(_ instance: VMInstance) {
        presenter?.presentRecoveryBoot(for: instance)
    }

    package func pause(_ instance: VMInstance) async {
        await run(on: instance) { try await self.commands.pause(.id(instance.id)) }
    }

    /// The resume half of the in-app door, surfacing what ``start(_:bootIntoRecovery:)``
    /// surfaces for the same reason.
    package func resume(_ instance: VMInstance) async {
        focusInlineDisplay(for: instance)
        await runAsking(on: instance, then: "Resume") { consent in
            try await self.commands.resume(.id(instance.id), consent: consent)
        }
    }

    package func save(_ instance: VMInstance) async {
        await run(on: instance) { try await self.commands.suspend(.id(instance.id)) }
    }

    /// Suspends a VM for the termination save pass, throwing on failure.
    package func saveForTermination(_ instance: VMInstance) async throws {
        try await commands.suspend(instance, origin: .terminationSave)
    }

    /// Force-stops a VM, throwing on failure — the termination save pass's
    /// fallback for a save that failed and left the guest live.
    package func tryForceStop(_ instance: VMInstance) async throws {
        try await commands.stop(
            .id(instance.id), disposition: .force, consent: Consent([.forceStop]))
    }

    // MARK: - Snapshots

    /// Opens the Take Snapshot sheet.
    package func requestTakeSnapshot(_ instance: VMInstance, for purpose: TakeSnapshotPurpose = .restorePoint) {
        guard capabilities.isAvailable(.takeSnapshot, on: instance) else { return }
        presenter?.presentTakeSnapshotSheet(for: instance, purpose: purpose)
    }

    /// Captures a snapshot from the Take Snapshot sheet's confirm; for an
    /// Ephemeral baseline, the capture also turns the mode on with it.
    ///
    /// The returned Task lets tests await the capture.
    @discardableResult
    package func takeSnapshot(
        _ instance: VMInstance, name: String, notes: String = "",
        for purpose: TakeSnapshotPurpose = .restorePoint
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            await self.run(on: instance) {
                _ = try await self.commands.takeSnapshot(
                    .id(instance.id), name: name, notes: notes,
                    asEphemeralBaseline: purpose == .ephemeralBaseline)
            }
        }
    }

    /// Opens the revert confirmation.
    package func requestRevert(_ instance: VMInstance, to snapshot: VMSnapshot) {
        guard capabilities.isAvailable(.revertToSnapshot, on: instance) else { return }
        presenter?.presentRevertSnapshot(snapshot, for: instance)
    }

    /// Passes a host USB accessory through to `instance`'s guest.
    ///
    /// No confirmation: the user already consented to Kernova holding this
    /// accessory in Apple's *Virtual Machine Accessories* menu, and a detach is
    /// one action away.
    package func attachUSBAccessory(_ registryID: UInt64, to instance: VMInstance) {
        guard capabilities.isAvailable(.editUSBAccessories, on: instance) else { return }
        Task {
            await run(on: instance) {
                try await self.commands.attachUSBAccessory(
                    .id(instance.id), accessory: registryID)
            }
        }
    }

    /// Takes a passed-through accessory back off `instance`'s guest.
    package func detachUSBAccessory(deviceID: UUID, from instance: VMInstance) {
        guard capabilities.isAvailable(.editUSBAccessories, on: instance) else { return }
        Task {
            await run(on: instance) {
                try await self.commands.detachUSBAccessory(.id(instance.id), device: deviceID)
            }
        }
    }

    /// Reverts to `snapshot`, first taking a snapshot of the current state
    /// when `takingSnapshotFirst` — the revert confirmation's two actions,
    /// which already gave the revert's own consent.
    ///
    /// Two verbs: a capture that fails reverts nothing, and the capture sits
    /// outside the revert's own questions, so a revert asked again never
    /// captures twice.
    package func revert(
        _ instance: VMInstance, to snapshot: VMSnapshot, takingSnapshotFirst: Bool = false
    ) async {
        if takingSnapshotFirst {
            do {
                try await commands.takeSnapshot(
                    .id(instance.id), name: instance.snapshotManifest.defaultNewName, notes: "")
            } catch {
                present(error, about: .vm(instance))
                return
            }
        }
        await runAsking(on: instance, then: nil) { consent in
            try await self.commands.revertToSnapshot(
                .id(instance.id), snapshot: snapshot.id,
                consent: consent.adding(.revertToSnapshot))
        }
    }

    /// Opens the delete-snapshot confirmation.
    package func requestDeleteSnapshot(_ instance: VMInstance, snapshot: VMSnapshot) {
        guard capabilities.isAvailable(.deleteSnapshot, on: instance) else {
            #log(
                Self.logger, .notice,
                "Refusing to delete snapshot '\(snapshot.name, privacy: .public)': '\(instance.name, privacy: .public)' does not offer a delete now"
            )
            return
        }
        presenter?.presentDeleteSnapshot(snapshot, for: instance)
    }

    /// Trashes a snapshot's captured files and drops it from the manifest —
    /// first turning Ephemeral Mode off when `turningOffEphemeralMode`, the
    /// confirmation the user answered having been the baseline's.
    ///
    /// Two steps through the verbs every other surface takes, in this order:
    /// the configuration write that turns the mode off, then the delete. A
    /// write that does not land deletes nothing, and a delete that fails leaves
    /// the mode off with the snapshot listed. A delete refused because the
    /// snapshot became the baseline while a plain confirmation was up asks
    /// again with the baseline's confirmation.
    ///
    /// The returned Task lets tests await the trash.
    @discardableResult
    package func deleteSnapshot(
        _ instance: VMInstance, snapshot: VMSnapshot, turningOffEphemeralMode: Bool
    ) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            if turningOffEphemeralMode {
                let off = self.setConfiguration(
                    [VMConfigurationKeyRegistry.ephemeral.assigning(false)], on: instance)
                guard off == .applied else { return }
            }
            do {
                try await self.commands.deleteSnapshot(
                    .id(instance.id), snapshot: snapshot.id, consent: Consent([.deleteSnapshot]))
            } catch {
                guard instance.isEphemeralBaseline(snapshot) else {
                    self.present(error, about: .vm(instance))
                    return
                }
                self.presenter?.presentDeleteSnapshot(snapshot, for: instance)
            }
        }
    }

    /// Renames a snapshot; an empty or unchanged name is a no-op.
    package func renameSnapshot(_ snapshot: VMSnapshot, newName: String, on instance: VMInstance) {
        runSync(on: instance) {
            try self.commands.renameSnapshot(
                .id(instance.id), snapshot: snapshot.id, to: newName)
        }
    }

    /// Replaces a snapshot's note; an unchanged value is a no-op.
    package func setSnapshotNotes(_ snapshot: VMSnapshot, notes: String, on instance: VMInstance) {
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
    package func requestDelete(_ instance: VMInstance, permanently: Bool = false) {
        presenter?.presentDeleteSheet(for: instance, permanently: permanently)
    }

    /// Deletes the VM bundle and the chosen external files, either to the
    /// Trash or immediately (bypassing it).
    package func delete(
        _ instance: VMInstance, deletingExternalIDs: Set<UUID> = [], permanently: Bool = false
    ) async {
        do {
            try await commands.delete(
                .id(instance.id), permanently: permanently, alsoRemoving: deletingExternalIDs,
                consent: Consent([.deleteVM]))
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
                present(error, about: .vm(instance))
            }
        } catch {
            present(error, about: .vm(instance))
        }
    }

    // MARK: - Import

    /// Filters `urls` to `.kernova` bundles and imports the batch, unwaited,
    /// into the folder `folder` identifies, if any
    /// (``VMCommandCore/beginImports(from:intoFolder:)``).
    ///
    /// Every import reserves its destination and registers its arrival before
    /// this returns, so two overlapping triggers never collide on a
    /// destination name and never wait behind each other's copies. Each
    /// refused import is presented; a folder that couldn't take the batch is
    /// presented once, apart from the imports, which run on.
    ///
    /// Returns whether any bundle was handed to an import — `true` means at
    /// least one import was started, not that every one will succeed.
    @discardableResult
    package func importVMs(fromDroppedURLs urls: [URL], intoFolder folder: UUID? = nil) -> Bool {
        let bundles = urls.filter { VMStorageService.isBundleURL($0) }
        guard !bundles.isEmpty else { return false }
        #log(Self.logger, .notice, "Importing \(bundles.count, privacy: .public) bundle(s)")
        let batch = commands.beginImports(from: bundles, intoFolder: folder)
        for case .failure(let error) in batch.imports { present(error, about: .library) }
        if let failure = batch.membershipFailure {
            surfaceError(
                failure.localizedDescription, title: "Couldn\u{2019}t Add to the Folder", about: .library)
        }
        return true
    }

    // MARK: - Show in Finder

    /// Selects the VM's bundle in the Finder.
    package func showVMInFinder(_ instance: VMInstance) {
        runSync(on: instance) { try self.commands.showInFinder(.id(instance.id)) }
    }

    // MARK: - Clone

    /// The alternate Clone menu item: clones `instance` as the outcome the
    /// primary item does not make (``AppPreferences/cloneMenuItems(for:)``),
    /// and does nothing where only one is offered.
    package func cloneVMAsAlternate(_ instance: VMInstance) {
        guard let alternate = preferences.cloneMenuItems(for: instance.configuration).alternate
        else { return }
        cloneVM(instance, as: alternate.outcome)
    }

    /// Clones `instance` as `outcome`; `nil` follows the clone preference.
    package func cloneVM(_ instance: VMInstance, as outcome: CloneOutcome? = nil) {
        do {
            try commands.beginClone(.id(instance.id), outcome: outcome)
        } catch let error as CommandError {
            if case .invalidState = error {
                #log(
                    Self.logger, .debug,
                    "Clone skipped for '\(instance.name, privacy: .public)': status '\(instance.status.displayName, privacy: .public)' does not allow editing"
                )
            } else {
                present(error, about: .vm(instance))
            }
        } catch {
            present(error, about: .vm(instance))
        }
    }

    // MARK: - Cancel Preparing

    /// Opens the cancel-create/clone/import confirmation.
    package func requestCancelPreparing(_ arrival: VMArrival) {
        presenter?.presentCancelPreparing(for: arrival)
    }

    /// Cancels an in-flight create, clone or import from that confirmation's confirm.
    package func cancelArrival(_ arrival: VMArrival) {
        do {
            try commands.cancelPreparing(.id(arrival.id), consent: Consent([.cancelPreparing]))
        } catch let error as CommandError {
            // The arrival settled while the confirmation was up: a failed one
            // left no row, and an adopted one is a VM the cancel refuses.
            #log(
                Self.logger, .notice,
                "Nothing to cancel for '\(arrival.name, privacy: .public)': \(error.message, privacy: .public)"
            )
        } catch {
            present(error, about: .library)
        }
    }

    // MARK: - Rename

    package enum RenameTarget: Equatable {
        case sidebar(UUID)
        case detail(UUID)
    }

    /// One of the two inline-rename surfaces, without the instance baked in.
    ///
    /// Commit/cancel call sites pass the surface and the instance separately so an
    /// instance/target id mismatch is unrepresentable.
    package enum RenameSurface {
        case sidebar
        case detail

        fileprivate func target(for instance: VMInstance) -> RenameTarget {
            switch self {
            case .sidebar: .sidebar(instance.id)
            case .detail: .detail(instance.id)
            }
        }
    }

    /// Opens a rename of `instance` in its sidebar row, revealing the row
    /// first (``VMLibrary/selectRevealing(_:in:)``); a VM no row can list is
    /// asked for no rename.
    package func renameVMInSidebar(_ instance: VMInstance) {
        guard library.selectRevealing(instance.id) != nil else {
            #log(Self.logger, .notice, "No sidebar row lists '\(instance.name, privacy: .public)' — no rename opened")
            return
        }
        #log(Self.logger, .debug, "Starting sidebar rename for '\(instance.name, privacy: .public)'")
        activeRename = .sidebar(instance.id)
    }

    package func renameVMInDetail(_ instance: VMInstance) {
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
    package func commitRename(for instance: VMInstance, newName: String, from surface: RenameSurface) {
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
            present(error, about: .vm(instance))
        }
        clearRename(ifOwnedBy: surface.target(for: instance))
    }

    /// Cancels the rename that `surface` has open on `instance`, leaving a rename
    /// that has since moved to the other surface untouched.
    package func cancelRename(for instance: VMInstance, from surface: RenameSurface) {
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
    package func applyClipboardPasteLimitChange() {
        for instance in instances {
            instance.resendAgentPolicy()
            instance.republishPassthroughIfCeilingRaised()
        }
    }

    // MARK: - Guest Agent Installer

    /// Performs the action `GuestAgentDiskControl.model(for:in:)` resolves for
    /// `instance` now — the one executor every surface showing that control
    /// calls.
    ///
    /// Ejecting removes the bundled installer from `removableMedia`, and the
    /// reconcile flow performs the runtime detach. Mounting attaches it and
    /// shows the next-step alert on every outcome: the alert is the whole action
    /// on two of the verb's three paths — an image already mounted, and a guest
    /// that takes it on virtio for the whole session.
    package func toggleGuestAgentDisk(on instance: VMInstance) {
        switch GuestAgentDiskControl.model(for: instance, in: capabilities).action {
        case .eject:
            runEdit(on: instance) { try self.commands.unmountGuestAgentDisk(.id(instance.id)) }
        case .mount(let purpose):
            runEdit(on: instance) {
                let outcome = try self.commands.mountGuestAgentDisk(.id(instance.id))
                self.presenter?.presentInstallerMounted(
                    for: instance, purpose: purpose, delivery: outcome.delivery)
            }
        }
    }

    /// Marks this VM's `.waiting` install nudge as dismissed and persists the choice.
    ///
    /// `.outdated`, `.unresponsive`, and `.expectedMissing` still surface — those imply
    /// something more urgent than "you could install this".
    package func dismissAgentInstallNudge(for instance: VMInstance) {
        setAgentInstallNudgeDismissed(true, for: instance)
    }

    /// Sets whether this VM's agent-install nudge is dismissed and persists the
    /// choice, through the `agent.installReminder` key.
    ///
    /// `true` silences the `.waiting` nudge, `false` re-arms it. A surface
    /// showing the flag repaints from the model unless the edit was applied.
    @discardableResult
    package func setAgentInstallNudgeDismissed(_ dismissed: Bool, for instance: VMInstance)
        -> EditOutcome
    {
        setConfiguration(
            [VMConfigurationKeyRegistry.agentInstallReminder.assigning(!dismissed)], on: instance)
    }

    /// Re-arms the agent-install nudge everywhere: clears the app-wide
    /// suppression *and* every VM's dismissed flag, so each VM's `.waiting`
    /// nudge can surface again.
    ///
    /// Each VM's flag lives in its own bundle and is persisted individually;
    /// VMs already armed make no edit.
    package func resetAllAgentInstallNudges() {
        agentInstallPromptDisabled = false
        let key = VMConfigurationKeyRegistry.agentInstallReminder
        for instance in instances where key.applies(instance.configuration) {
            setAgentInstallNudgeDismissed(false, for: instance)
        }
    }

    // MARK: - Launch Auto-Start

    /// Names of the macOS VMs marked to start automatically, in library order —
    /// which is the order ``startAutomaticVMsForLaunch(_:)`` reaches them in.
    ///
    /// Feeds the Startup section's capacity warning: macOS caps how many macOS
    /// guests run at once, so a longer list than that cap cannot come up whole.
    package var macOSVMNamesMarkedForAutoStart: [String] {
        instances
            .filter {
                $0.configuration.guestOS == .macOS
                    && $0.hostState.startsAutomaticallyOnLaunch
            }
            .map(\.name)
    }

    /// Starts the VMs the launch's library read found marked to start
    /// automatically, `marked` (``VMCommandCore/startVMsMarkedToStartAutomatically(_:)``),
    /// then puts one account of every VM it left undone on screen — held until
    /// a window can show it, on a launch that opens none.
    ///
    /// Nobody is at the machine for this, so it selects and focuses nothing: it
    /// goes through the core rather than the in-app door, and the library is
    /// left showing whatever the user left it on.
    package func startAutomaticVMsForLaunch(_ marked: Set<UUID>) async {
        let results = await commands.startVMsMarkedToStartAutomatically(marked)
        guard !results.undone.isEmpty else { return }
        presenter?.presentStartSummary(title: Self.autoStartUndoneTitle, undone: results.undone)
    }

    /// What the launch pass heads its account of the VMs it left undone with.
    static let autoStartUndoneTitle = "Couldn\u{2019}t Start Every VM Set to Start When Kernova Opens"

    // MARK: - Error Handling

    /// Runs one verb, routing whatever it refuses with to the right surface.
    private func run(on instance: VMInstance, _ verb: () async throws -> Void) async {
        do {
            try await verb()
        } catch {
            present(error, about: .vm(instance))
        }
    }

    /// The synchronous counterpart of ``run(on:_:)``.
    private func runSync(on instance: VMInstance, _ verb: () throws -> Void) {
        do {
            try verb()
        } catch {
            present(error, about: .vm(instance))
        }
    }

    /// Runs one edit, routing refusals as ``runSync(on:_:)`` does but logging
    /// the failure a race raises instead of alerting on it, and handing a
    /// consent refusal back to the caller that gathers it.
    ///
    /// Two things reach here as
    /// ``CommandError/operationFailed(verb:title:message:recovery:)``: an edit
    /// naming an attachment the list no longer carries — a rename field
    /// committing after its row went, a second alert for a disk the first
    /// already removed — and a settings write the library has already told the
    /// user about. Both were silent before there was a verb to refuse them,
    /// and the verb throws so a wire client hears about it.
    @discardableResult
    private func runEdit(on instance: VMInstance, _ verb: () throws -> Void) -> EditOutcome {
        do {
            try verb()
            return .applied
        } catch {
            return route(error, ofEditOn: instance)
        }
    }

    /// The asynchronous counterpart of ``runEdit(on:_:)``.
    @discardableResult
    private func runEdit(on instance: VMInstance, _ verb: () async throws -> Void) async
        -> EditOutcome
    {
        do {
            try await verb()
            return .applied
        } catch {
            return route(error, ofEditOn: instance)
        }
    }

    /// Where ``runEdit(on:_:)`` sends what an edit threw.
    private func route(_ error: any Error, ofEditOn instance: VMInstance) -> EditOutcome {
        if let command = error as? CommandError {
            if let prompt = command.confirmationPrompt { return .consentRequired(prompt) }
            if command.isOperationFailure {
                #log(
                    Self.logger, .debug,
                    "Edit on '\(instance.name, privacy: .public)' did not apply: \(command.message, privacy: .public)"
                )
                return .refused
            }
        }
        present(error, about: .vm(instance))
        return .refused
    }

    /// Shows a refusal nobody is waiting for.
    ///
    /// A `kernova:` link has no caller to answer to, so the app is where its
    /// refusal lands — through the same routing every in-app refusal takes, so
    /// a refusal raised before any window can show it waits for one.
    package func surfaceUnawaitedFailure(_ failure: CommandError) {
        present(failure, about: .library)
    }

    /// The single place an error about `subject` becomes something on screen.
    ///
    /// A consent refusal opens the sheet that gathers it; a failure carrying a
    /// recovery opens the alert that offers it; everything else is an error
    /// alert headed by the refusal's own title — a ``TitledError``'s, or
    /// "Error".
    func present(_ error: Error, about subject: AlertSubject) {
        guard let command = error as? CommandError else {
            surfaceError(
                error.localizedDescription, title: (error as? any TitledError)?.alertTitle ?? "Error",
                about: subject)
            return
        }
        switch (command, subject) {
        case (.confirmationRequired(let prompt), .vm(let instance)):
            presentConfirmation(prompt, for: instance)
        case (.confirmationRequired(let prompt), .library):
            #log(
                Self.logger, .debug,
                "No sheet to raise for an unconsented \(prompt.kind.rawValue, privacy: .public) about no VM"
            )
        case (.operationFailed(_, _, _, .removeStartFailedAttachment(let failure)?), .vm(let instance)):
            presenter?.presentStartFailedAttachment(failure, for: instance)
        case (.operationFailed(.start, _, let message, _), .vm(let instance)):
            presenter?.presentStartFailure(message, title: command.alertTitle, for: instance)
        case (.operationFailed(_, _, let message, _), _):
            surfaceError(message, title: command.alertTitle, about: subject)
        default:
            surfaceError(command.message, title: command.alertTitle, about: subject)
        }
    }

    /// Opens the sheet that gathers the consent a refusal is asking for.
    ///
    /// A Stop the user asked for that only the core can tell is destructive
    /// opens one: a suspended VM whose stop discards its saved state. A start beside a VM sharing its machine identity
    /// arrives here only when it could not be asked (``runAsking(on:then:_:)``),
    /// and is shown as the refusal it stands for. Every other confirmation is
    /// raised by the `request…` method that opens its own sheet and knows the
    /// arguments — which VM, which snapshot, Trash or immediate — that the
    /// prompt alone does not carry.
    private func presentConfirmation(_ prompt: ConfirmationPrompt, for instance: VMInstance) {
        switch prompt.kind {
        case .forceStop:
            presenter?.presentForceStop(for: instance)
        case .startBesideSharedMachineIdentity:
            // Raised where it could not be asked: the refusal it stands for.
            surfaceError(prompt.message, title: ConflictReason.machineIdentity.title, about: .vm(instance))
        default:
            #log(
                Self.logger, .debug,
                "No sheet to raise for an unconsented \(prompt.kind.rawValue, privacy: .public)"
            )
        }
    }

    /// Routes an error message composed upstream to the presenter; an `Error`
    /// goes through ``present(_:about:)`` instead.
    func surfaceError(_ message: String, title: String, about subject: AlertSubject) {
        presenter?.presentError(message, title: title, about: subject)
    }
}
