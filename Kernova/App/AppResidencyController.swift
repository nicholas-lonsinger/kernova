import AppIntents
import Cocoa
import os

/// The residency decisions a window owner needs but cannot make.
@MainActor
protocol WindowResidencyHosting: AnyObject {
    /// Re-asserts whatever the app must be before a window goes on screen.
    func prepareToPresentWindow()
    /// Re-decides the activation policy now, rather than on the next runloop turn.
    func syncActivationPolicy()
    /// Re-decide whether the process still has work.
    func reconcileIdleTermination()
}

/// Everything ``AppDelegate`` asks of the process's residency — what it is
/// between windows, and what a launch, a reopen and a summon do to it.
///
/// The one place the two modes differ: ``AppResidencyController`` is the
/// resident app, ``TestHostResidencyController`` the plain foreground test host.
/// The delegate holds one of them and forks nowhere.
@MainActor
protocol AppResidencyHosting: WindowResidencyHosting {
    /// The launch cluster this residency reaches back into.
    var host: (any AppLaunchHosting)? { get set }
    /// Where a downgraded quit closes the GUI, or `nil` for a mode with no
    /// headless state to downgrade into — which is what makes every quit there a
    /// real one.
    var softQuit: (any SoftQuitHosting)? { get }
    /// Publishes the App Intents front door, before any launch presentation, so
    /// an intent delivered during launch resolves it.
    func registerIntentGateway()
    /// Brings the process up for the launch it was given.
    func start(provenance: AppResidencyController.LaunchProvenance)
    /// The answer to `applicationShouldTerminateAfterLastWindowClosed(_:)`.
    var terminatesAfterLastWindowClosed: Bool { get }
    /// Records that the app is about to become active, so the reopen that may
    /// follow can tell a dock click that activated the app from one on an
    /// already-active app.
    func noteWillBecomeActive()
    /// The reopen leg — a Dock click, `open`, a Launch Services self-open.
    func handleReopen(hasVisibleWindows: Bool)
    /// Puts the summoned interface on screen, without requesting activation.
    func presentSummonedInterface()
    /// Brings the GUI forward, requesting activation.
    func summonUserInterface()
}

/// The launch-cluster seam a residency needs but cannot own: the auto-start
/// pass, the first library read, and the true quit.
@MainActor
protocol AppLaunchHosting: AnyObject {
    /// Arms the pass that brings up the VMs marked to start automatically, once
    /// per process.
    ///
    /// `surfacingDisplays` is `false` only where the pass runs with no GUI: a
    /// headless login launch, whose guests must not drag a window on screen.
    func armAutoStartPass(surfacingDisplays: Bool)
    /// Awaits the app's first library read.
    func awaitLibraryReady() async
    /// Terminates the app unconditionally, bypassing the keep-in-menu-bar
    /// downgrade.
    func requestFullQuit()
}

/// The one owner of what the process *is* when no window is on screen: the
/// activation policy, the status item, the GUI summon, and the idle quit an
/// automation launch settles into.
///
/// Constructed only for the resident app — the test host runs
/// ``TestHostResidencyController`` instead — so every path here can assume the
/// resident-app machinery is the one that runs.
@MainActor
final class AppResidencyController: AppResidencyHosting {
    private let viewModel: VMLibraryViewModel
    /// App-wide preferences, handed to the status item.
    private let preferences: AppPreferences
    /// The one owner of which user-facing windows exist; every presentation and
    /// the window half of every reconcile goes through it.
    private let windows: AppWindowRegistry
    weak var host: (any AppLaunchHosting)?

    /// The App Intents front door, retained so the aliveness decision can ask
    /// whether an intent is still running — which is what holds an otherwise-idle
    /// automation launch open. `AppDependencyManager` owns the copy intents
    /// resolve.
    private var intentGateway: VMIntentGateway?

    /// How this process was brought up, decided once by ``start(provenance:)``.
    private var launchProvenance: LaunchProvenance = .user

    /// Whether any GUI surface has been put on screen this run.
    ///
    /// What separates an automation-launched process that is still headless from
    /// one a person has since summoned: only the former may idle-quit, and only
    /// the former still owes the auto-start pass.
    private(set) var hasPresentedInterface = false

    /// Latched once a reconcile has asked to terminate for want of anything to
    /// do, so a second one — a window closing during the async save, or an
    /// intent settling behind the last window — can't request a second
    /// termination.
    private var hasRequestedIdleTermination = false

    /// The menu-bar status item — the "Kernova is running" affordance and the way
    /// to summon the GUI while headless.
    ///
    /// Present exactly while *Continue running in Status Bar* is on
    /// (``syncStatusItem()``).
    private var statusItemController: HostAgentStatusItemController?

    /// Watches the residency toggle so the status item and the reconcile follow
    /// it live.
    private var residencyObservation: ObservationLoop?

    /// Watches guest liveness for an automation launch, so a process an intent
    /// started a VM in can leave once that guest stops.
    private var idleObservation: ObservationLoop?

    /// Single close-side trigger for the activation-policy reconcile.
    ///
    /// Fires ``scheduleActivationPolicySync()`` when a titled window closes,
    /// tracked or not (e.g. the standard About panel) — the only closes that can
    /// change ``hasVisibleUserWindow`` (``windowCloseAffectsActivationPolicy(_:)``).
    private var globalWindowCloseObserver: Any?

    private static let logger = Logger(subsystem: "app.kernova", category: "AppResidency")

    init(
        viewModel: VMLibraryViewModel,
        preferences: AppPreferences,
        windows: AppWindowRegistry
    ) {
        self.viewModel = viewModel
        self.preferences = preferences
        self.windows = windows
    }

    // MARK: - Intents

    /// Publishes the App Intents front door, so an intent delivered during
    /// launch resolves it rather than failing for a missing dependency.
    ///
    /// The gateway is retained by the dependency manager and lives as long as
    /// the process. It takes the app's first library read as its readiness
    /// await: an intent can arrive while that read is still in flight, and a verb
    /// run against a library that has not landed yet finds no VM to address.
    func registerIntentGateway() {
        let gateway = VMIntentGateway(
            commands: viewModel.commands,
            awaitReady: { [weak self] in
                guard let self else { return }
                await self.awaitLibraryReady()
            },
            onIdle: { [weak self] in self?.reconcileIdleTermination() })
        intentGateway = gateway
        AppDependencyManager.shared.add(dependency: gateway)
    }

    /// Awaits the app's first library read on the main actor, so the gateway's
    /// `@Sendable` readiness closure only ever captures this controller.
    private func awaitLibraryReady() async {
        await host?.awaitLibraryReady()
    }

    // MARK: - Start

    /// Who brought this process up, as decided by ``launchProvenance(openedUntitledFile:openedDocuments:hasOpenAppleEvent:openEventIsDirect:isHiddenLaunch:isLoginItemLaunch:isDefaultLaunch:)``.
    enum LaunchProvenance: Equatable {
        /// A person opened the app — a double-click, `open`, the Dock.
        case user
        /// The system opened it at login, on the user's standing request.
        case loginItem
        /// Something opened it to service automation, with nobody present.
        case automation
    }

    /// Classifies a launch from the signals AppKit settles before
    /// `applicationDidFinishLaunching`.
    ///
    /// **Positive identification only.** A user launch that came up headless —
    /// no window for a double-click — is far worse than an automation launch
    /// that showed one, so `.automation` is returned only for a launch that
    /// shows no sign of a person at all or carries the pair below, and anything
    /// unrecognized resolves to `.user`.
    ///
    /// What makes that separable is the pair *hidden* and *foreign*, measured on
    /// macOS 27 (26A5425a) on 2026-09-04: an App Intents launch comes up hidden,
    /// and the open Apple Event the Shortcuts runner sends it — which the runner
    /// sends on roughly one launch in four, so its absence carries no
    /// information — has a `keyEventSourceAttr` of `kAELocalProcess` naming the
    /// runner as sender. Each launch a person performs that was measured breaks
    /// that pair: a Finder double-click and a Dock click carry a foreign open
    /// event but come up unhidden, and `open -a`, `open -g -j -a` and a
    /// Shortcuts *Open App* action all send `kAEDirectCall`. An opener that
    /// asks for the app hidden has asked for no window, which is what the rule
    /// answers.
    ///
    /// `openEventIsDirect` says nothing when `hasOpenAppleEvent` is `false`, and
    /// a source that could not be read counts as direct. `openedDocuments`
    /// outranks the hidden-and-foreign rule: opening a document is a request
    /// to see it.
    nonisolated static func launchProvenance(
        openedUntitledFile: Bool,
        openedDocuments: Bool,
        hasOpenAppleEvent: Bool,
        openEventIsDirect: Bool,
        isHiddenLaunch: Bool,
        isLoginItemLaunch: Bool,
        isDefaultLaunch: Bool
    ) -> LaunchProvenance {
        if isLoginItemLaunch { return .loginItem }
        if openedDocuments { return .user }
        if isHiddenLaunch && hasOpenAppleEvent && !openEventIsDirect { return .automation }
        if openedUntitledFile || hasOpenAppleEvent || isDefaultLaunch { return .user }
        return .automation
    }

    /// How a launch brings the process up, as decided by
    /// ``launchPosture(for:keepInMenuBar:)``.
    enum LaunchPosture: Equatable {
        /// Put the library on screen; the auto-start pass rides along with it.
        case present
        /// `.accessory`, no window. `armsAutoStart` says whether the pass runs
        /// headless (a login launch) or is deferred to the first presentation
        /// (an automation launch).
        case headless(armsAutoStart: Bool)
    }

    /// Decides what a launch puts on screen and whether the auto-start pass runs
    /// now.
    ///
    /// A person opening the app asked to see it. A login launch did not: marking
    /// VMs to start automatically *and* asking for Kernova at login is a request
    /// to have those guests running, not to be shown a window — so it comes up
    /// as the status-item app and boots them there. With *Continue running in
    /// Status Bar* off there is no status item to reach a headless process, so
    /// that launch presents instead. An `.automation` launch presents nothing and
    /// boots nothing: nobody asked for a window, and booting guests is not what
    /// servicing a read verb means.
    nonisolated static func launchPosture(
        for provenance: LaunchProvenance, keepInMenuBar: Bool
    ) -> LaunchPosture {
        switch provenance {
        case .user: .present
        case .loginItem: keepInMenuBar ? .headless(armsAutoStart: true) : .present
        case .automation: .headless(armsAutoStart: false)
        }
    }

    /// Brings the resident app up in the posture
    /// ``launchPosture(for:keepInMenuBar:)`` gives the launch.
    ///
    /// The status item, the residency observation and the window-close reconcile
    /// are set up for every provenance — they are what the process needs to be
    /// reachable and to answer for itself, whoever started it. The three
    /// postures then differ in what goes on screen and when the auto-start pass
    /// runs:
    ///
    /// - `.present` puts the library up, arming the pass with it, so VMs marked
    ///   `VMConfiguration.startsAutomaticallyOnLaunch` come up once the library
    ///   read lands.
    /// - `.headless(armsAutoStart: true)` runs that pass with no window: the
    ///   status item keeps the process reachable, and the residency preference
    ///   that put it there is what keeps the process alive.
    /// - `.headless(armsAutoStart: false)` presents and boots nothing, and takes
    ///   the idle-termination observer that is the only thing able to reconcile
    ///   a process that never opens a window.
    ///
    /// Both headless postures drop straight to `.accessory` — deliberately *not*
    /// through ``syncActivationPolicy()``, whose `.quit` branch would terminate
    /// the process out from under the very intent that launched it whenever
    /// *Continue running in Status Bar* is off.
    func start(provenance: LaunchProvenance) {
        launchProvenance = provenance
        let line = Self.residentProvenanceLine(
            bundlePath: Bundle.main.bundlePath,
            build: Self.buildNumber,
            configuration: Self.buildConfiguration,
            vmNetworkingEntitled: EntitlementService.shared.hasVMNetworking,
            launch: provenance)
        Self.logger.notice("Kernova resident app ready — \(line, privacy: .public)")
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
                guard !self.windows.displayPlacement.isPoppingIn(window) else { return }
                self.scheduleActivationPolicySync()
            }
        }

        switch Self.launchPosture(
            for: provenance, keepInMenuBar: viewModel.keepInMenuBarOnQuit)
        {
        case .present:
            // Presentation only, not `summonUserInterface`: whoever launched the
            // process (Launch Services, a login-item start, Finder) already
            // requested activation, so a launch leg requests none of its own —
            // `requestSummonActivation`'s `!NSApp.isActive` guard doesn't cover
            // this moment, since the app isn't active yet this early in launch.
            // Arming the auto-start pass rides along with it.
            presentSummonedInterface()
        case .headless(armsAutoStart: true):
            setActivationPolicy(.accessory)
            // Not `markInterfacePresented`: nothing went on screen, so the
            // process has not joined the window reconcile. A later summon
            // latches it then, and its own arming call is a no-op behind the
            // delegate's once-per-process latch.
            host?.armAutoStartPass(surfacingDisplays: false)
        case .headless(armsAutoStart: false):
            setActivationPolicy(.accessory)
            // Nothing else will reconcile a process that never opens a window:
            // this is what lets it leave once the guest an intent started stops.
            observeForIdleTermination()
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
        launch: LaunchProvenance
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

    // MARK: - Status Item

    /// Builds the menu-bar status item.
    ///
    /// Extracted from ``start(provenance:)`` so ``syncStatusItem()`` can rebuild
    /// it when the residency toggle flips back on.
    private func makeStatusItemController() -> HostAgentStatusItemController {
        HostAgentStatusItemController(
            viewModel: viewModel,
            preferences: preferences,
            onOpen: { [weak self] vmID in self?.summonStatusItemTarget(for: vmID) },
            onOpenClipboard: { [weak self] vmID in
                guard let self else { return }
                guard
                    let instance = self.viewModel.instances.first(where: { $0.instanceID == vmID }),
                    self.viewModel.capabilities.accepts(.showClipboard, on: instance)
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
            onQuit: { [weak self] in self?.host?.requestFullQuit() }
        )
    }

    /// Creates or removes the status item so it exists exactly while
    /// *Continue running in Status Bar* is on.
    ///
    /// Idempotent, so the observation loop can call it on every wake.
    private func syncStatusItem() {
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
                self?.syncActivationPolicy()
            }
        )
    }

    // MARK: - Summon

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
    /// ``statusItemOpenTarget(displayPreference:canUseExternalDisplay:)``.
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

    /// What a reopen (Dock click, `open`, our own Launch Services self-open)
    /// does to the GUI, as decided by ``reopenPresentation(hasOnScreenUserWindow:)``.
    enum ReopenPresentation: Equatable {
        /// Present the library.
        case library
        /// Do nothing — a window already on screen owns the presentation.
        case nothing
    }

    /// Decides the reopen leg's presentation, so a reopen our own
    /// ``requestSummonActivation()`` self-open triggers can't drag a surface a
    /// per-VM summon didn't ask for back on screen — matching
    /// ``statusItemOpenTarget(displayPreference:canUseExternalDisplay:)``'s
    /// "opens only the chosen surface" rule.
    ///
    /// The self-open's own reopen always sees its target surface as already
    /// on screen: `summonUserInterface` enqueues the presentation `Task` on
    /// the main actor before the Launch Services request leaves the process,
    /// and the reopen Apple Event is only handled on a later main-runloop
    /// turn.
    nonisolated static func reopenPresentation(hasOnScreenUserWindow: Bool) -> ReopenPresentation {
        hasOnScreenUserWindow ? .nothing : .library
    }

    /// The resident app's reopen leg: present the library only when nothing is
    /// already on screen. Never requests activation — a reopen already carries
    /// one, and a second would make ``requestSummonActivation()``'s self-open
    /// loop.
    ///
    /// `hasVisibleWindows` is ignored: AppKit's own count answers a different
    /// question than ``reopenPresentation(hasOnScreenUserWindow:)`` — it counts
    /// no untracked panel and reads a miniaturized window as absent.
    func handleReopen(hasVisibleWindows: Bool) {
        switch Self.reopenPresentation(hasOnScreenUserWindow: hasOnScreenUserWindow) {
        case .library:
            presentSummonedInterface()
        case .nothing:
            break
        }
    }

    /// Brings the resident app's GUI forward: morph to `.regular`, request
    /// activation, and show the summoned surface.
    ///
    /// The sole path that requests activation for a summon — a launch or
    /// reopen leg presents through ``presentSummonedInterface(showing:)``
    /// directly instead, since it already has one. Idempotent.
    func summonUserInterface() {
        summonUserInterface(showing: .library)
    }

    private func summonUserInterface(showing target: SummonTarget) {
        // Morph to a regular app so the Dock icon + menu bar appear. The
        // activation request is sent synchronously here — not deferred into the
        // presentation `Task` below — because the summon owns exactly one
        // activation request per gesture; issuing it anywhere else would risk a
        // second one racing the reopen it can trigger.
        setActivationPolicy(.regular)
        let event = NSApp.currentEvent
        let eventAge = event.map { ProcessInfo.processInfo.systemUptime - $0.timestamp }
        Self.logger.debug(
            "Summon: isActive=\(NSApp.isActive, privacy: .public) hasCurrentEvent=\(event != nil, privacy: .public) eventAge=\(eventAge.map { String(format: "%.3f", $0) } ?? "n/a", privacy: .public)"
        )
        requestSummonActivation()
        presentSummonedInterface(showing: target)
    }

    /// Requests activation for a summon via Launch Services, so a menu-bar
    /// status item or Dock menu selection — delivered as a FrontBoard scene
    /// action with no `NSEvent` behind it — still lands a request WindowServer
    /// accepts.
    ///
    /// Cooperative activation stamps a request with the sending process's last
    /// user-event time; a request with no event behind it (or one sent late,
    /// after the event's stamp has gone stale) is rejected outright
    /// (`CPS: Rejecting expired request`, observed 2026-08-26 in the WindowServer
    /// log). Routing the request through Launch Services instead — which
    /// carries it on the app's behalf — sidesteps the missing/stale stamp
    /// rather than depending on one.
    ///
    /// `createsNewApplicationInstance = false` is load-bearing: without it, a
    /// resident app requesting its own activation this way can spawn a second
    /// process managing the same VM bundles.
    private func requestSummonActivation() {
        guard !NSApp.isActive else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        // Captured for the completion closure, which is `@Sendable`.
        let logger = Self.logger
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        ) { _, error in
            guard let error else { return }
            logger.error(
                "Launch Services summon activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Puts the summoned library on screen, without requesting activation.
    func presentSummonedInterface() {
        presentSummonedInterface(showing: .library)
    }

    /// Puts the summoned surface on screen, without requesting activation.
    ///
    /// Neither a launch nor a reopen requests activation here: whoever brought
    /// the process up — Launch Services on a launch (a Finder double-click, a
    /// login-item start, `open`), or the same set plus our own Launch Services
    /// self-open on a reopen — already asked for it. A launch or reopen leg
    /// that called `summonUserInterface` instead would issue a second,
    /// redundant activation request — and on the reopen leg, our own self-open
    /// would loop.
    private func presentSummonedInterface(showing target: SummonTarget) {
        // Idempotent — re-asserted here since a reopen can arrive with the
        // policy already `.regular`.
        setActivationPolicy(.regular)
        // Defer the show to the next runloop tick so the menu bar has refreshed
        // (the .accessory→.regular menu-bar quirk, FB7743313).
        Task { @MainActor in
            let summoned: NSWindow?
            switch target {
            case .library:
                self.windows.showLibrary(bringToFront: true)
                summoned = self.windows.libraryWindow
            case .display(let instance):
                self.windows.displayPlacement.showDisplayWindow(for: instance)
                summoned = self.windows.displayPlacement.window(for: instance.instanceID)
            case .clipboard(let instance):
                self.windows.showClipboard(for: instance)
                summoned = self.windows.clipboardWindow(for: instance.instanceID)
            }
            // The activation request above may still be refused; the window has
            // to arrive either way. `orderFrontRegardless` is the only ordering
            // call that doesn't depend on the app being active.
            summoned?.orderFrontRegardless()
            // Summoning from the status-item menu leaves the freshly-appeared menu
            // bar with its first menu highlighted: the status menu's dismissal
            // bleeds into the menu bar the morph just installed. Clear it.
            NSApp.mainMenu?.cancelTracking()
        }
        // After the presentation is enqueued, not before: the pass's first act
        // is to await the library read, so the deferred window show above still
        // runs first and a VM booting here finds the measurable surface
        // `applyMatchWindowBootResolution` needs. The marked VMs only exist in
        // `instances` once that read applies.
        markInterfacePresented()
    }

    /// Records that a GUI surface is going on screen: the process has joined the
    /// window reconcile, and owes the auto-start pass an automation launch
    /// deferred.
    ///
    /// Both must happen together at every presenting path. Latching the flag
    /// alone would end idle-quit *and* leave the pass unarmed for the rest of
    /// the process's life, so a display window an intent asked for would
    /// silently cost the user *Start automatically on launch*.
    private func markInterfacePresented() {
        hasPresentedInterface = true
        host?.armAutoStartPass(surfacingDisplays: true)
    }

    /// Re-asserts `.regular` before a window is shown, so a window can never be
    /// presented while the resident app is still headless `.accessory`.
    func prepareToPresentWindow() {
        // The chokepoint every window that bypasses `presentSummonedInterface`
        // passes through — a display window an `open` verb asked for, a
        // clipboard window, Settings.
        markInterfacePresented()
        setActivationPolicy(.regular)
    }

    // MARK: - Soft Quit

    /// The resident app has a headless state to downgrade a quit into, so ⌘Q and
    /// the Dock's Quit land on ``closeGUIForSoftQuit()`` rather than terminating.
    var softQuit: (any SoftQuitHosting)? { self }

    /// Never: the global `willClose` observer's reconcile decides between the
    /// Dock icon, a headless status-item app, and quitting. It keys on
    /// ``hasVisibleUserWindow``, which counts miniaturized windows and untracked
    /// panels that AppKit's own last-window rule does not, so letting AppKit
    /// terminate too would double-fire on a different predicate.
    var terminatesAfterLastWindowClosed: Bool { false }

    /// Nothing to record: the reopen leg reads the window list, not whether the
    /// activation that may precede it was the reopen's own.
    func noteWillBecomeActive() {}

    /// Closes the GUI, settles the activation policy, then anchors the soft-quit
    /// reminder — in that order.
    func closeGUIForSoftQuit() {
        windows.closeAll()
        // Settle the Dock-presence policy BEFORE anchoring the reminder. Left to
        // the deferred per-window reconciles, the popover is shown first and the
        // `.regular` → `.accessory` flip lands 20–75ms later, which re-hosts the
        // menu-bar status item and tears the just-anchored popover down with it
        // (observed: the reminder flashed for a frame and vanished).
        syncActivationPolicy()
        statusItemController?.showSoftQuitReminder()
    }

    // MARK: - Window Reconcile

    /// Whether any user-facing Kernova window is currently on screen, counting a
    /// miniaturized one as present.
    ///
    /// The Dock icon (`.regular`) must be present iff this is `true`.
    private var hasVisibleUserWindow: Bool {
        windows.hasUserWindow(countingMiniaturized: true)
    }

    /// Whether any user-facing Kernova window is currently on screen, excluding
    /// a miniaturized one.
    ///
    /// Used by the reopen leg: a reopen arriving for an app with only a
    /// miniaturized window must still present, matching AppKit's own Dock-click
    /// behavior of deminiaturizing it.
    private var hasOnScreenUserWindow: Bool {
        windows.hasUserWindow(countingMiniaturized: false)
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

    /// Reconciles the resident app with its open windows: `.regular` (Dock icon)
    /// while any user window is on screen, and when none are, either `.accessory`
    /// (status-item only) or a quit — see
    /// ``residencyOutcome(hasVisibleUserWindow:isHidden:keepInMenuBar:hasUninterruptibleWork:)``.
    ///
    /// Re-run on every window open and close so a partial close can never strand
    /// the policy.
    ///
    /// An unpresented automation launch is routed away from `residencyOutcome`
    /// entirely: that decision reads neither provenance nor in-flight intents,
    /// so a *Start VM* intent raising `hasUninterruptibleWork` would give the
    /// headless process a Dock icon, and the same work settling would quit it —
    /// save-suspending the guest the intent had just started.
    func syncActivationPolicy() {
        guard !isUnpresentedAutomationLaunch else {
            reconcileIdleTermination()
            return
        }
        switch Self.residencyOutcome(
            hasVisibleUserWindow: hasVisibleUserWindow,
            isHidden: NSApp.isHidden,
            keepInMenuBar: viewModel.keepInMenuBarOnQuit,
            hasUninterruptibleWork: viewModel.hasUninterruptibleWork
        ) {
        case .showDockIcon:
            setActivationPolicy(.regular)
        case .goHeadless:
            setActivationPolicy(.accessory)
        case .quit:
            // Latched: `applicationShouldTerminate` replies `.terminateLater` while
            // VMs save, and a window closing during that window would otherwise
            // re-enter with a reply already outstanding.
            guard !hasRequestedIdleTermination else { return }
            hasRequestedIdleTermination = true
            Self.logger.notice("Last window closed with the app set to quit — terminating")
            NSApp.terminate(nil)
        }
    }

    /// Re-runs ``syncActivationPolicy()`` on the next runloop tick — after a
    /// closing window has left the window list — so the window count is accurate.
    private func scheduleActivationPolicySync() {
        Task { @MainActor in self.syncActivationPolicy() }
    }

    /// Sets the activation policy, logging the transition.
    ///
    /// No-op when already at `policy`.
    private func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        let current = NSApp.activationPolicy()
        guard current != policy else { return }
        NSApp.setActivationPolicy(policy)
        Self.logger.notice(
            "Activation policy \(current.rawValue, privacy: .public) → \(policy.rawValue, privacy: .public) (hasVisibleWindow=\(self.hasVisibleUserWindow, privacy: .public))"
        )
    }

    // MARK: - Idle Termination

    /// What becomes of an automation-launched process once its work settles.
    enum AutomationIdleOutcome: Equatable {
        /// Keep running — headless, reachable through the status item.
        case stayResident
        /// Quit through `applicationShouldTerminate`, save-suspending anything live.
        case quit
    }

    /// Decides whether a process nobody asked to see still has a reason to run.
    ///
    /// The window reconcile (`residencyOutcome`) cannot answer this: it keys on
    /// windows, and this process has never had one, so nothing it watches will
    /// ever fire. This is the counterpart trigger — every other state hands back
    /// to the window reconcile by answering `.stayResident`.
    ///
    /// A live guest or work in flight always holds the process, whatever the
    /// residency preference: an intent that started a VM must not have it
    /// save-suspended the moment the intent returns. With *Continue running in
    /// Status Bar* on, the process stays as the user asked; with it off there is
    /// neither Dock icon nor status item, so a process that keeps running would
    /// be unreachable — it leaves instead.
    nonisolated static func automationIdleOutcome(
        isAutomationLaunch: Bool,
        hasPresentedInterface: Bool,
        hasVisibleUserWindow: Bool,
        keepInMenuBar: Bool,
        hasUninterruptibleWork: Bool,
        hasLiveGuest: Bool,
        hasIntentInFlight: Bool
    ) -> AutomationIdleOutcome {
        guard isAutomationLaunch, !hasPresentedInterface, !hasVisibleUserWindow else {
            return .stayResident
        }
        if hasIntentInFlight || hasLiveGuest || hasUninterruptibleWork { return .stayResident }
        return keepInMenuBar ? .stayResident : .quit
    }

    /// Whether the aliveness question belongs to `automationIdleOutcome` rather
    /// than to the window reconcile.
    ///
    /// True for an automation launch that has never put a surface on screen —
    /// the process `residencyOutcome` cannot speak for, because it decides from
    /// windows and this one has none and never will until someone summons it.
    private var isUnpresentedAutomationLaunch: Bool {
        launchProvenance == .automation && !hasPresentedInterface && !hasVisibleUserWindow
    }

    /// Re-decides whether the process still has a reason to run.
    ///
    /// Answered only for an automation launch that has never presented — a
    /// windowed resident app is the window reconcile's to decide, and one the
    /// user has summoned has joined it.
    func reconcileIdleTermination() {
        switch Self.automationIdleOutcome(
            isAutomationLaunch: launchProvenance == .automation,
            hasPresentedInterface: hasPresentedInterface,
            hasVisibleUserWindow: hasVisibleUserWindow,
            keepInMenuBar: viewModel.keepInMenuBarOnQuit,
            hasUninterruptibleWork: viewModel.hasUninterruptibleWork,
            hasLiveGuest: viewModel.instances.contains(where: \.isKeepingAppAlive),
            hasIntentInFlight: intentGateway?.hasIntentInFlight ?? false
        ) {
        case .stayResident:
            break
        case .quit:
            guard !hasRequestedIdleTermination else { return }
            hasRequestedIdleTermination = true
            Self.logger.notice(
                "Automation launch settled with nothing left to run — terminating")
            NSApp.terminate(nil)
        }
    }

    /// Watches guest liveness so an automation launch settles once the guest an
    /// intent started stops — hours later, with nothing else watching.
    private func observeForIdleTermination() {
        idleObservation = observeGuestLiveness(of: viewModel) { [weak self] in
            self?.reconcileIdleTermination()
        }
    }
}

// MARK: - SoftQuitHosting

/// Where a downgraded quit lands: ``closeGUIForSoftQuit()`` is the whole
/// conformance.
extension AppResidencyController: SoftQuitHosting {}

/// Observes every instance's ``VMInstance/isKeepingAppAlive`` so the process can
/// settle when the last one flips inactive.
@MainActor
func observeGuestLiveness(
    of viewModel: VMLibraryViewModel, apply: @escaping () -> Void
) -> ObservationLoop {
    observeRecurring(
        track: { [weak viewModel] in
            guard let viewModel else { return }
            for instance in viewModel.instances {
                _ = instance.isKeepingAppAlive
            }
        },
        apply: apply
    )
}
