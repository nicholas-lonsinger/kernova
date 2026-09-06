import AppIntents
import Cocoa
import KernovaKit
import os

/// The residency decisions a window owner needs but cannot make.
@MainActor
protocol WindowResidencyHosting: AnyObject {
    /// Re-asserts whatever the app must be before a window goes on screen.
    func prepareToPresentWindow()
    /// Re-decides the activation policy now, rather than on the next runloop turn.
    func syncActivationPolicy()
    /// Brings the app forward for a surface something outside the process asked
    /// for.
    ///
    /// An in-process gesture needs none of this — the user is already in the
    /// app — but a request arriving over the command socket carries no
    /// `NSEvent`, so the window it surfaces would open behind whatever the
    /// person is looking at.
    func activateForExternalRequest()
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
    /// Opens every automation front door, before any launch presentation, so a
    /// request delivered during launch is answered rather than dropped.
    func registerAutomationFrontDoors()
    /// Brings the process up for the launch it was given.
    func start(provenance: AppResidencyController.LaunchProvenance)
    /// The answer to `applicationShouldTerminateAfterLastWindowClosed(_:)`.
    var terminatesAfterLastWindowClosed: Bool { get }
    /// Records that the app is about to become active, so the reopen that may
    /// follow can tell a dock click that activated the app from one on an
    /// already-active app.
    func noteWillBecomeActive()
    /// The unhide leg — every window is back on screen after a ⌘H, so whatever
    /// the app's windows did meanwhile is now legible to a reconcile.
    func noteDidUnhide()
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
/// activation policy, the status item, and the GUI summon.
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

    /// The command socket this process bound, held for the life of the process:
    /// nothing else retains it, and a released listener stops answering.
    /// `AppDependencyManager` owns the intent gateway copy intents resolve.
    private var commandSocket: VMCommandSocketListener?

    /// The menu-bar status item — the "Kernova is running" affordance and the way
    /// to summon the GUI while headless.
    ///
    /// Present exactly while *Continue running in Status Bar* is on
    /// (``syncStatusItem()``).
    private var statusItemController: HostAgentStatusItemController?

    /// Watches the residency toggle so the status item and the reconcile follow
    /// it live.
    private var residencyObservation: ObservationLoop?

    /// Single close-side trigger for the activation-policy reconcile.
    ///
    /// Fires ``scheduleActivationPolicySync()`` when a titled window closes,
    /// tracked or not (e.g. the standard About panel) — the only closes that can
    /// change ``hasVisibleUserWindow`` (``windowCloseAffectsActivationPolicy(_:)``).
    private var globalWindowCloseObserver: Any?

    /// The unhide reconcile deferred to the next runloop tick, carrying the
    /// outcome it applied.
    private var pendingUnhideReconcile: Task<UnhideOutcome, Never>?

    /// Whether the unhide now being delivered is one ``unhideForSummon()``
    /// performed, rather than the person reversing a ⌘H.
    private var isUnhidingForSummon = false

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

    // MARK: - Automation front doors

    /// Opens both out-of-process front doors, so a request delivered during
    /// launch is answered rather than failing for a door that isn't there yet.
    ///
    /// The App Intents gateway is retained by the dependency manager and lives
    /// as long as the process. It takes the app's first library read as its
    /// readiness await: an intent can arrive while that read is still in
    /// flight, and a verb run against a library that has not landed yet finds
    /// no VM to address.
    ///
    /// The command socket binds in the app-group container, admitting peers
    /// this build's own team signed. A build resolving neither a container nor
    /// a team publishes no socket and the CLI finds nothing to connect to. It
    /// takes the same readiness await for the same reason: it is bound before
    /// the library read lands, so that a tool which just launched the app finds
    /// something to connect to.
    func registerAutomationFrontDoors() {
        let gateway = VMIntentGateway(
            commands: viewModel.commands,
            awaitReady: { [weak self] in
                guard let self else { return }
                await self.awaitLibraryReady()
            },
            surfaceLibrary: { [weak self] in self?.presentSummonedInterface() })
        AppDependencyManager.shared.add(dependency: gateway)

        let socket = VMCommandSocketListener(
            router: VMCommandEnvelopeRouter(commands: viewModel.commands),
            authorizer: SameTeamPeerAuthorizer(),
            socketPath: KernovaAppGroup.socketPath(),
            awaitReady: { [weak self] in
                guard let self else { return }
                await self.awaitLibraryReady()
            },
            onSurfaceRequested: { [weak self] in self?.activateForExternalRequest() })
        socket.start()
        commandSocket = socket
    }

    /// Awaits the app's first library read on the main actor, so the gateway's
    /// `@Sendable` readiness closure only ever captures this controller.
    private func awaitLibraryReady() async {
        await host?.awaitLibraryReady()
    }

    // MARK: - Start

    /// What a launch asked for: who performed it, and whether it asked for the
    /// app hidden.
    struct LaunchProvenance: Equatable {
        /// Who performed the launch.
        enum Origin: String, Equatable {
            /// Anything a person or a launcher did — a double-click, `open`,
            /// the Dock, a Shortcut, the `kernova` tool.
            case user
            /// The system opened the app at login, on the user's standing
            /// request.
            case loginItem
        }

        let origin: Origin

        /// Whether the app came up hidden, read from `NSApp.isHidden`.
        ///
        /// An opener that asks for the app hidden has asked for no window. An
        /// App Intents launch is one of them: measured on macOS 27 (26A5425a)
        /// on 2026-09-04, the system brings such a launch up hidden. The
        /// `kernova` tool asks for the same thing by passing `hides`.
        let isHidden: Bool
    }

    /// How a launch brings the process up, as decided by
    /// ``launchPosture(for:keepInMenuBar:)``.
    enum LaunchPosture: Equatable {
        /// Put the library on screen. A hidden launch still creates it, behind
        /// the hide, so the Dock icon a person clicks has something to show.
        case present
        /// `.accessory`, no window.
        case headless
    }

    /// Decides what a launch puts on screen.
    ///
    /// A launch that asked for no window — hidden — and a login launch are the
    /// same request: have Kernova running, not be shown it. Both come up as the
    /// status-item app, which is the affordance that then reaches the GUI. With
    /// *Continue running in Status Bar* off there is no status item, so a
    /// headless process would be unreachable and every launch presents instead
    /// — behind the hide for a hidden one, where the Dock icon is what reaches
    /// it.
    ///
    /// Either way the auto-start pass runs, as it does on every launch, and the
    /// process stays until somebody quits it.
    nonisolated static func launchPosture(
        for provenance: LaunchProvenance, keepInMenuBar: Bool
    ) -> LaunchPosture {
        guard keepInMenuBar else { return .present }
        return provenance.origin == .loginItem || provenance.isHidden ? .headless : .present
    }

    /// Brings the resident app up in the posture
    /// ``launchPosture(for:keepInMenuBar:)`` gives the launch.
    ///
    /// The status item, the residency observation and the window-close reconcile
    /// are set up for every provenance — they are what the process needs to be
    /// reachable and to answer for itself, whoever started it. The two postures
    /// differ only in what goes on screen; both arm the auto-start pass, so VMs
    /// marked `VMConfiguration.startsAutomaticallyOnLaunch` come up once the
    /// library read lands, surfacing their displays only where there is a GUI
    /// to surface into.
    ///
    /// `.headless` drops straight to `.accessory` — deliberately *not* through
    /// ``syncActivationPolicy()``, which reads a window list this launch has not
    /// built yet.
    func start(provenance: LaunchProvenance) {
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
        case .headless:
            setActivationPolicy(.accessory)
            // Not `armAutoStartForPresentation`: nothing went on screen, so a
            // guest booting here has no window to surface into. A later summon
            // asks for surfacing, and its own arming call is a no-op behind the
            // delegate's once-per-process latch.
            host?.armAutoStartPass(surfacingDisplays: false)
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
        "bundle=\(bundlePath) build=\(build) config=\(configuration) "
            + "vmNetworking=\(vmNetworkingEntitled ? "entitled" : "unentitled") "
            + "launch=\(launch.origin.rawValue) hidden=\(launch.isHidden)"
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
        // Last, after the presentation is enqueued: the unhide notification can
        // be delivered inside the call, and the reconcile it schedules must run
        // behind the window show rather than reading a window list the show has
        // not reached yet.
        unhideForSummon()
    }

    /// Leaves the hidden state, so a surface this summon puts on screen is
    /// actually on it.
    ///
    /// A launch that asked for the app hidden — `kernova`'s `hides`, an App
    /// Intents launch — stays hidden for the life of the process, and a hidden
    /// app displays no window however it is ordered, `orderFrontRegardless`
    /// included. Only a summon does this: a launch that presents deliberately
    /// builds its library behind the hide, where the Dock icon is what brings
    /// it forward.
    private func unhideForSummon() {
        guard NSApp.isHidden else { return }
        Self.logger.notice("Summoned while hidden — unhiding")
        // Scoped across the call, which is what `applicationDidUnhide` is
        // delivered inside: the summon is already deciding what goes on screen,
        // and the unhide leg would otherwise read a window list the
        // presentation has not reached yet and demote the app mid-summon.
        isUnhidingForSummon = true
        NSApp.unhide(nil)
        isUnhidingForSummon = false
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
        armAutoStartForPresentation()
    }

    /// Arms the auto-start pass for a GUI surface going on screen, so the guests
    /// it boots can surface their displays.
    ///
    /// Every presenting path calls it; the delegate's once-per-process latch is
    /// what makes the second call a no-op.
    private func armAutoStartForPresentation() {
        host?.armAutoStartPass(surfacingDisplays: true)
    }

    /// Re-asserts `.regular` before a window is shown, so a window can never be
    /// presented while the resident app is still headless `.accessory`.
    func activateForExternalRequest() {
        unhideForSummon()
        setActivationPolicy(.regular)
        requestSummonActivation()
    }

    func prepareToPresentWindow() {
        // The chokepoint every window that bypasses `presentSummonedInterface`
        // passes through — a display window an `open` verb asked for, a
        // clipboard window, Settings.
        armAutoStartForPresentation()
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

    /// Closes the GUI, drops to the status item, then anchors the soft-quit
    /// reminder — in that order.
    ///
    /// `.accessory` is asserted rather than reconciled: this path has just
    /// closed every window and is only reached with *Continue running in Status
    /// Bar* on (``AppTerminationController/shouldTerminateOnQuit``), so it knows
    /// the answer the reconcile would have to infer — and while the app is
    /// hidden the reconcile deliberately infers nothing, which would leave a
    /// window-less app holding a Dock icon that only an unhide could clear.
    func closeGUIForSoftQuit() {
        windows.closeAll()
        // Drop the Dock presence BEFORE anchoring the reminder. Left to the
        // deferred per-window reconciles, the popover is shown first and the
        // `.regular` → `.accessory` flip lands 20–75ms later, which re-hosts the
        // menu-bar status item and tears the just-anchored popover down with it
        // (observed: the reminder flashed for a frame and vanished).
        setActivationPolicy(.accessory)
        statusItemController?.showSoftQuitReminder()
    }

    // MARK: - Window Reconcile

    /// Whether any user-facing Kernova window is currently on screen, counting a
    /// miniaturized one as present.
    ///
    /// The Dock icon (`.regular`) must be present iff this is `true` — except
    /// while the app is hidden, where every window reads `false` and the
    /// reconcile leaves the policy the app already had (``ResidencyOutcome/waitForUnhide``).
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
        /// Leave the app as it is — hidden, it is not the app's windows the
        /// reconcile would be reading. ``noteDidUnhide()`` decides once they are
        /// legible again.
        case waitForUnhide
    }

    /// Decides the reconcile's outcome.
    ///
    /// With *Continue running in Status Bar* off there is neither a Dock icon nor
    /// a status item, so a headless app would be unreachable — the last window
    /// close quits instead of demoting.
    ///
    /// Two things hold that off:
    ///
    /// - **Hiding.** ⌘H makes every window report `isVisible == false` without
    ///   closing any of them, so a hidden app's windows are open windows the
    ///   reconcile simply cannot see, and it reads the same as an app whose last
    ///   window closed. It decides nothing there — a hidden app keeps the Dock
    ///   icon a presented one had, and a background close landing mid-hide (a VM
    ///   shutting down empties its display window) is answered by
    ///   ``unhideOutcome(hasVisibleUserWindow:keepInMenuBar:)``. What *Continue
    ///   running in Status Bar* governs is the last close, not a hide.
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
        if isHidden { return .waitForUnhide }
        if keepInMenuBar { return .goHeadless }
        if hasUninterruptibleWork { return .showDockIcon }
        return .quit
    }

    /// Reconciles the resident app with its open windows: `.regular` (Dock icon)
    /// while any user window is on screen, and when none are, either `.accessory`
    /// (status-item only) or a quit — see
    /// ``residencyOutcome(hasVisibleUserWindow:isHidden:keepInMenuBar:hasUninterruptibleWork:)``.
    ///
    /// Re-run on every window open and close, and on the unhide that makes a
    /// hidden app's windows legible again, so a partial close can never strand
    /// the policy.
    func syncActivationPolicy() {
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
        case .waitForUnhide:
            break
        case .quit:
            Self.logger.notice("Last window closed with the app set to quit — terminating")
            host?.requestFullQuit()
        }
    }

    /// What an unhide does with the resident app.
    enum UnhideOutcome: Equatable {
        /// Show the Dock icon — windows came back with the app.
        case showDockIcon
        /// Drop to a status-item-only app: the last window closed during the
        /// hide, which is the close *Continue running in Status Bar* answers.
        case goHeadless
        /// Put the library back on screen — nothing survived the hide, and with
        /// no status item a headless app would be unreachable.
        case presentLibrary
    }

    /// Decides what the unhide does, which is never a quit.
    ///
    /// Unhiding is a request for the app, so the close that landed mid-hide is
    /// answered by making the app reachable — never by terminating under the
    /// person who just asked for it. A window close is what quits this app, and
    /// no close is observable from here: the hide swallowed whichever one
    /// happened, and AppKit's unhide restores the windows that are left.
    nonisolated static func unhideOutcome(
        hasVisibleUserWindow: Bool, keepInMenuBar: Bool
    ) -> UnhideOutcome {
        if hasVisibleUserWindow { return .showDockIcon }
        return keepInMenuBar ? .goHeadless : .presentLibrary
    }

    /// Runs the decision a hide deferred: every window a hidden app has reports
    /// `isVisible == false`, so a close landing meanwhile is only legible once
    /// the app is back on screen.
    ///
    /// Deliberately not ``syncActivationPolicy()``: that one quits an app whose
    /// last window closed, and an unhide is the one moment where a person has
    /// just asked for the app.
    ///
    /// An unhide ``unhideForSummon()`` performed is not that moment and decides
    /// nothing: the summon that asked for it is already putting a surface up.
    func noteDidUnhide() {
        guard !isUnhidingForSummon else { return }
        pendingUnhideReconcile = Task { @MainActor in self.reconcileUnhide() }
    }

    /// Applies ``unhideOutcome(hasVisibleUserWindow:keepInMenuBar:)`` to the app
    /// AppKit has just brought back, and reports what it applied.
    private func reconcileUnhide() -> UnhideOutcome {
        let outcome = Self.unhideOutcome(
            hasVisibleUserWindow: hasVisibleUserWindow,
            keepInMenuBar: viewModel.keepInMenuBarOnQuit)
        switch outcome {
        case .showDockIcon:
            setActivationPolicy(.regular)
        case .goHeadless:
            Self.logger.notice("Unhidden with no window left — dropping to the status item")
            setActivationPolicy(.accessory)
        case .presentLibrary:
            Self.logger.notice("Unhidden with no window left — showing the library")
            presentSummonedInterface()
        }
        return outcome
    }

    /// Re-runs ``syncActivationPolicy()`` on the next runloop tick — after a
    /// closing window has left the window list — so the window count is accurate.
    private func scheduleActivationPolicySync() {
        Task { @MainActor in self.syncActivationPolicy() }
    }

    #if DEBUG
    /// The deferred unhide reconcile, which a test awaits for the outcome it
    /// applied rather than polling for that outcome's effect.
    var pendingUnhideReconcileForTesting: Task<UnhideOutcome, Never>? { pendingUnhideReconcile }
    #endif

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
