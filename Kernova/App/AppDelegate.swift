import Cocoa
import Darwin
import KernovaKit
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    /// Whether this process is the unit-test host.
    ///
    /// `true` for the `BUNDLE_LOADER` test host — a plain foreground app that
    /// idle-terminates, with none of the resident-app machinery (status item,
    /// login-item registration, activation-policy switching).
    private let isTestHost: Bool
    /// App-wide preferences (the single DI seam for `UserDefaults`-backed state).
    private let preferences: AppPreferences
    private var mainWindowController: MainWindowController?
    private let viewModel: VMLibraryViewModel
    /// The library's first read from disk, started in
    /// `applicationWillFinishLaunching`.
    ///
    /// Retained so `application(_:open:)` can wait for it: a Finder open that
    /// launched the app is delivered while the read is still in flight.
    private var libraryLoad: Task<Void, Never>?
    /// The launch pass that brings up the VMs marked to start automatically.
    ///
    /// Retained so a quit can cancel it: the pass outlives the library read, and
    /// left running it would keep starting *further* guests behind the
    /// termination save pass. Cancelling bounds the pass to the VMs it has
    /// already reached — the one inside VZ at that moment still finishes, and a
    /// quit does not wait on a `.starting` VM.
    private var autoStartPass: Task<Void, Never>?
    private var clipboardWindows: [UUID: ClipboardWindowController] = [:]
    private var clipboardObservers: [UUID: Any] = [:]
    private var displayWindows: [UUID: VMDisplayWindowController] = [:]
    private var displayWindowObservers: [UUID: Any] = [:]
    private var terminationObservation: ObservationLoop?
    /// Watches the residency toggle so the status item and the reconcile follow it
    /// live. Resident app only.
    private var residencyObservation: ObservationLoop?
    /// Latched once the reconcile has asked to terminate, so a window closing
    /// during the async save can't request a second termination.
    private var isQuittingOnLastWindowClose = false
    /// Latched once the termination gate has replied `.terminateLater`, so a
    /// second quit can't start a second save pass: its `trySave` would come back
    /// as `operationInProgress` and the catch would force-stop a VM mid-save.
    ///
    /// Never reset, matching the quit flags below: every later quit defers to the
    /// pass, which always replies and terminates the app.
    private var isRunningTerminationSavePass = false
    private let clipboardMenuItem: NSMenuItem
    private var settingsWindowController: SettingsWindowController?

    /// The application menu, retained so its quit section can be rebuilt when it opens.
    private var appMenu: NSMenu?
    /// The quit-section items currently installed in `appMenu`, tracked so a
    /// rebuild removes exactly what it added.
    private var appMenuQuitItemViews: [NSMenuItem] = []
    /// The model `appMenuQuitItemViews` was last built from, so a rebuild that
    /// would produce identical items is skipped.
    private var appMenuQuitModel: [AppMenuQuitItem] = []

    /// Single close-side trigger for the activation-policy reconcile.
    ///
    /// Fires `scheduleAgentActivationPolicySync()` when a titled window closes,
    /// tracked or not (e.g. the standard About panel) — the only closes that can
    /// change `hasVisibleUserWindow` (`windowCloseAffectsActivationPolicy`).
    /// Resident app only.
    private var globalWindowCloseObserver: Any?

    /// The menu-bar status item — the "Kernova is running" affordance and the way
    /// to summon the GUI while headless.
    ///
    /// Resident app only, and present exactly while *Continue running in Status
    /// Bar* is on (`syncStatusItem`).
    private var statusItemController: HostAgentStatusItemController?

    /// Set in `applicationWillBecomeActive` and read in `applicationShouldHandleReopen`
    /// to distinguish a dock click that activates the app from one on an already-active app.
    ///
    /// Cleared synchronously in `applicationShouldHandleReopen` as well as
    /// asynchronously, so rapid successive dock clicks can't read a stale `true`
    /// before the async clear runs.
    private var wasJustActivated = false

    /// Set by `handleQuitAppleEvent` when the sender is System Settings / TCC.
    private var terminationIsTCCRevocation = false

    /// Set in `applicationShouldTerminate` when TCC revocation is detected AND
    /// running VMs require an async save (`.terminateLater`).
    private var relaunchAfterTermination = false

    /// Set by the true-quit affordances (the status item's Quit, the app menu's
    /// "Quit Kernova") so `applicationShouldTerminate` proceeds instead of
    /// downgrading the quit to a GUI close.
    private var userRequestedAgentQuit = false

    /// Set by `handleQuitAppleEvent` via `classifyQuit` whenever an external quit
    /// Apple Event must actually terminate the agent rather than downgrade to a
    /// GUI close, short of a TCC revocation.
    ///
    /// Latches for every sender `classifyQuit` maps to `.terminateAndSave`: a
    /// system quit must never leave the system waiting on the agent at logout, a
    /// programmatic quit is explicit and honored, and an unattributable sender
    /// fails toward saving state rather than vetoing a possible power-off.
    private var externalQuitRequiresTermination = false

    /// Whether a pending quit should actually terminate the resident app.
    ///
    /// While *Continue running in Status Bar* is on (the default), GUI-origin quits (⌘Q,
    /// "Close All Windows", the Dock's Quit) only close the GUI and leave the app
    /// resident with its VMs running headless. Only consulted for the resident
    /// app, not the test host.
    private var quitShouldTerminateAgent: Bool {
        userRequestedAgentQuit || externalQuitRequiresTermination || terminationIsTCCRevocation
            || !viewModel.keepInMenuBarOnQuit
    }

    /// Bundle identifiers that indicate a TCC-initiated quit.
    private nonisolated static let tccSenderBundleIDs: Set<String> = [
        "com.apple.settings.PrivacySecurity.extension"
    ]

    /// Bundle identifiers whose quit means the whole session is ending.
    ///
    /// `loginwindow` sends each app a `kAEQuitApplication` event as it tears the
    /// session down (logout / restart / shutdown); that quit must terminate the
    /// agent, never be downgraded to a GUI close.
    private nonisolated static let systemQuitSenderBundleIDs: Set<String> = [
        "com.apple.loginwindow"
    ]

    /// Bundle identifiers of user-facing quit affordances that must be treated
    /// like ⌘Q — a soft quit that downgrades to a GUI close, never a real
    /// termination.
    ///
    /// The Dock's "Quit" delivers a `kAEQuitApplication` event from
    /// `com.apple.dock`.
    private nonisolated static let dockSenderBundleIDs: Set<String> = [
        "com.apple.dock"
    ]

    /// The outcome `classifyQuit` assigns to a quit Apple Event's sender.
    enum QuitClassification: Equatable {
        /// Close the GUI only; the agent stays resident with VMs running headless.
        case stayResident
        /// Terminate the agent and save-suspend running VMs.
        case terminateAndSave
        /// Terminate the agent, save-suspend running VMs, and relaunch after exit
        /// (TCC revocation — see `terminationIsTCCRevocation`).
        case terminateAndRelaunch
    }

    /// Classifies a quit Apple Event by its sender PID, in isolation from the AE
    /// itself so the full matrix is unit-testable with injected probes.
    ///
    /// The governing principle: user-facing quit affordances soft-quit;
    /// programmatic and external quits are honored as real quits, and an
    /// unattributable sender fails safe toward termination.
    nonisolated static func classifyQuit(
        senderPID: pid_t?,
        bundleIDResolver: (pid_t) -> String?,
        isProcessAlive: (pid_t) -> Bool
    ) -> QuitClassification {
        // A non-positive PID targets a process group, not a single process, so it
        // can't be probed the same way: unattributable.
        guard let senderPID, senderPID > 0 else { return .terminateAndSave }

        guard isProcessAlive(senderPID) else { return .terminateAndSave }

        if senderPID == getpid() { return .stayResident }

        // Live sender with no resolvable bundle ID (e.g. `osascript` running an
        // AppleScript `quit`) — a programmatic quit; honor it.
        guard let bundleID = bundleIDResolver(senderPID) else { return .terminateAndSave }

        if tccSenderBundleIDs.contains(bundleID) { return .terminateAndRelaunch }
        if systemQuitSenderBundleIDs.contains(bundleID) { return .terminateAndSave }
        // The Dock's Quit is a user-facing affordance — soft-quit like ⌘Q.
        if dockSenderBundleIDs.contains(bundleID) { return .stayResident }
        return .terminateAndSave
    }

    /// One item in the app menu's quit section, as decided by `appMenuQuitItems`.
    struct AppMenuQuitItem: Equatable {
        /// What invoking the item does.
        enum Action: Equatable {
            /// Routes through `NSApplication.terminate(_:)` and thus the
            /// `applicationShouldTerminate` gate.
            case terminateThroughGate
            /// Requests an unconditional full quit, bypassing the
            /// keep-in-menu-bar downgrade.
            case quitCompletely
        }

        let title: String
        /// The key-equivalent character (always `"q"`; ⌘ is always part of the shortcut).
        let keyEquivalent: String
        /// Whether Option joins Command: `false` = ⌘Q, `true` = ⌥⌘Q.
        let usesOptionModifier: Bool
        let action: Action
    }

    /// Decides the app menu's quit-section items, so every state presents an
    /// honest command.
    ///
    /// The resident app with keep-in-menu-bar on gets the honest split — "Close
    /// All Windows" (⌘Q) plus the true "Quit Kernova" (⌥⌘Q); every other mode
    /// gets a single ⌘Q that really quits.
    nonisolated static func appMenuQuitItems(
        isTestHost: Bool, keepInMenuBar: Bool
    ) -> [AppMenuQuitItem] {
        if !isTestHost && keepInMenuBar {
            return [
                AppMenuQuitItem(
                    title: "Close All Windows", keyEquivalent: "q",
                    usesOptionModifier: false, action: .terminateThroughGate),
                AppMenuQuitItem(
                    title: "Quit Kernova", keyEquivalent: "q",
                    usesOptionModifier: true, action: .quitCompletely),
            ]
        }
        return [
            AppMenuQuitItem(
                title: "Quit Kernova", keyEquivalent: "q",
                usesOptionModifier: false, action: .terminateThroughGate)
        ]
    }

    private static let logger = Logger(subsystem: "app.kernova", category: "AppDelegate")
    private static let guestAgentDiskPath: String? = {
        guard
            let path = Bundle.main.url(forResource: "KernovaMacOSAgent", withExtension: "dmg")?.path(
                percentEncoded: false)
        else {
            logger.warning("Guest agent disk image not found in app bundle — 'Install Guest Agent' will be unavailable")
            return nil
        }
        return path
    }()

    /// Returns the VM that menu actions should target: the display or clipboard
    /// window's VM if its window is key, otherwise the sidebar-selected VM.
    private var activeInstance: VMInstance? {
        if let keyWindow = NSApp.keyWindow {
            if let controller = displayWindows.values.first(where: { $0.window === keyWindow }) {
                return controller.instance
            }
            if let controller = clipboardWindows.values.first(where: { $0.window === keyWindow }) {
                return controller.instance
            }
        }
        return viewModel.selectedInstance
    }

    // MARK: - Entry Point

    static func main() {
        let isTestHost = ProcessInfo.processInfo.isRunningXCTests
        let app = NSApplication.shared

        // `NSApplication.delegate` is weak, so the local binding retains the
        // delegate for the process lifetime (`run()` never returns).
        let delegate = AppDelegate(isTestHost: isTestHost)
        app.delegate = delegate
        app.run()
    }

    init(isTestHost: Bool, preferences: AppPreferences = .shared) {
        self.isTestHost = isTestHost
        self.preferences = preferences
        self.viewModel = VMLibraryViewModel()

        let clipboardItem = NSMenuItem(
            title: "Clipboard",
            action: #selector(showClipboard(_:)),
            keyEquivalent: "v"
        )
        clipboardItem.keyEquivalentModifierMask = [.command, .shift]
        self.clipboardMenuItem = clipboardItem

        super.init()

        viewModel.onOpenDisplayWindow = { [weak self] instance in
            self?.openDisplayWindow(for: instance)
        }
        viewModel.displayBootGeometryProvider = self
    }

    // MARK: - NSApplicationDelegate

    /// Starts the library read.
    ///
    /// Deliberately here and not in `applicationDidFinishLaunching`: AppKit
    /// delivers a launch document's `application(_:open:)` *between* the two, and
    /// that path waits on `libraryLoad` — left unset, the wait would silently
    /// pass through and re-import a bundle already in the library. Starting the
    /// read costs nothing here; the task body only runs once the main actor
    /// yields, and its file I/O is off the main actor either way.
    func applicationWillFinishLaunching(_ notification: Notification) {
        libraryLoad = Task { @MainActor [viewModel] in await viewModel.startLibrary() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        // Reclaim orphaned clipboard staging files from a previous run or crash —
        // every label family under the shared parent (`host`, per-VM `host-<vm>`
        // receive roots, `host-send-<vm>` outbound-archive roots). The staged file
        // URL must outlive the clipboard window (paste-after-close), so staging
        // never sweeps on close — only here, before any clipboard use.
        ClipboardFileStaging.reclaimAll()

        // Intercept the Quit Apple Event so `classifyQuit` can inspect its sender.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )

        if isTestHost {
            // None of the resident-app machinery (status item, activation-policy
            // switching) runs in the test host, so CI unit tests never register
            // login items.
            let windowController = MainWindowController(viewModel: viewModel)
            windowController.showWindow(nil)
            mainWindowController = windowController
            observeForTermination()
        } else {
            startResidentApp()
        }
    }

    // MARK: - Resident App

    /// Brings up the resident app with its library window on screen.
    ///
    /// VMs appear at their last-logout state, except those marked
    /// `VMConfiguration.startsAutomaticallyOnLaunch`, which come up once the
    /// library read lands. Idle termination is not armed: while *Continue running
    /// in Status Bar* is on the app stays resident until an explicit Quit, with
    /// any running VMs executing headless.
    private func startResidentApp() {
        syncStatusItem()
        observeResidencyPreference()

        globalWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard let self, Self.windowCloseAffectsActivationPolicy(window) else { return }
                // A pop-in restores the library as part of the same close and
                // reconciles itself afterwards. A second reconcile scheduled here
                // runs before that restore, sees no window on screen, and would
                // quit the app instead of popping the display back in.
                guard !self.isPoppingIn(window) else { return }
                self.scheduleAgentActivationPolicySync()
            }
        }

        let provenance = Self.residentProvenanceLine(
            bundlePath: Bundle.main.bundlePath,
            build: Self.buildNumber,
            configuration: Self.buildConfiguration,
            vmNetworkingEntitled: EntitlementService.shared.hasVMNetworking)
        Self.logger.notice("Kernova resident app ready — \(provenance, privacy: .public)")

        summonUserInterface()

        // After the summon, not before: its deferred window show runs while the
        // library read is still doing its off-main-actor file I/O, so a VM
        // booting here finds the measurable surface `applyMatchWindowBootResolution`
        // needs. The marked VMs only exist in `instances` once that read applies.
        autoStartPass = Task { @MainActor in
            await self.libraryLoad?.value
            await self.viewModel.startAutomaticVMsForLaunch()
        }
    }

    /// Builds the menu-bar status item.
    ///
    /// Extracted from `startResidentApp` so `syncStatusItem` can rebuild it when
    /// the residency toggle flips back on.
    private func makeStatusItemController() -> HostAgentStatusItemController {
        HostAgentStatusItemController(
            viewModel: viewModel,
            preferences: preferences,
            onOpen: { [weak self] vmID in self?.summonStatusItemTarget(for: vmID) },
            onOpenClipboard: { [weak self] vmID in
                guard let self else { return }
                guard
                    let instance = self.viewModel.instances.first(where: { $0.instanceID == vmID }),
                    instance.canShowClipboard
                else {
                    // The window the notice pointed at can't open — the VM has
                    // stopped, had sharing turned off, or is gone from the
                    // library. Land on its usual surface rather than nowhere.
                    self.summonStatusItemTarget(for: vmID)
                    return
                }
                self.viewModel.selectedID = vmID
                self.summonUserInterface(showing: .clipboard(instance))
            },
            onQuit: { [weak self] in self?.requestFullQuit() }
        )
    }

    /// Creates or removes the status item so it exists exactly while
    /// *Continue running in Status Bar* is on.
    ///
    /// Idempotent, so the observation loop can call it on every wake.
    private func syncStatusItem() {
        guard !isTestHost else { return }
        if viewModel.keepInMenuBarOnQuit {
            guard statusItemController == nil else { return }
            statusItemController = makeStatusItemController()
        } else {
            statusItemController?.tearDown()
            statusItemController = nil
        }
    }

    /// Reacts to the residency toggle: the status item appears and disappears
    /// with it, and the reconcile re-runs because the toggle changes what a
    /// windowless app should do.
    private func observeResidencyPreference() {
        residencyObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                _ = self.viewModel.keepInMenuBarOnQuit
                // Work settling lifts the hold in `residencyOutcome`, so the
                // reconcile has to re-run when the last of it clears.
                _ = self.viewModel.hasUninterruptibleWork
            },
            apply: { [weak self] in
                self?.syncStatusItem()
                self?.syncAgentActivationPolicy()
            }
        )
    }

    #if DEBUG
    private static let buildConfiguration = "Debug"
    #else
    private static let buildConfiguration = "Release"
    #endif

    /// The build number, substituted into Info.plist at build time by
    /// `Tools/set-build-number.sh` — a missing value is a build misconfiguration.
    private static let buildNumber: String = {
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            logger.fault("CFBundleVersion not found in Info.plist")
            assertionFailure("CFBundleVersion not found in Info.plist")
            return "?"
        }
        return build
    }()

    /// Formats the resident-app startup provenance line.
    nonisolated static func residentProvenanceLine(
        bundlePath: String, build: String, configuration: String, vmNetworkingEntitled: Bool
    ) -> String {
        "bundle=\(bundlePath) build=\(build) config=\(configuration) "
            + "vmNetworking=\(vmNetworkingEntitled ? "entitled" : "unentitled")"
    }

    /// What a GUI summon puts on screen.
    private enum SummonTarget {
        /// The library window — the default surface.
        case library
        /// One VM's dedicated display window (pop-out or fullscreen, per its
        /// `displayPreference`), and nothing else.
        case display(VMInstance)
        /// One VM's clipboard window, and nothing else.
        case clipboard(VMInstance)
    }

    /// Summons the surface the status item's per-VM commands land on: the VM's
    /// own display window when it can present one, else the library.
    ///
    /// A `nil` or unknown id opens the library, which is where a VM that has left
    /// the library is looked for.
    private func summonStatusItemTarget(for vmID: UUID?) {
        guard
            let instance = vmID.flatMap({ id in
                viewModel.instances.first(where: { $0.instanceID == id })
            })
        else {
            summonUserInterface()
            return
        }
        viewModel.selectedID = instance.instanceID
        switch Self.statusItemOpenTarget(
            displayPreference: instance.configuration.displayPreference,
            canUseExternalDisplay: instance.canUseExternalDisplay)
        {
        case .displayWindow:
            summonUserInterface(showing: .display(instance))
        case .library:
            summonUserInterface()
        }
    }

    /// Where the status item's per-VM open command lands, as decided by
    /// `statusItemOpenTarget`.
    enum StatusItemOpenTarget: Equatable {
        /// Show the library window, selected on the VM.
        case library
        /// Open only the VM's dedicated display window.
        case displayWindow
    }

    /// Decides what clicking a VM in the status-item dropdown opens: its own
    /// display window when the VM's preference is pop-out or fullscreen and it can
    /// present one, else the library.
    ///
    /// Deliberately opens *only* the chosen surface — summoning one VM must not
    /// drag the library or other VMs' windows back on screen, and summoning the
    /// library ("Open Kernova") must not restore any display windows.
    nonisolated static func statusItemOpenTarget(
        displayPreference: VMDisplayPreference, canUseExternalDisplay: Bool
    ) -> StatusItemOpenTarget {
        displayPreference != .inline && canUseExternalDisplay ? .displayWindow : .library
    }

    /// Brings the resident app's GUI forward: morph to `.regular`, then activate
    /// and show the summoned surface.
    ///
    /// The sole GUI-summon path, and idempotent.
    private func summonUserInterface(showing target: SummonTarget = .library) {
        // Morph to a regular app so the Dock icon + menu bar appear. Defer the
        // activate + show to the next runloop tick so the menu bar has refreshed
        // (the .accessory→.regular menu-bar quirk, FB7743313).
        setAgentActivationPolicy(.regular)
        Task { @MainActor in
            Self.logger.debug("Summon: isActive=\(NSApp.isActive, privacy: .public)")
            // A summon out of the headless `.accessory` state fronts an
            // unactivated background process, and `ignoringOtherApps` is what
            // does that — the argument-less `activate()` is unreliable there. A
            // no-op when the app is already frontmost.
            NSApp.activate(ignoringOtherApps: true)
            switch target {
            case .library:
                self.showLibraryWindow(bringToFront: true)
            case .display(let instance):
                if let existing = self.displayWindows[instance.instanceID] {
                    existing.window?.makeKeyAndOrderFront(nil)
                } else {
                    self.openDisplayWindow(for: instance)
                }
            case .clipboard(let instance):
                self.showClipboardWindow(for: instance)
            }
            // Summoning from the status-item menu leaves the freshly-appeared menu
            // bar with its first menu highlighted: the status menu's dismissal
            // bleeds into the menu bar the morph just installed. Clear it.
            NSApp.mainMenu?.cancelTracking()
            await self.reassertActivationAfterSummon()
        }
    }

    /// Re-requests activation until the summon's activation sticks.
    ///
    /// Cooperative activation (macOS 14+) occasionally denies the summon's
    /// `activate`: the request lands milliseconds after the `.accessory` →
    /// `.regular` morph, and when it loses that race the previously active app
    /// keeps focus — the summoned window surfaces behind it and the Dock,
    /// never seeing an activation, leaves the app at the ⌘-Tab tail. Poll and
    /// re-assert until activation sticks, bounded to three attempts so a
    /// denied activation isn't re-requested indefinitely.
    private func reassertActivationAfterSummon() async {
        for attempt in 1...3 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !NSApp.isActive else { return }
            Self.logger.debug(
                "Summon: activation denied, re-asserting (attempt \(attempt, privacy: .public))")
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Re-asserts `.regular` before a window is shown, so a window can never be
    /// presented while the resident app is still headless `.accessory`.
    ///
    /// No-op in the test host, which is always `.regular`.
    private func ensureRegularActivationIfAgent() {
        guard !isTestHost else { return }
        setAgentActivationPolicy(.regular)
    }

    /// Whether any user-facing Kernova window is currently on screen.
    ///
    /// The Dock icon (`.regular`) must be present iff this is `true`.
    private var hasVisibleUserWindow: Bool {
        // Deliberately does NOT special-case `NSApp.isHidden`: plain ⌘H closes no
        // window, so no reconcile fires and the Dock icon persists. Forcing
        // `.regular` while hidden strands the agent with a Dock icon and zero
        // windows when a background close (a VM shutting down empties the last
        // display window mid-hide) fires the reconcile.
        func onScreen(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            return window.isVisible || window.isMiniaturized
        }
        if onScreen(mainWindowController?.window) { return true }
        if displayWindows.values.contains(where: { onScreen($0.window) }) { return true }
        if clipboardWindows.values.contains(where: { onScreen($0.window) }) { return true }
        if onScreen(settingsWindowController?.window) { return true }
        // Untracked AppKit-owned panels are genuine on-screen windows: count them
        // so a reconcile can't strip the Dock icon while one is the last visible.
        if NSApp.windows.contains(where: Self.isUntrackedUserPanel) { return true }
        return false
    }

    /// Whether `window` is a display window closing because the user popped it
    /// back into the library, which owns the reconcile for that close.
    private func isPoppingIn(_ window: NSWindow) -> Bool {
        displayWindows.values.contains { $0.window === window && $0.closeReason == .popIn }
    }

    /// Whether closing `window` can change what `hasVisibleUserWindow` returns,
    /// so the close must run the activation-policy reconcile.
    ///
    /// Every window `hasVisibleUserWindow` counts is titled, so a borderless
    /// close (a dismissing status-item menu, a tooltip) never changes the
    /// answer — and must not run the reconcile: the status menu dismisses
    /// *before* its action fires, so its close otherwise lands a reconcile
    /// between the summon's `.regular` morph and the deferred window show,
    /// flipping the app back to `.accessory` mid-summon. The activate then
    /// fires while the app is `.accessory`, and the re-morph re-appends it to
    /// the ⌘-Tab switcher's tail with no activation event after it — leaving
    /// the freshly summoned app last in ⌘-Tab.
    static func windowCloseAffectsActivationPolicy(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled)
    }

    /// Whether `window` is an untracked, AppKit-owned top-level panel whose
    /// presence must keep the Dock icon.
    ///
    /// The standard About panel is the motivating example. The visible +
    /// normal-level + titled filter excludes chrome: the status item's backing
    /// `NSStatusBarWindow` is borderless and sits above `.normal`, so an
    /// unfiltered `NSApp.windows` scan would pin the agent to `.regular` forever.
    static func isUntrackedUserPanel(_ window: NSWindow) -> Bool {
        (window.isVisible || window.isMiniaturized)
            && window.level == .normal
            && window.styleMask.contains(.titled)
    }

    /// What the window reconcile does with the resident app.
    enum ResidencyOutcome: Equatable {
        /// Show the Dock icon — a user window is on screen.
        case showDockIcon
        /// Drop to a status-item-only app; running VMs keep executing.
        case goHeadless
        /// Quit through `applicationShouldTerminate`, save-suspending running VMs.
        case quit
    }

    /// Decides the reconcile's outcome.
    ///
    /// With *Continue running in Status Bar* off there is neither a Dock icon nor
    /// a status item, so a headless app would be unreachable — the last window
    /// close quits instead of demoting.
    ///
    /// Two things hold that quit back:
    ///
    /// - **Hiding.** ⌘H makes every window report `isVisible == false` without
    ///   closing any of them, so a background close landing mid-hide (a VM
    ///   shutting down empties its display window) reads as "no windows" while
    ///   the library is still open. Quitting there would discard windows the user
    ///   never closed.
    /// - **Work in flight.** Termination trashes partial bundles
    ///   (`cancelAndCleanupPreparingInstances`) and hard-aborts a VM that is
    ///   mid-save, mid-restore, mid-start or mid-install — `applicationShouldTerminate`
    ///   only save-suspends VMs already settled at `.running` or `.paused`. An
    ///   ordinary window close must not destroy that work, so it keeps the Dock
    ///   icon (not headless — the app has to stay reachable to show progress)
    ///   until the work settles and the observation re-runs this.
    ///
    /// A settled `.running` VM deliberately does *not* hold the quit back:
    /// save-suspending it is the decided behavior.
    nonisolated static func residencyOutcome(
        hasVisibleUserWindow: Bool,
        isHidden: Bool,
        keepInMenuBar: Bool,
        hasUninterruptibleWork: Bool
    ) -> ResidencyOutcome {
        if hasVisibleUserWindow { return .showDockIcon }
        if keepInMenuBar || isHidden { return .goHeadless }
        if hasUninterruptibleWork { return .showDockIcon }
        return .quit
    }

    /// What the termination gate does with a quit request.
    enum TerminationOutcome: Equatable {
        /// Downgrade the quit to a GUI close; the app stays resident.
        case closeGUI
        /// Wait on the save pass already running, without starting a second one.
        case deferToSavePass
        /// Nothing to save and nothing to wait out.
        case terminateNow
        /// Reply later: wait out every in-flight save, then save-suspend whatever
        /// is still live.
        case saveThenTerminate
    }

    /// Decides the termination gate's reply.
    ///
    /// A save already in flight forces the deferred reply even when the gate has
    /// nothing of its own to save: `VZVirtualMachine.saveMachineStateTo` writes
    /// the save file in place, so exiting through it truncates the file. The
    /// window reconcile answers a different question with
    /// `hasUninterruptibleWork` — it may defer a quit nobody asked for
    /// indefinitely, where an explicit quit may only wait out what termination
    /// would corrupt.
    ///
    /// A running save pass outranks the soft-quit downgrade: the app is already
    /// on its way out, so closing the GUI and telling the user it stays resident
    /// would be false.
    nonisolated static func terminationOutcome(
        shouldTerminateAgent: Bool,
        isSavePassRunning: Bool,
        hasSaveInFlight: Bool,
        hasInstancesToSave: Bool
    ) -> TerminationOutcome {
        if isSavePassRunning { return .deferToSavePass }
        guard shouldTerminateAgent else { return .closeGUI }
        if hasSaveInFlight || hasInstancesToSave { return .saveThenTerminate }
        return .terminateNow
    }

    /// What the termination save pass does with one VM it has selected.
    enum TerminationSaveStep: Equatable {
        /// Hold until the lifecycle operation on this VM finishes, then re-decide.
        case waitForOperation
        /// Save-suspend it now.
        case save
        /// Leave it alone.
        case skip
    }

    /// Decides the pass's next move for one VM.
    ///
    /// ``VMStatus`` cannot tell a settling pause or resume from a settled VM —
    /// both hold `.running` / `.paused` for the whole `vm.pause()` /
    /// `vm.resume()` await — so the operation's own lifetime is what decides,
    /// and a save issued against a held VM comes back as
    /// ``VMLifecycleCoordinator/LifecycleError/operationInProgress``.
    ///
    /// The signal is ``VMLifecycleCoordinator/hasUnsettledOperation(for:)``
    /// rather than the claim: a Stop arriving mid-wait releases the claim while
    /// the pause it interrupted is still inside VZ, and saving there would issue
    /// a second VZ operation on a busy VM.
    ///
    /// `hasLiveSession` is what bounds the wait: `.installing`, `.starting` and
    /// `.restoring` all fail it, so the operations that run for minutes are
    /// skipped rather than waited on and can never hold a quit.
    nonisolated static func terminationSaveStep(
        hasLiveSession: Bool,
        hasUnsettledOperation: Bool
    ) -> TerminationSaveStep {
        guard hasLiveSession else { return .skip }
        return hasUnsettledOperation ? .waitForOperation : .save
    }

    /// Reconciles the resident app with its open windows: `.regular` (Dock icon)
    /// while any user window is on screen, and when none are, either `.accessory`
    /// (status-item only) or a quit — see `residencyOutcome`.
    ///
    /// Re-run on every window open and close so a partial close can never strand
    /// the policy. No-op in the test host.
    private func syncAgentActivationPolicy() {
        guard !isTestHost else { return }
        switch Self.residencyOutcome(
            hasVisibleUserWindow: hasVisibleUserWindow,
            isHidden: NSApp.isHidden,
            keepInMenuBar: viewModel.keepInMenuBarOnQuit,
            hasUninterruptibleWork: viewModel.hasUninterruptibleWork
        ) {
        case .showDockIcon:
            setAgentActivationPolicy(.regular)
        case .goHeadless:
            setAgentActivationPolicy(.accessory)
        case .quit:
            // Latched: `applicationShouldTerminate` replies `.terminateLater` while
            // VMs save, and a window closing during that window would otherwise
            // re-enter with a reply already outstanding.
            guard !isQuittingOnLastWindowClose else { return }
            isQuittingOnLastWindowClose = true
            Self.logger.notice("Last window closed with the app set to quit — terminating")
            NSApp.terminate(nil)
        }
    }

    /// Re-runs `syncAgentActivationPolicy` on the next runloop tick — after a
    /// closing window has left the window list — so the window count is accurate.
    private func scheduleAgentActivationPolicySync() {
        guard !isTestHost else { return }
        Task { @MainActor in self.syncAgentActivationPolicy() }
    }

    /// Sets the activation policy, logging the transition.
    ///
    /// No-op when already at `policy`.
    private func setAgentActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        let current = NSApp.activationPolicy()
        guard current != policy else { return }
        NSApp.setActivationPolicy(policy)
        Self.logger.notice(
            "Activation policy \(current.rawValue, privacy: .public) → \(policy.rawValue, privacy: .public) (hasVisibleWindow=\(self.hasVisibleUserWindow, privacy: .public))"
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Resident app: the global `willClose` observer's reconcile decides
        // between the Dock icon, a headless status-item app, and quitting. It
        // keys on `hasVisibleUserWindow`, which counts miniaturized windows and
        // untracked panels that AppKit's own last-window rule does not, so
        // letting AppKit terminate too would double-fire on a different
        // predicate.
        if !isTestHost {
            return false
        }

        let hasActiveVMs = viewModel.instances.contains(where: \.isKeepingAppAlive)

        if hasActiveVMs || !displayWindows.isEmpty {
            Self.logger.debug(
                "applicationShouldTerminateAfterLastWindowClosed: false (activeVMs=\(hasActiveVMs, privacy: .public), displayWindows=\(self.displayWindows.count, privacy: .public))"
            )
            return false
        }

        Self.logger.debug("applicationShouldTerminateAfterLastWindowClosed: true")
        return true
    }

    func applicationWillBecomeActive(_ notification: Notification) {
        Self.logger.debug("applicationWillBecomeActive: setting wasJustActivated")
        wasJustActivated = true
        // Clear after the current event cycle so the flag doesn't go stale for
        // non-dock activations (Cmd-Tab, clicking a window), where
        // `applicationShouldHandleReopen` is never called.
        Task { @MainActor [weak self] in
            self?.wasJustActivated = false
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A Finder reopen (double-click / Dock click / `open` routed to the
        // existing instance) summons the GUI, morphing `.accessory`→`.regular`
        // first.
        if !isTestHost {
            wasJustActivated = false
            summonUserInterface()
            return true
        }

        let justActivated = wasJustActivated
        wasJustActivated = false  // Synchronous clear — see wasJustActivated doc comment

        if !flag {
            showLibrary(nil)
        } else if !justActivated && isMainWindowDismissed {
            Self.logger.debug("applicationShouldHandleReopen: reopening dismissed library window")
            showLibrary(nil)
        } else if justActivated {
            Self.logger.debug("applicationShouldHandleReopen: suppressed (initial activation with visible windows)")
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Show Library", action: #selector(showLibrary(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Closes every user-facing window, returning the agent to its headless
    /// `.accessory` state.
    ///
    /// Display windows close as app-initiated dismissals so their handler returns
    /// `displayMode` to `.inline` (not the user-close `.hidden`) and leaves
    /// `displayPreference` intact. Collections are snapshotted because closing
    /// mutates them.
    private func closeAllGUIWindows() {
        for controller in Array(displayWindows.values) { controller.closeForAppDismissal() }
        for controller in Array(clipboardWindows.values) { controller.window?.close() }
        settingsWindowController?.window?.close()
        mainWindowController?.window?.close()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Every quit path funnels through `terminate:` and thus this method, so
        // this single gate covers them all — see `quitShouldTerminateAgent`.
        switch Self.terminationOutcome(
            shouldTerminateAgent: isTestHost || quitShouldTerminateAgent,
            isSavePassRunning: isRunningTerminationSavePass,
            hasSaveInFlight: viewModel.hasSaveInFlight,
            hasInstancesToSave: viewModel.instances.contains(where: \.hasLiveSession)
        ) {
        case .closeGUI:
            Self.logger.notice("GUI-origin quit — closing the GUI; app stays resident")
            // Defer so the close runs after this termination request is fully cancelled.
            Task { @MainActor in
                self.closeAllGUIWindows()
                // Settle the Dock-presence policy BEFORE anchoring the reminder.
                // Left to the deferred per-window reconciles, the popover is shown
                // first and the `.regular` → `.accessory` flip lands 20–75ms later,
                // which re-hosts the menu-bar status item and tears the
                // just-anchored popover down with it (observed: the reminder
                // flashed for a frame and vanished).
                self.syncAgentActivationPolicy()
                self.statusItemController?.showSoftQuitReminder()
            }
            return .terminateCancel

        case .deferToSavePass:
            // Deferred, never cancelled: a `.terminateCancel` here would report a
            // veto to whoever asked, and loginwindow reads that as the app
            // refusing a logout, restart, or shut down. `.terminateLater` runs a
            // nested wait instead, which the pass's single
            // `reply(toApplicationShouldTerminate:)` resolves.
            if terminationIsTCCRevocation {
                relaunchAfterTermination = true
            }
            Self.logger.notice("Quit requested while the termination save pass is running — deferring to it")
            return .terminateLater

        case .terminateNow:
            autoStartPass?.cancel()
            cancelAndCleanupPreparingInstances()
            return .terminateNow

        case .saveThenTerminate:
            // Before the save pass, so it never has to chase a guest the launch
            // pass brings up behind it.
            autoStartPass?.cancel()
            cancelAndCleanupPreparingInstances()
            // macOS quits and relaunches the app when a TCC permission is revoked, and
            // its built-in relaunch times out while VMs are saving. Mark for relaunch
            // so `applicationWillTerminate` launches the helper after saves complete.
            if terminationIsTCCRevocation {
                relaunchAfterTermination = true
            }
            isRunningTerminationSavePass = true
            Task { @MainActor in
                await self.runTerminationSavePass()
                // A drop/odoc delivered during the async save window above can register
                // a fresh phantom, so sweep again right before the deferred reply or
                // that bundle is orphaned on disk.
                self.cancelAndCleanupPreparingInstances()
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    /// Waits out every in-flight save, then save-suspends whatever is still live.
    ///
    /// One instance per iteration, tracked by id: a failed force-stop leaves the
    /// VM live, so re-selecting on state alone would loop forever, and marking a
    /// VM handled *before* its wait keeps that guarantee when a user-initiated
    /// operation keeps re-taking the lock.
    ///
    /// The wait at the top of each iteration covers a save the user starts on
    /// another VM while the pass runs — a `.saving` VM is never selected here
    /// (`.saving` fails `hasLiveSession`), so nothing else would stop the loop
    /// from breaking out and letting the process exit mid-write. The per-VM wait
    /// below covers the selected VM's own settling operation, per
    /// ``terminationSaveStep(hasLiveSession:hasActiveOperation:)``.
    private func runTerminationSavePass() async {
        var handled: Set<UUID> = []
        var savedCount = 0
        var failedCount = 0
        var skippedCount = 0
        while true {
            if viewModel.hasSaveInFlight {
                Self.logger.notice("Termination waiting on an in-flight save to settle")
                await waitForObservedChange { [viewModel] in !viewModel.hasSaveInFlight }
            }
            guard
                let instance = viewModel.instances.first(where: {
                    $0.hasLiveSession && !handled.contains($0.id)
                })
            else { break }
            handled.insert(instance.id)

            if step(for: instance) == .waitForOperation {
                Self.logger.notice(
                    "Termination waiting on a lifecycle operation for '\(instance.name, privacy: .public)' to settle"
                )
                // The liveness escape ends the wait when the operation leaves the
                // VM unsaveable — a failed pause landing on `.error`, or a Force
                // Stop whose `vm.stop()` tears the session down while the
                // interrupted operation is still inside VZ.
                await waitForObservedChange { [viewModel] in
                    !viewModel.lifecycle.hasUnsettledOperation(for: instance.id)
                        || !instance.hasLiveSession
                }
            }

            // Re-decided after the wait: a VM that is no longer live must not
            // reach `trySave`, whose generic failure path force-stops.
            switch step(for: instance) {
            case .save:
                if await saveForTermination(instance) {
                    savedCount += 1
                } else {
                    failedCount += 1
                }
            case .skip:
                Self.logger.notice(
                    "Termination skipping '\(instance.name, privacy: .public)': it is no longer a live session this pass can save"
                )
                skippedCount += 1
            case .waitForOperation:
                // A second operation took the lock while the first was being
                // waited out. One attempt per VM, so this one is not re-waited.
                Self.logger.warning(
                    "Termination skipping '\(instance.name, privacy: .public)': another lifecycle operation took it"
                )
                skippedCount += 1
            }
        }
        Self.logger.notice(
            "Termination save complete: \(savedCount, privacy: .public) saved, \(failedCount, privacy: .public) failed, \(skippedCount, privacy: .public) skipped"
        )
    }

    /// The pass's move for `instance`, read from live state.
    private func step(for instance: VMInstance) -> TerminationSaveStep {
        Self.terminationSaveStep(
            hasLiveSession: instance.hasLiveSession,
            hasUnsettledOperation: viewModel.lifecycle.hasUnsettledOperation(for: instance.id)
        )
    }

    /// Save-suspends one VM for termination, force-stopping it when the save
    /// fails so a half-live VM can't outlive the process.
    ///
    /// The pass waits an in-flight lifecycle operation out before calling this,
    /// so a rejection here is the residual race where a user-initiated operation
    /// takes the lock in between. It is left alone rather than force-stopped:
    /// force-stopping would abort an operation that is about to finish and
    /// discard the very guest state the pass exists to save, where letting the
    /// process exit costs the same RAM and nothing more.
    ///
    /// - Returns: `true` when the state was saved.
    private func saveForTermination(_ instance: VMInstance) async -> Bool {
        do {
            try await viewModel.trySave(instance)
            viewModel.saveConfiguration(for: instance)
            return true
        } catch VMLifecycleCoordinator.LifecycleError.operationInProgress {
            Self.logger.warning(
                "Skipped saving '\(instance.name, privacy: .public)' during termination: another lifecycle operation holds it"
            )
            return false
        } catch {
            Self.logger.error(
                "Failed to save '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
            )
            do {
                try await viewModel.tryForceStop(instance)
            } catch {
                Self.logger.error(
                    "Failed to force-stop '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
                )
            }
            return false
        }
    }

    /// Cancels every preparing instance's task and trashes its partial bundle.
    ///
    /// Best effort, since `FileManager.copyItem` isn't interruptible — the copy
    /// already in flight keeps writing until it finishes or fails on its own.
    private func cancelAndCleanupPreparingInstances() {
        viewModel.instances.removeAll { instance in
            guard instance.isPreparing else { return false }

            Self.logger.notice("Terminating: cancelling preparing operation for '\(instance.name, privacy: .public)'")
            instance.preparingState?.task.cancel()
            do {
                try FileManager.default.trashItem(at: instance.bundleURL, resultingItemURL: nil)
            } catch {
                Self.logger.warning(
                    "Failed to clean up partial bundle for '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
                )
            }
            return true
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if relaunchAfterTermination {
            launchRelaunchHelper()
        }
    }

    /// Handles the `kAEQuitApplication` Apple Event by classifying its sender.
    ///
    /// Flags are only ever set to `true` here, never reset to `false`: a `true`
    /// flag always drives the process toward actual termination on the same call
    /// that set it, so there is never a stale `true` left over. Resetting on
    /// `.stayResident` would let a later, unrelated GUI-origin quit clear the very
    /// flag an in-flight `.terminateLater` VM-save depends on.
    @objc private func handleQuitAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent _: NSAppleEventDescriptor
    ) {
        let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        // Resolved once and fed to `classifyQuit` as fixed values so the same
        // attribution result also drives the logging below. The two probes can't
        // collapse into one: `NSRunningApplication` alone reads a live non-GUI
        // sender like `osascript` as dead, and the Dock's stay-resident outcome
        // depends on being seen as alive *and* identifiable.
        let attributablePID: pid_t? = senderPID.flatMap { pid in
            guard pid > 0, kill(pid, 0) == 0 || errno != ESRCH else { return nil }
            return pid
        }
        let bundleID = attributablePID.flatMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }

        let classification = Self.classifyQuit(
            senderPID: senderPID,
            bundleIDResolver: { _ in bundleID },
            isProcessAlive: { _ in attributablePID != nil }
        )

        if let attributablePID {
            if let bundleID {
                Self.logger.debug(
                    "Quit Apple Event from PID \(attributablePID, privacy: .public) (bundle: \(bundleID, privacy: .public)) classified as \(String(describing: classification), privacy: .public)"
                )
            } else {
                Self.logger.warning(
                    "Quit Apple Event: sender PID \(attributablePID, privacy: .public) is alive but could not be resolved to an application with a bundle identifier — classified as \(String(describing: classification), privacy: .public)"
                )
            }
        } else {
            Self.logger.warning(
                "Quit Apple Event sender could not be attributed (PID \(senderPID.map(String.init) ?? "none", privacy: .public)) — failing safe to \(String(describing: classification), privacy: .public)"
            )
        }

        switch classification {
        case .stayResident:
            break
        case .terminateAndSave:
            externalQuitRequiresTermination = true
        case .terminateAndRelaunch:
            terminationIsTCCRevocation = true
        }

        NSApp.terminate(nil)
    }

    /// The app menu's honest "Quit Kernova" — an unconditional full quit,
    /// identical to the status item's Quit.
    @objc func quitCompletely(_ sender: Any?) {
        requestFullQuit()
    }

    /// The single "truly terminate the resident app" path: latch the
    /// authorized-quit flag so `applicationShouldTerminate` proceeds to the
    /// save-suspend path instead of downgrading to a GUI close, then terminate.
    private func requestFullQuit() {
        Self.logger.notice("User-requested full quit — terminating the resident app")
        userRequestedAgentQuit = true
        NSApp.terminate(nil)
    }

    /// Launches the relaunch helper, which monitors this process and re-opens the
    /// app after it terminates.
    ///
    /// Used for TCC revocations, where the built-in relaunch times out during VM save.
    private func launchRelaunchHelper() {
        guard
            let helperURL = Bundle.main.url(
                forAuxiliaryExecutable: "KernovaRelaunchHelper"
            )
        else {
            Self.logger.fault("Relaunch helper not found in app bundle")
            assertionFailure("Relaunch helper not found in app bundle")
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath

        do {
            let process = Process()
            process.executableURL = helperURL
            process.arguments = [String(pid), bundlePath]
            try process.run()
            Self.logger.notice("Launched relaunch helper (watching PID \(pid, privacy: .public))")
        } catch {
            Self.logger.error("Failed to launch relaunch helper: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Open URLs (Finder double-click / dock icon drop)

    func application(_ application: NSApplication, open urls: [URL]) {
        importVMs(from: urls)
        // A double-click while the app is already resident+headless gets no
        // activation-driven summon — macOS sends no reopen for a document open —
        // so surface the window here. The test host manages its own window.
        if !isTestHost {
            summonUserInterface()
        }
    }

    /// Filters to `.kernova` bundles and imports the batch, once the library is
    /// readable.
    ///
    /// The wait is what makes a Finder open of a bundle *already in the library*
    /// still resolve to "select the existing VM": a launch document arrives
    /// while the first read is in flight, and `importVMs(fromDroppedURLs:)`
    /// dedups by UUID against `instances` — against an empty library it would
    /// copy the bundle a second time instead. Awaiting a finished load resumes
    /// on the next tick, so an open arriving later is unaffected.
    ///
    /// `importVMs(fromDroppedURLs:)` then reserves every destination in the batch
    /// without suspending and runs the copies concurrently, so two overlapping
    /// triggers still see each other's phantoms.
    private func importVMs(from urls: [URL]) {
        Task { @MainActor in
            await self.libraryLoad?.value
            self.viewModel.importVMs(fromDroppedURLs: urls)
        }
    }

    // MARK: - Menu Actions

    @objc func newVM(_ sender: Any?) {
        showLibraryWindow(bringToFront: true)
        viewModel.presenter?.presentCreationWizard()
    }

    @objc func openVMsFolder(_ sender: Any?) {
        do {
            // Resolving `vmsDirectory` creates the folder when missing, so the
            // command also works on a fresh install with an empty library.
            NSWorkspace.shared.open(try viewModel.storageService.vmsDirectory)
        } catch {
            Self.logger.error(
                "openVMsFolder: failed to resolve VMs directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc func showLibrary(_ sender: Any?) {
        showLibraryWindow(bringToFront: true)
    }

    private func showLibraryWindow(bringToFront: Bool) {
        ensureRegularActivationIfAgent()
        if let existingWindow = mainWindowController?.window {
            if bringToFront {
                Self.logger.debug("showLibrary: focusing existing window")
                NSApp.activate()
                existingWindow.makeKeyAndOrderFront(nil)
            } else {
                Self.logger.debug("showLibrary: showing existing window in background")
                existingWindow.orderBack(nil)
            }
        } else {
            Self.logger.notice("showLibrary: recreating main window controller")
            let windowController = MainWindowController(viewModel: viewModel)
            if bringToFront {
                windowController.showWindow(nil)
            } else {
                windowController.showWindowInBackground()
            }
            mainWindowController = windowController
        }
    }

    @objc func showAboutPanel(_ sender: Any?) {
        #if DEBUG
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        let versionAnnotation = buildNumber.isEmpty ? "Debug" : "\(buildNumber) | Debug"
        NSApp.orderFrontStandardAboutPanel(options: [.version: versionAnnotation])
        #else
        NSApp.orderFrontStandardAboutPanel(sender)
        #endif
    }

    @objc func showSettings(_ sender: Any?) {
        ensureRegularActivationIfAgent()
        let controller = settingsWindowController ?? SettingsWindowController(viewModel: viewModel)
        settingsWindowController = controller
        NSApp.activate()
        controller.showWindow(sender)
        controller.window?.makeKeyAndOrderFront(sender)
    }

    // MARK: - VM Actions

    @objc func startVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.start(instance) }
    }

    @objc func startVMInRecovery(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.confirmStartInRecovery(instance)
    }

    @objc func pauseVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.pause(instance) }
    }

    @objc func resumeVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.resume(instance) }
    }

    @objc func stopVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        // Require explicit confirmation before discarding saved state
        if instance.isColdPaused {
            viewModel.confirmForceStop(instance)
        } else {
            Task { await viewModel.stop(instance) }
        }
    }

    @objc func forceStopVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.confirmForceStop(instance)
    }

    @objc func saveVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.save(instance) }
    }

    @objc func toggleSettingsPane(_ sender: Any?) {
        guard let instance = activeInstance,
            instance.status.hasActiveDisplay
        else { return }
        instance.detailPaneMode = instance.detailPaneMode == .settings ? .display : .settings
    }

    @objc func renameVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        // Reveal the sidebar first so the inline rename always lands on a visible
        // row.
        showLibraryWindow(bringToFront: true)
        mainWindowController?.revealSidebar()
        viewModel.renameVMInSidebar(instance)
    }

    @objc func cloneVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.cloneVM(instance)
    }

    @objc func cloneVMAlternate(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.cloneVMWithOppositeMachineIdentity(instance)
    }

    @objc func deleteVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.confirmDelete(instance)
    }

    @objc func deleteImmediatelyVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.confirmDelete(instance, permanently: true)
    }

    @objc func showVMInFinder(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
    }

    // MARK: - Auxiliary Windows (Serial Console, Clipboard)

    /// Shows or focuses an auxiliary window for the given VM instance.
    private func showAuxiliaryWindow<C: NSWindowController>(
        for instance: VMInstance,
        isEligible: Bool,
        windowsPath: ReferenceWritableKeyPath<AppDelegate, [UUID: C]>,
        observersPath: ReferenceWritableKeyPath<AppDelegate, [UUID: Any]>,
        factory: (VMInstance) -> C
    ) {
        guard isEligible else { return }
        ensureRegularActivationIfAgent()

        let vmID = instance.instanceID

        if let existing = self[keyPath: windowsPath][vmID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }

        let controller = factory(instance)
        self[keyPath: windowsPath][vmID] = controller

        // `ReferenceWritableKeyPath` is not Sendable, but the observer closure runs
        // on `queue: .main`, where `AppDelegate` is `@MainActor`-isolated.
        nonisolated(unsafe) let observersKP = observersPath
        nonisolated(unsafe) let windowsKP = windowsPath
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self[keyPath: observersKP].removeValue(forKey: vmID) {
                    NotificationCenter.default.removeObserver(token)
                }
                self[keyPath: windowsKP].removeValue(forKey: vmID)
                self.terminateIfIdle()
            }
        }
        self[keyPath: observersPath][vmID] = token

        controller.showWindow(nil)
    }

    @objc func showClipboard(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        showClipboardWindow(for: instance)
    }

    /// Shows or focuses the clipboard window for `instance`.
    private func showClipboardWindow(for instance: VMInstance) {
        showAuxiliaryWindow(
            for: instance,
            isEligible: instance.canShowClipboard,
            windowsPath: \.clipboardWindows,
            observersPath: \.clipboardObservers,
            factory: { [viewModel] in ClipboardWindowController(instance: $0, viewModel: viewModel) }
        )
    }

    @objc func toggleGuestAgentDisk(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        // Same single source of truth as `validateMenuItem`, so the action can
        // never disagree with the title the user clicked.
        let model = GuestAgentDiskMenuItem.model(
            status: instance.agentStatus,
            isInstallerMounted: viewModel.isGuestAgentInstallerMounted(on: instance))
        switch model.action {
        case .eject:
            viewModel.unmountGuestAgentInstaller(from: instance)
        case .mount(let purpose):
            viewModel.mountGuestAgentInstaller(on: instance, purpose: purpose)
        }
    }

    // MARK: - Display Window (Pop-Out / Fullscreen)

    @objc func togglePopOut(_ sender: Any?) {
        guard let instance = activeInstance else { return }

        if let existing = displayWindows[instance.instanceID] {
            existing.closeForPopIn()
            return
        }

        if instance.displayMode == .hidden {
            // Pop in from headless: there is no window to close — just return
            // the display slot to the main window.
            viewModel.updateConfiguration(of: instance) { $0.displayPreference = .inline }
            instance.displayMode = .inline
            viewModel.presenter?.focusGuestDisplay(for: instance)
            return
        }

        viewModel.updateConfiguration(of: instance) { $0.displayPreference = .popOut }
        openDisplayWindow(for: instance, enterFullscreen: false)
    }

    /// Brings the VM's display window forward, reopening it (in its persisted
    /// style) if the user previously closed it while the VM ran headless.
    @objc func showDisplayWindow(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        if let existing = displayWindows[instance.instanceID] {
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            openDisplayWindow(for: instance)
        }
    }

    @objc func toggleFullscreen(_ sender: Any?) {
        guard let instance = activeInstance else { return }

        if let existing = displayWindows[instance.instanceID] {
            existing.window?.toggleFullScreen(nil)
            return
        }

        viewModel.updateConfiguration(of: instance) { $0.displayPreference = .fullscreen }
        openDisplayWindow(for: instance, enterFullscreen: true)
    }

    private func openDisplayWindow(for instance: VMInstance) {
        openDisplayWindow(for: instance, enterFullscreen: instance.configuration.displayPreference == .fullscreen)
    }

    private func openDisplayWindow(for instance: VMInstance, enterFullscreen: Bool) {
        let vmID = instance.instanceID

        // Already open (e.g. resuming a live-paused VM from the library):
        // surface the existing window so keyboard input lands in the guest.
        if let existing = displayWindows[vmID] {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        ensureRegularActivationIfAgent()

        let controller = VMDisplayWindowController(
            instance: instance,
            enterFullscreen: enterFullscreen,
            onResume: { [weak self] in
                guard let self else { return }
                Task { await self.viewModel.resume(instance) }
            },
            onUpdateConfiguration: { [weak self] mutate in
                self?.viewModel.updateConfiguration(of: instance, mutate: mutate)
            }
        )
        displayWindows[vmID] = controller

        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] notification in
            // Capture window state synchronously before the Task runs (it may change).
            let window = notification.object as? NSWindow
            dispatchPrecondition(condition: .onQueue(.main))
            let (wasKeyWindow, appWasActive) = MainActor.assumeIsolated {
                (window?.isKeyWindow ?? false, NSApp.isActive)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let token = self.displayWindowObservers.removeValue(forKey: vmID) {
                    NotificationCenter.default.removeObserver(token)
                }
                guard let controller = self.displayWindows.removeValue(forKey: vmID) else { return }
                let closeReason = controller.closeReason ?? .userClose
                self.viewModel.updateConfiguration(of: instance) { config in
                    if let displayID = controller.lastDisplayID {
                        config.lastFullscreenDisplayID = displayID
                    }
                    if closeReason == .popIn {
                        config.displayPreference = .inline
                        Self.logger.debug(
                            "Cleared displayPreference for '\(instance.name, privacy: .public)' (popped display back in)"
                        )
                    }
                }

                Self.logger.notice(
                    "Display window closed for '\(instance.name, privacy: .public)' (reason=\(String(describing: closeReason), privacy: .public), policy=\(NSApp.activationPolicy().rawValue, privacy: .public))"
                )
                switch closeReason {
                case .appDismissal:
                    // VM stopped/errored/cold-paused, or the GUI was dismissed.
                    self.terminateIfIdle()
                case .userClose:
                    // The VM keeps running headless and nothing pops back in; the
                    // library window shows the "Display Closed" placeholder.
                    break
                case .popIn:
                    self.viewModel.selectedID = vmID

                    // Restore library window so the popped-in display is visible:
                    // - Key + active app: user popped in from the display window → focus library
                    // - App not active: popped in while elsewhere → show library in background
                    // - Active but not key: user is in another Kernova window (e.g. the
                    //   library's placeholder button) → no action needed
                    if wasKeyWindow && appWasActive {
                        self.showLibrary(nil)
                    } else if !appWasActive {
                        self.showLibraryWindow(bringToFront: false)
                    }
                    self.viewModel.presenter?.focusGuestDisplay(for: instance)
                    // Reconcile synchronously here, after the restore, rather than
                    // through `scheduleAgentActivationPolicySync()`: the global
                    // `willClose` observer's independent `Task` isn't guaranteed to
                    // run after the restore above, which would flip the Dock icon
                    // to `.accessory` and back.
                    self.syncAgentActivationPolicy()
                }
            }
        }
        displayWindowObservers[vmID] = token

        // For fullscreen: position on the remembered display so toggleFullScreen picks the correct screen
        if enterFullscreen {
            if let screen = targetScreen(for: instance),
                let window = controller.window
            {
                let frame = screen.frame
                let centeredOrigin = NSPoint(
                    x: frame.midX - window.frame.width / 2,
                    y: frame.midY - window.frame.height / 2
                )
                window.setFrameOrigin(centeredOrigin)
            }
        }

        controller.showWindow(nil)
    }

    /// Returns the best screen for entering fullscreen: the display the VM was
    /// last fullscreen on, else the library window's display, else the primary.
    private func targetScreen(for instance: VMInstance) -> NSScreen? {
        if let savedID = instance.configuration.lastFullscreenDisplayID {
            if let target = NSScreen.screens.first(where: { $0.displayID == savedID }) {
                Self.logger.debug(
                    "targetScreen for '\(instance.name, privacy: .public)': using saved display \(savedID, privacy: .public)"
                )
                return target
            }
            Self.logger.debug(
                "targetScreen for '\(instance.name, privacy: .public)': saved display \(savedID, privacy: .public) not found, falling back"
            )
        }
        if let libraryScreen = mainWindowController?.window?.screen {
            return libraryScreen
        }
        return NSScreen.screens.first
    }

    // MARK: - Idle Termination

    /// Whether the main library window has been dismissed (closed by the user).
    ///
    /// Distinguishes closed from hidden (Cmd+H) and minimized (Cmd+M).
    private var isMainWindowDismissed: Bool {
        guard let window = mainWindowController?.window else { return false }
        if NSApp.isHidden || window.isMiniaturized { return false }
        return !window.isVisible
    }

    /// Whether the app has no reason to stay alive: main window dismissed,
    /// no auxiliary windows remain, and no VMs are active.
    private var isIdle: Bool {
        guard isMainWindowDismissed else { return false }
        guard displayWindows.isEmpty else { return false }
        guard clipboardWindows.isEmpty else { return false }
        return !viewModel.instances.contains(where: \.isKeepingAppAlive)
    }

    /// Terminates the app if `isIdle` is true.
    ///
    /// Only the test host idle-quits. The resident app never does — closing the
    /// last window drops it to `.accessory` via
    /// `applicationShouldTerminateAfterLastWindowClosed`, keeping VMs running.
    private func terminateIfIdle() {
        guard isTestHost else { return }
        guard isIdle else { return }
        Self.logger.notice("No visible windows and no active VMs — requesting termination")
        NSApp.terminate(nil)
    }

    /// Observes each instance's `isKeepingAppAlive` state so the app can terminate
    /// when the last one flips to inactive.
    private func observeForTermination() {
        terminationObservation = observeRecurring(
            track: { [weak self] in
                guard let self else { return }
                for instance in self.viewModel.instances {
                    _ = instance.isKeepingAppAlive
                }
            },
            apply: { [weak self] in
                self?.terminateIfIdle()
            }
        )
    }

    // MARK: - Menu Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Preparing instances disable all VM menu bar actions; Show in Finder stays
        // available since the bundle already exists on disk. `quitCompletely` is
        // app-level and must never be gated on the selected VM's state, or a
        // preparing import would disable the GUI's only full-quit affordance.
        if let instance = activeInstance, instance.isPreparing {
            switch menuItem.action {
            case #selector(showLibrary(_:)), #selector(newVM(_:)), #selector(openVMsFolder(_:)),
                #selector(showVMInFinder(_:)), #selector(quitCompletely(_:)):
                return true
            default:
                return false
            }
        }

        switch menuItem.action {
        case #selector(startVM(_:)):
            guard let instance = activeInstance else { return false }
            // Install-flavored title for pending-install VMs.
            menuItem.title = instance.startAction.label
            return instance.status.canStart
        case #selector(startVMInRecovery(_:)):
            return activeInstance?.canStartInRecovery ?? false
        case #selector(pauseVM(_:)):
            return activeInstance?.status.canPause ?? false
        case #selector(resumeVM(_:)):
            return activeInstance?.status.canResume ?? false
        case #selector(stopVM(_:)):
            guard let instance = activeInstance else { return false }
            // Cold-paused VMs have no live VM to stop — `stopVM(_:)` routes them to
            // the discard-saved-state confirmation, and the title names that.
            menuItem.title = instance.stopActionMenuTitle
            return instance.canStop || instance.isColdPaused
        case #selector(forceStopVM(_:)):
            // Cold-paused is excluded: the retitled stop item ("Discard Saved
            // State…") is the one surface for that action, and two enabled items
            // must not alias one action under two names.
            return activeInstance?.canForceStop ?? false
        case #selector(saveVM(_:)):
            return activeInstance?.canSave ?? false
        case #selector(renameVM(_:)):
            return activeInstance?.status.canRename ?? false
        case #selector(cloneVM(_:)), #selector(cloneVMAlternate(_:)):
            if menuItem.action == #selector(cloneVMAlternate(_:)) {
                menuItem.title = preferences.cloneAlternateMenuTitle
            }
            guard let instance = activeInstance else { return false }
            return instance.status.canEditSettings && !viewModel.hasPreparing
        case #selector(deleteVM(_:)), #selector(deleteImmediatelyVM(_:)):
            // Same gate for both the primary and its ⌥-alternate.
            return activeInstance?.canDelete ?? false
        case #selector(showVMInFinder(_:)):
            return activeInstance != nil
        // AppKit bypasses NSMenuItemValidation for windowsMenu items, so
        // menuNeedsUpdate(_:) handles visual state. This case covers keyboard
        // shortcut validation, which still routes through validateMenuItem(_:).
        case #selector(showClipboard(_:)):
            return activeInstance?.canShowClipboard ?? false
        case #selector(toggleGuestAgentDisk(_:)):
            // Hard gates (not status-derived): a macOS guest with a live session
            // to look inside, and a bundled DMG for it to hold. Retitling on the
            // way out matters as much as enabling — see `unavailableTitle`.
            guard let instance = activeInstance, instance.canManageGuestAgentDisk,
                Self.guestAgentDiskPath != nil
            else {
                menuItem.title = GuestAgentDiskMenuItem.unavailableTitle
                return false
            }
            let model = GuestAgentDiskMenuItem.model(
                status: instance.agentStatus,
                isInstallerMounted: viewModel.isGuestAgentInstallerMounted(on: instance))
            menuItem.title = model.title
            return model.isEnabled
        case #selector(togglePopOut(_:)):
            guard let instance = activeInstance else { return false }
            let canUse = instance.canUseExternalDisplay
            // `isDisplayDetached` (not window existence): a hidden (headless)
            // display has no window but still pops back *in*.
            menuItem.title = instance.isDisplayDetached ? "Pop In Display" : "Pop Out Display"
            return canUse
        case #selector(toggleFullscreen(_:)):
            guard let instance = activeInstance else { return false }
            let canUse = instance.canUseExternalDisplay
            let isFullscreen = displayWindows[instance.instanceID] != nil && instance.isInFullscreen
            menuItem.title = isFullscreen ? "Exit Fullscreen Display" : "Fullscreen Display"
            return canUse
        default:
            return true
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === NSApp.windowsMenu {
            clipboardMenuItem.isEnabled = activeInstance?.canShowClipboard ?? false
        } else if menu === appMenu {
            // Re-derive the quit section so a Settings toggle flip is reflected on
            // the next open.
            rebuildAppMenuQuitItems()
        }
    }

    /// Rebuilds the app menu's quit section from `appMenuQuitItems` for the
    /// current mode, removing exactly the items a prior rebuild added.
    ///
    /// The unchanged-model guard is load-bearing, not an optimization: AppKit also
    /// calls `menuNeedsUpdate(_:)` while *matching key equivalents*, so this runs
    /// on every ⌘-keystroke — and tearing the items down mid-match is exactly the
    /// mutation that must not happen.
    private func rebuildAppMenuQuitItems() {
        guard let appMenu else { return }
        let model = Self.appMenuQuitItems(
            isTestHost: isTestHost, keepInMenuBar: viewModel.keepInMenuBarOnQuit)
        guard model != appMenuQuitModel else { return }
        appMenuQuitModel = model

        for item in appMenuQuitItemViews { appMenu.removeItem(item) }
        appMenuQuitItemViews = model.map { model in
            let item: NSMenuItem
            switch model.action {
            case .terminateThroughGate:
                // nil target → the responder chain resolves it to NSApp, funneling
                // through `applicationShouldTerminate`'s gate.
                item = NSMenuItem(
                    title: model.title,
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: model.keyEquivalent)
            case .quitCompletely:
                item = NSMenuItem(
                    title: model.title,
                    action: #selector(quitCompletely(_:)),
                    keyEquivalent: model.keyEquivalent)
                item.target = self
            }
            item.keyEquivalentModifierMask =
                model.usesOptionModifier ? [.command, .option] : [.command]
            return item
        }
        for item in appMenuQuitItemViews { appMenu.addItem(item) }
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Kernova", action: #selector(showAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(
            withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.keyEquivalentModifierMask = [.command]
        appMenu.addItem(.separator())
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Kernova", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        // The quit section is built dynamically per mode; `menuNeedsUpdate`
        // rebuilds it, so build it once now for the first open.
        self.appMenu = appMenu
        appMenu.delegate = self
        rebuildAppMenuQuitItems()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Virtual Machine…", action: #selector(newVM(_:)), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        // "Open … Folder" (a Finder window of the contents), not "Show in Finder",
        // which reveals an item selected in its parent — and "VMs Folder", not
        // "Library", which the Window menu already uses for the main window.
        fileMenu.addItem(withTitle: "Open VMs Folder", action: #selector(openVMsFolder(_:)), keyEquivalent: "")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        // Nil-target standard `NSWindow` actions resolve against the key window's
        // responder chain, so AppKit retitles and disables these items itself.
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleToolbarItem = viewMenu.addItem(
            withTitle: "Show Toolbar",
            action: #selector(NSWindow.toggleToolbarShown(_:)),
            keyEquivalent: "t"
        )
        toggleToolbarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(
            withTitle: "Customize Toolbar…",
            action: #selector(NSWindow.runToolbarCustomizationPalette(_:)),
            keyEquivalent: ""
        )
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Virtual Machine menu
        let vmMenuItem = NSMenuItem()
        let vmMenu = NSMenu(title: "Virtual Machine")
        vmMenu.addItem(withTitle: "Start", action: #selector(startVM(_:)), keyEquivalent: "r")
        // The ⌥⌘R shortcut is shared with "Resume" — unambiguous because a VM is
        // never both stopped and paused, and recovery precedes Resume in menu order.
        let recoveryItem = vmMenu.addItem(
            withTitle: "Start in Recovery Mode", action: #selector(startVMInRecovery(_:)), keyEquivalent: "r")
        recoveryItem.keyEquivalentModifierMask = [.command, .option]
        let pauseItem = vmMenu.addItem(withTitle: "Pause", action: #selector(pauseVM(_:)), keyEquivalent: "p")
        pauseItem.keyEquivalentModifierMask = [.command, .option]
        let resumeItem = vmMenu.addItem(withTitle: "Resume", action: #selector(resumeVM(_:)), keyEquivalent: "r")
        resumeItem.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(withTitle: "Stop", action: #selector(stopVM(_:)), keyEquivalent: "")
        vmMenu.addItem(withTitle: "Force Stop…", action: #selector(forceStopVM(_:)), keyEquivalent: "")
        vmMenu.addItem(.separator())
        let saveItem = vmMenu.addItem(withTitle: "Suspend", action: #selector(saveVM(_:)), keyEquivalent: "s")
        saveItem.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(.separator())
        let popOutItem = vmMenu.addItem(
            withTitle: "Pop Out Display",
            action: #selector(togglePopOut(_:)),
            keyEquivalent: "o"
        )
        popOutItem.keyEquivalentModifierMask = [.command, .shift]
        let fullscreenItem = vmMenu.addItem(
            withTitle: "Fullscreen Display",
            action: #selector(toggleFullscreen(_:)),
            keyEquivalent: "f"
        )
        fullscreenItem.keyEquivalentModifierMask = [.command, .shift]
        vmMenu.addItem(.separator())
        // No ellipsis on "Rename": it starts an inline edit on the sidebar row (like
        // Finder's single-item Rename), not a dialog.
        vmMenu.addItem(withTitle: "Rename", action: #selector(renameVM(_:)), keyEquivalent: "")
        vmMenu.addItem(withTitle: "Clone", action: #selector(cloneVM(_:)), keyEquivalent: "d")
        // Clones with the opposite machine-identity behavior to the setting.
        // Always visible, like Start in Recovery Mode: this menu shows advanced
        // actions plainly, reserving ⌥-alternates for irreversible ones.
        // `validateMenuItem(_:)` re-reads the title on every menu open, so a
        // setting change while the menu exists is picked up. The ⌥⌘D key
        // equivalent is eclipsed by the system's Dock-hiding hotkey; the item
        // fires from the pointer.
        let cloneAlternateItem = vmMenu.addItem(
            withTitle: preferences.cloneAlternateMenuTitle, action: #selector(cloneVMAlternate(_:)),
            keyEquivalent: "d")
        cloneAlternateItem.keyEquivalentModifierMask = [.command, .option]
        vmMenu.addItem(withTitle: "Show in Finder", action: #selector(showVMInFinder(_:)), keyEquivalent: "")
        vmMenu.addItem(.separator())
        // "Move to Trash…" gathers input (the delete sheet lets the user pick which
        // external files to remove too), so the ellipsis is HIG-correct here.
        let deleteItem = vmMenu.addItem(
            withTitle: "Move to Trash…", action: #selector(deleteVM(_:)), keyEquivalent: "\u{08}")
        deleteItem.keyEquivalentModifierMask = [.command]
        // ⌥-alternate, Finder's idiom for this pair: it is irreversible, so it stays
        // tucked behind Option rather than one slip from the pointer.
        let deleteImmediatelyItem = vmMenu.addItem(
            withTitle: "Delete Immediately…", action: #selector(deleteImmediatelyVM(_:)), keyEquivalent: "\u{08}")
        deleteImmediatelyItem.keyEquivalentModifierMask = [.command, .option]
        deleteImmediatelyItem.isAlternate = true
        vmMenu.addItem(.separator())
        // Title is a placeholder — `validateMenuItem(_:)` retitles per agent status
        // and attach state on every menu open.
        vmMenu.addItem(
            NSMenuItem(
                title: GuestAgentDiskMenuItem.unavailableTitle,
                action: #selector(toggleGuestAgentDisk(_:)),
                keyEquivalent: ""
            ))
        vmMenuItem.submenu = vmMenu
        mainMenu.addItem(vmMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        let showLibraryItem = NSMenuItem(
            title: "Show Library",
            action: #selector(showLibrary(_:)),
            keyEquivalent: "0"
        )
        windowMenu.addItem(showLibraryItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(clipboardMenuItem)
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu
        windowMenu.delegate = self
        mainMenu.addItem(windowMenuItem)

        // Help menu
        let helpMenuItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "Kernova Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
        helpMenuItem.submenu = helpMenu
        NSApp.helpMenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        NSApp.mainMenu = mainMenu
    }
}

// MARK: - DisplayBootGeometryProviding

extension AppDelegate: DisplayBootGeometryProviding {
    func displayBootSurface(for instance: VMInstance) -> DisplayBootSurface? {
        switch instance.configuration.displayPreference {
        case .popOut:
            // `start` opens the display window before consulting this, and
            // `setFrameAutosaveName` restores the saved frame at init, so the
            // content view already carries the size the guest will fill.
            guard let window = displayWindows[instance.instanceID]?.window,
                let content = window.contentView
            else { return nil }
            return surface(pointSize: content.bounds.size, scale: window.backingScaleFactor)
        case .fullscreen:
            // The screen, never the window: the fullscreen transition is still
            // in flight, so the window's frame is the pre-transition one.
            // Fullscreen content sits below the camera housing, so the notch
            // strip (`safeAreaInsets.top`) is not part of the surface.
            guard let screen = targetScreen(for: instance) else { return nil }
            var size = screen.frame.size
            size.height -= screen.safeAreaInsets.top
            return surface(pointSize: size, scale: screen.backingScaleFactor)
        case .inline:
            return mainWindowController?.detailContainer.displayBootSurface()
        }
    }

    private func surface(pointSize: CGSize, scale: CGFloat) -> DisplayBootSurface? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        return DisplayBootSurface(pointSize: pointSize, backingScaleFactor: scale)
    }
}
