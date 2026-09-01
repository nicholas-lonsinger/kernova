import AppIntents
import Cocoa
import Darwin
import KernovaKit
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    /// Whether this process is the unit-test host.
    ///
    /// `true` for the `BUNDLE_LOADER` test host — a plain foreground app that
    /// idle-terminates, with none of the resident-app machinery (status item,
    /// login-item registration, activation-policy switching).
    private let isTestHost: Bool
    /// App-wide preferences (the single DI seam for `UserDefaults`-backed state).
    private let preferences: AppPreferences
    /// The one owner of which user-facing windows exist, and whether any is on
    /// screen.
    private let windows: AppWindowRegistry
    /// The one owner of the menu bar — construction, the open-time rebuilds, and
    /// menu-item validation. Strongly held: `NSMenu.delegate` is weak, and this
    /// is the delegate of every menu whose opening it answers for.
    private let mainMenu: MainMenuController
    /// The one owner of what the process is when no window is on screen: the
    /// activation policy, the status item, the GUI summon, and the idle quit.
    ///
    /// Assigned once in `init` and never again — `nil` exactly for the test
    /// host, which is a plain foreground app with none of that machinery, and
    /// that `nil` is what stands in for every resident-app-only guard.
    private var residency: AppResidencyController?
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
    /// Latched once ``armAutoStartPassIfNeeded()`` has armed the pass, so the
    /// first interactive bring-up of an automation-launched process runs it and
    /// no later one runs it a second time.
    private var hasArmedAutoStartPass = false
    /// The App Intents front door, retained so the aliveness decision can ask
    /// whether an intent is still running. `AppDependencyManager` owns the copy
    /// intents resolve.
    private var intentGateway: VMIntentGateway?
    /// Whether `applicationOpenUntitledFile(_:)` ran, latched before
    /// `applicationDidFinishLaunching` reads it — see ``AppResidencyController/launchProvenance(openedUntitledFile:openedDocuments:hasOpenAppleEvent:isLoginItemLaunch:isDefaultLaunch:)``.
    private var didOpenUntitledFile = false
    /// Whether `application(_:open:)` ran with a launch document, latched the
    /// same way.
    private var didOpenLaunchDocuments = false
    /// Watches guest liveness so the test host settles once the last VM stops.
    private var terminationObservation: ObservationLoop?
    /// Latched once the termination gate has replied `.terminateLater`, so a
    /// second quit can't start a second save pass: its `trySave` would come back
    /// as `operationInProgress` and the catch would force-stop a VM mid-save.
    ///
    /// Never reset, matching the quit flags below: every later quit defers to the
    /// pass, which always replies and terminates the app.
    private var isRunningTerminationSavePass = false

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

    private static let logger = Logger(subsystem: "app.kernova", category: "AppDelegate")

    /// Returns the VM that menu actions should target: the display or clipboard
    /// window's VM if its window is key, otherwise the sidebar-selected VM.
    private var activeInstance: VMInstance? {
        NSApp.keyWindow.flatMap(windows.instance(forKeyWindow:)) ?? viewModel.selectedInstance
    }

    /// The VM a nil-target action acts on: the one the sending item names, else
    /// ``activeInstance``.
    ///
    /// The sidebar's context menu dispatches its display toggles down the
    /// responder chain, and its row is not always the key window's VM — naming
    /// the VM on the item is what keeps the click acting on the row it came
    /// from. Every other sender carries none and gets the key-window rule.
    private func target(of sender: Any?) -> VMInstance? {
        (sender as? NSMenuItem)?.representedObject as? VMInstance ?? activeInstance
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
        let viewModel = VMLibraryViewModel()
        self.viewModel = viewModel
        self.windows = AppWindowRegistry(
            viewModel: viewModel,
            displayPlacement: VMDisplayPlacementController(viewModel: viewModel))
        self.mainMenu = MainMenuController(
            viewModel: viewModel, preferences: preferences, isTestHost: isTestHost)

        super.init()

        if !isTestHost {
            residency = AppResidencyController(
                viewModel: viewModel,
                preferences: preferences,
                windows: windows,
                hasIntentInFlight: { [weak self] in
                    self?.intentGateway?.hasIntentInFlight ?? false
                },
                onInterfacePresented: { [weak self] in self?.armAutoStartPassIfNeeded() },
                onRequestFullQuit: { [weak self] in self?.requestFullQuit() })
        }
        windows.residency = self
        windows.displayPlacement.residency = self
        windows.displayPlacement.host = windows
        mainMenu.host = self
        viewModel.onSurfaceLibrary = { [weak self] in
            self?.residency?.presentSummonedInterface()
        }
        viewModel.onOpenDisplayWindow = { [weak self] instance in
            self?.windows.displayPlacement.showDisplayWindow(for: instance)
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
        registerIntentGateway()
    }

    /// Publishes the App Intents front door, so an intent delivered during
    /// launch resolves it rather than failing for a missing dependency.
    ///
    /// The gateway is retained by the dependency manager and lives as long as
    /// the process. It takes `libraryLoad` as its readiness await: an intent can
    /// arrive while the first library read is still in flight, and a verb run
    /// against a library that has not landed yet finds no VM to address.
    ///
    /// Not in the test host, with the rest of the resident-app machinery: the
    /// gateway rebuilds Siri's parameter vocabulary, which writes to the
    /// developer's own Shortcuts database, and holds an events subscription that
    /// keeps the core's observation loop armed for every test.
    private func registerIntentGateway() {
        guard !isTestHost else { return }
        let gateway = VMIntentGateway(
            commands: viewModel.commands,
            awaitReady: { [weak self] in
                guard let load = await self?.libraryLoad else { return }
                await load.value
            },
            onIdle: { [weak self] in self?.residency?.reconcileIdleTermination() })
        intentGateway = gateway
        AppDependencyManager.shared.add(dependency: gateway)
    }

    /// Records that Launch Services asked for the app's default surface.
    ///
    /// AppKit sends this while handling the launch `kAEOpenApplication`, which
    /// it does *between* `applicationWillFinishLaunching` and
    /// `applicationDidFinishLaunching` — so the latch is always settled by the
    /// time `readLaunchProvenance` reads it. The window itself is not opened
    /// here: `AppResidencyController.start(provenance:)` owns presentation, and
    /// answering `true` only reports
    /// that the request was taken.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        didOpenUntitledFile = true
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        mainMenu.install()

        // Reclaim orphaned clipboard staging files from a previous run or crash —
        // every label family under the shared parent (`host`, per-VM `host-<vm>`
        // receive roots, `host-send-<vm>` outbound-archive roots). The staged file
        // URL must outlive the clipboard window (paste-after-close), so staging
        // never sweeps on close — only here, before any clipboard use.
        ClipboardFileStaging.reclaimAll()

        // Same reason, for the files a promise drag writes before it is offered:
        // the guest pulls a queued drop only when its turn comes, so launch is
        // the one moment nothing staged can still be owed to it.
        DropPromiseStaging.reclaimAll()

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
            windows.showLibrary(bringToFront: true)
            observeForTermination()
        } else {
            let provenance = readLaunchProvenance(notification)
            let line = Self.residentProvenanceLine(
                bundlePath: Bundle.main.bundlePath,
                build: Self.buildNumber,
                configuration: Self.buildConfiguration,
                vmNetworkingEntitled: EntitlementService.shared.hasVMNetworking,
                launch: provenance)
            Self.logger.notice("Kernova resident app ready — \(line, privacy: .public)")
            residency?.start(provenance: provenance)
        }
    }

    /// Reads the launch's raw signals and classifies them.
    ///
    /// The only place any of them is read: everything downstream takes the
    /// decided ``AppResidencyController/LaunchProvenance``, so a second front
    /// door (a CLI, #309) marks its own launches rather than adding a second
    /// detection mechanism.
    private func readLaunchProvenance(
        _ notification: Notification
    ) -> AppResidencyController.LaunchProvenance {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let isOpenEvent =
            event.map { descriptor in
                descriptor.eventClass == AEEventClass(kCoreEventClass)
                    && (descriptor.eventID == AEEventID(kAEOpenApplication)
                        || descriptor.eventID == AEEventID(kAEOpenDocuments))
            } ?? false
        let isLoginItem =
            event.map { descriptor in
                descriptor.eventID == AEEventID(kAEOpenApplication)
                    && descriptor.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                        == keyAELaunchedAsLogInItem
            } ?? false
        // Absent means unknown, and unknown resolves to the interactive launch.
        let isDefaultLaunch =
            notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true

        return AppResidencyController.launchProvenance(
            openedUntitledFile: didOpenUntitledFile,
            openedDocuments: didOpenLaunchDocuments,
            hasOpenAppleEvent: isOpenEvent,
            isLoginItemLaunch: isLoginItem,
            isDefaultLaunch: isDefaultLaunch)
    }

    /// Arms the launch pass that brings up the VMs marked to start
    /// automatically, once per process.
    ///
    /// Deferred rather than skipped for an automation launch: a nightly
    /// automation must not cost the user *Start automatically on launch* for the
    /// rest of the process's life, so the first interactive bring-up — a reopen,
    /// a document open, a status-item summon — runs the pass it never got. The
    /// pass is safe to run late because `VMLibraryViewModel.autoStartStep`
    /// re-reads each instance when it acts and skips one already running.
    private func armAutoStartPassIfNeeded() {
        guard !hasArmedAutoStartPass else { return }
        hasArmedAutoStartPass = true
        autoStartPass = Task { @MainActor in
            await self.libraryLoad?.value
            await self.viewModel.startAutomaticVMsForLaunch()
        }
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
        bundlePath: String, build: String, configuration: String, vmNetworkingEntitled: Bool,
        launch: AppResidencyController.LaunchProvenance
    ) -> String {
        let launchName =
            switch launch {
            case .user: "user"
            case .loginItem: "loginItem"
            case .automation: "automation"
            }
        return "bundle=\(bundlePath) build=\(build) config=\(configuration) "
            + "vmNetworking=\(vmNetworkingEntitled ? "entitled" : "unentitled") "
            + "launch=\(launchName)"
    }

    /// What the termination gate does with a quit request.
    enum TerminationOutcome: Equatable {
        /// Downgrade the quit to a GUI close; the app stays resident.
        case closeGUI
        /// Wait on the save pass already running, without starting a second one.
        case deferToSavePass
        /// Nothing to save and nothing to wait out.
        case terminateNow
        /// Reply later: wait out every in-flight save and revert, then
        /// save-suspend whatever is still live.
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
    /// A revert in flight forces the deferred reply for the same reason: it
    /// writes the bundle's disks, and can bring the VM back live once they are
    /// in place — with no live session to save, the gate would otherwise reply
    /// `.terminateNow` and exit straight through the write.
    ///
    /// A running save pass outranks the soft-quit downgrade: the app is already
    /// on its way out, so closing the GUI and telling the user it stays resident
    /// would be false.
    nonisolated static func terminationOutcome(
        shouldTerminateAgent: Bool,
        isSavePassRunning: Bool,
        hasSaveInFlight: Bool,
        hasRevertInFlight: Bool,
        hasInstancesToSave: Bool
    ) -> TerminationOutcome {
        if isSavePassRunning { return .deferToSavePass }
        guard shouldTerminateAgent else { return .closeGUI }
        if hasSaveInFlight || hasRevertInFlight || hasInstancesToSave { return .saveThenTerminate }
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

        if hasActiveVMs || !windows.displayPlacement.isEmpty {
            Self.logger.debug(
                "applicationShouldTerminateAfterLastWindowClosed: false (activeVMs=\(hasActiveVMs, privacy: .public), displayWindows=\(self.windows.displayPlacement.count, privacy: .public))"
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
        let justActivated = wasJustActivated
        wasJustActivated = false  // Synchronous clear — see wasJustActivated doc comment

        // A Finder reopen (double-click / Dock click / `open` routed to the
        // existing instance, including our own Launch Services self-open) already
        // carries its own activation request, so the resident leg only ever
        // presents — never re-requests activation, or a self-open would loop.
        if let residency {
            residency.handleReopen()
            return true
        }

        if !flag {
            showLibrary(nil)
        } else if !justActivated && windows.isLibraryDismissed {
            Self.logger.debug("applicationShouldHandleReopen: reopening dismissed library window")
            showLibrary(nil)
        } else if justActivated {
            Self.logger.debug("applicationShouldHandleReopen: suppressed (initial activation with visible windows)")
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(
            title: "Show Library", action: #selector(summonLibraryFromDockMenu), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// The Dock menu's "Show Library", routed through the summon path rather
    /// than `showLibrary(_:)`: unlike ⌘0 (only reachable while the app is
    /// already active), a Dock-menu selection can arrive while Kernova is
    /// inactive and needs the summon path's activation request.
    @objc private func summonLibraryFromDockMenu(_ sender: Any?) {
        residency?.summonUserInterface()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Every quit path funnels through `terminate:` and thus this method, so
        // this single gate covers them all — see `quitShouldTerminateAgent`.
        switch Self.terminationOutcome(
            shouldTerminateAgent: isTestHost || quitShouldTerminateAgent,
            isSavePassRunning: isRunningTerminationSavePass,
            hasSaveInFlight: viewModel.hasSaveInFlight,
            hasRevertInFlight: viewModel.hasRevertInFlight,
            hasInstancesToSave: viewModel.instances.contains(where: \.hasLiveSession)
        ) {
        case .closeGUI:
            Self.logger.notice("GUI-origin quit — closing the GUI; app stays resident")
            // Defer so the close runs after this termination request is fully
            // cancelled. `.closeGUI` is unreachable in the test host, whose
            // `shouldTerminateAgent` is unconditionally true, so the optional
            // chain skips nothing.
            Task { @MainActor in
                self.residency?.closeGUIForSoftQuit()
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

    /// Waits out every in-flight save and revert, then save-suspends whatever is
    /// still live.
    ///
    /// One instance per iteration, tracked by id: a failed force-stop leaves the
    /// VM live, so re-selecting on state alone would loop forever, and marking a
    /// VM handled *before* its wait keeps that guarantee when a user-initiated
    /// operation keeps re-taking the lock.
    ///
    /// The wait at the top of each iteration covers a save or revert the user
    /// starts on another VM while the pass runs — neither a `.saving` VM nor a
    /// reverting one is selectable here (both fail `hasLiveSession`), so nothing
    /// else would stop the loop from breaking out and letting the process exit
    /// mid-write. The per-VM wait below covers the selected VM's own settling
    /// operation, per ``terminationSaveStep(hasLiveSession:hasActiveOperation:)``.
    ///
    /// The revert wait sits at the top of the loop for two reasons: this pass's
    /// own force-stop fallback powers an Ephemeral VM off and registers a revert
    /// mid-pass, and a revert that brings its VM back live re-enters selection,
    /// so that VM is save-suspended rather than killed running.
    private func runTerminationSavePass() async {
        var handled: Set<UUID> = []
        var savedCount = 0
        var failedCount = 0
        var skippedCount = 0
        while true {
            // Both predicates are re-tested after either wait: each suspends,
            // and a save the user starts during the revert wait — or a revert a
            // save's power-off registers — would otherwise reach the guard
            // below unnoticed, break the pass out, and let the process exit
            // mid-write.
            while viewModel.hasSaveInFlight || viewModel.hasRevertInFlight {
                if viewModel.hasSaveInFlight {
                    Self.logger.notice("Termination waiting on an in-flight save to settle")
                    await waitForObservedChange { [viewModel] in !viewModel.hasSaveInFlight }
                }
                if viewModel.hasRevertInFlight {
                    Self.logger.notice(
                        "Termination waiting on an in-flight snapshot revert to settle")
                    await viewModel.waitForRevertsToSettle()
                }
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
        } catch let error as CommandError where error.isBusy {
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
        // A launch document arrives between `applicationWillFinishLaunching` and
        // `applicationDidFinishLaunching`, so this latch is settled in time to
        // classify the launch — a double-clicked bundle is a person asking, and
        // carries no `kAEOpenApplication` of its own to say so.
        didOpenLaunchDocuments = true
        importVMs(from: urls)
        // A double-click while the app is already resident+headless gets no
        // reopen — macOS sends no reopen for a document open — so surface the
        // window here. Presentation only: a launch document open and a later
        // one delivered to the running app are both Launch-Services-mediated
        // and already carry their own activation request, per
        // `presentSummonedInterface`'s invariant. The test host manages its
        // own window.
        residency?.presentSummonedInterface()
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
        windows.showLibrary(bringToFront: true)
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
        windows.showLibrary(bringToFront: true)
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
        windows.showSettings(sender)
    }

    // MARK: - VM Actions

    @objc func startVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.start(instance) }
    }

    @objc func startVMInRecovery(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestStartInRecovery(instance)
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
            viewModel.requestForceStop(instance)
        } else {
            Task { await viewModel.stop(instance) }
        }
    }

    @objc func forceStopVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestForceStop(instance)
    }

    @objc func saveVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        Task { await viewModel.save(instance) }
    }

    @objc func takeSnapshot(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestTakeSnapshot(instance)
    }

    /// Reverts to the snapshot the sending "Revert to Snapshot" item names.
    @objc func revertToSnapshot(_ sender: Any?) {
        guard let ref = (sender as? NSMenuItem)?.representedObject as? SnapshotMenuRef else {
            return
        }
        viewModel.requestRevert(ref.instance, to: ref.snapshot)
    }

    @objc func toggleSettingsPane(_ sender: Any?) {
        guard let instance = activeInstance,
            instance.hasActiveDisplay
        else { return }
        instance.detailPaneMode = instance.detailPaneMode == .settings ? .display : .settings
    }

    @objc func renameVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        // Reveal the sidebar first so the inline rename always lands on a visible
        // row.
        windows.showLibrary(bringToFront: true)
        windows.revealLibrarySidebar()
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
        viewModel.requestDelete(instance)
    }

    @objc func deleteImmediatelyVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.requestDelete(instance, permanently: true)
    }

    @objc func showVMInFinder(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        NSWorkspace.shared.activateFileViewerSelecting([instance.bundleURL])
    }

    @objc func showClipboard(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        windows.showClipboard(for: instance)
    }

    @objc func toggleGuestAgentDisk(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        // Same single source of truth as `MainMenuController.validate`, so the
        // action can never disagree with the title the user clicked.
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
        guard let instance = target(of: sender) else { return }
        windows.displayPlacement.togglePopOut(for: instance)
    }

    /// Brings the VM's display window forward, reopening it (in its persisted
    /// style) if the user previously closed it while the VM ran headless.
    @objc func showDisplayWindow(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        windows.displayPlacement.showDisplayWindow(for: instance)
    }

    @objc func toggleFullscreen(_ sender: Any?) {
        guard let instance = target(of: sender) else { return }
        windows.displayPlacement.toggleFullscreen(for: instance)
    }

    // MARK: - Idle Termination

    /// Whether the app has no reason to stay alive: library window dismissed,
    /// no auxiliary windows remain, and no VMs are active.
    private var isIdle: Bool {
        guard windows.isLibraryDismissed else { return false }
        guard !windows.hasAuxiliaryWindows else { return false }
        return !viewModel.instances.contains(where: \.isKeepingAppAlive)
    }

    /// Terminates the test host if `isIdle` is true.
    ///
    /// `isIdle` reads `AppWindowRegistry.isLibraryDismissed`, which answers
    /// `false` when no library window was ever created — so it can never speak
    /// for an automation launch.
    /// `AppResidencyController.automationIdleOutcome` covers that case on its own
    /// window-presence read.
    private func terminateIfIdle() {
        guard isTestHost else { return }
        guard isIdle else { return }
        Self.logger.notice("No visible windows and no active VMs — requesting termination")
        NSApp.terminate(nil)
    }

    /// Arms the test host's idle quit, so it leaves once the last VM a suite
    /// started stops.
    private func observeForTermination() {
        terminationObservation = observeGuestLiveness(of: viewModel) { [weak self] in
            self?.reconcileIdleTermination()
        }
    }

    // MARK: - Menu Validation

    /// AppKit asks a menu item's *target*, and a nil-target item resolves to
    /// this delegate — so the answer is forwarded to the menu's own owner.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        mainMenu.validate(menuItem)
    }
}

// MARK: - WindowResidencyHosting

extension AppDelegate: WindowResidencyHosting {
    func prepareToPresentWindow() { residency?.prepareToPresentWindow() }

    func syncActivationPolicy() { residency?.syncActivationPolicy() }

    /// The test host has residency behavior of its own — a plain foreground app
    /// that idle-quits — with no `AppResidencyController` to hold it.
    func reconcileIdleTermination() {
        guard let residency else {
            terminateIfIdle()
            return
        }
        residency.reconcileIdleTermination()
    }
}

// MARK: - MainMenuHosting

extension AppDelegate: MainMenuHosting {
    func menuCommandTarget(of sender: Any?) -> VMInstance? { target(of: sender) }
}

// MARK: - DisplayBootGeometryProviding

extension AppDelegate: DisplayBootGeometryProviding {
    func displayBootSurface(for instance: VMInstance) -> DisplayBootSurface? {
        switch instance.configuration.displayPreference {
        case .popOut:
            // `start` opens the display window before consulting this, and
            // `setFrameAutosaveName` restores the saved frame at init, so the
            // content view already carries the size the guest will fill.
            guard let window = windows.displayPlacement.window(for: instance.instanceID),
                let content = window.contentView
            else { return nil }
            return surface(pointSize: content.bounds.size, scale: window.backingScaleFactor)
        case .fullscreen:
            // The screen, never the window: the fullscreen transition is still
            // in flight, so the window's frame is the pre-transition one.
            // Fullscreen content sits below the camera housing, so the notch
            // strip (`safeAreaInsets.top`) is not part of the surface.
            guard
                let screen = windows.displayPlacement.preferredScreenForFullscreen(of: instance)
            else { return nil }
            var size = screen.frame.size
            size.height -= screen.safeAreaInsets.top
            return surface(pointSize: size, scale: screen.backingScaleFactor)
        case .inline:
            return windows.libraryDetailContainer?.displayBootSurface()
        }
    }

    private func surface(pointSize: CGSize, scale: CGFloat) -> DisplayBootSurface? {
        guard pointSize.width > 0, pointSize.height > 0 else { return nil }
        return DisplayBootSurface(pointSize: pointSize, backingScaleFactor: scale)
    }
}
