import AppIntents
import Cocoa
import KernovaKit
import KernovaLogging

/// What the app is presenting, read at the moment a VM comes up.
enum GUIPosture: Equatable {
    /// Status-item-only (`.accessory`): no window may appear.
    case absent
    /// Windows exist but another app is frontmost.
    case background
    /// Kernova is the active app.
    case foreground
}

/// The residency decisions a window owner needs but cannot make.
@MainActor
protocol WindowResidencyHosting: AnyObject {
    /// Re-asserts whatever the app must be before a window goes on screen.
    func prepareToPresentWindow()
    /// Re-decides the activation policy now, rather than on the next runloop turn.
    func syncActivationPolicy()
    /// What the app is presenting, for a window deciding whether — and how — to
    /// go on screen.
    var guiPosture: GUIPosture { get }
}

/// The launch-cluster seam a residency needs but cannot own: the auto-start
/// pass, the first library read, and the true quit.
@MainActor
protocol AppLaunchHosting: AnyObject {
    /// Arms the pass that brings up the VMs marked to start automatically, once
    /// per process.
    func armAutoStartPass()
    /// Awaits the app's first library read.
    func awaitLibraryReady() async
    /// Terminates the app unconditionally, bypassing the keep-in-menu-bar
    /// downgrade.
    func requestFullQuit()
}

/// The one owner of what the process *is* when no window is on screen: the
/// activation policy, the status item, and the GUI summon.
@MainActor
final class AppResidencyController: WindowResidencyHosting {
    private let viewModel: VMLibraryViewModel
    /// The one owner of which user-facing windows exist; every presentation and
    /// the window half of every reconcile goes through it.
    private let windows: AppWindowRegistry
    /// The launch cluster this residency reaches back into.
    weak var host: (any AppLaunchHosting)?

    /// The command socket this process bound, held for the life of the process:
    /// nothing else retains it, and a released listener stops answering.
    /// `AppDependencyManager` owns the intent gateway copy intents resolve.
    private var commandSocket: VMCommandSocketListener?

    /// The `kernova:` link front door, held for the life of the process:
    /// nothing else retains it.
    private var urlGateway: VMURLGateway?

    /// The Apple event front door, held for the life of the process: Cocoa
    /// builds a fresh `NSScriptCommand` per event and this is what each one
    /// finds through the delegate.
    private(set) var scriptingGateway: VMScriptingGateway?

    /// The menu-bar status item — the "Kernova is running" affordance and the way
    /// to summon the GUI while headless.
    ///
    /// Present exactly while *Continue running in the menu bar* is on
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

    /// The process-wide calls that take the app out of hiding and ask for it
    /// to be frontmost.
    private let foreground: ForegroundControl

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppResidency")

    init(
        viewModel: VMLibraryViewModel, windows: AppWindowRegistry,
        foreground: ForegroundControl = .live
    ) {
        self.viewModel = viewModel
        self.windows = windows
        self.foreground = foreground
    }

    /// The `NSApplication` calls that take the app out of hiding and ask for it
    /// to be frontmost, which a test replaces to drive a summon without hiding
    /// or activating the test host.
    struct ForegroundControl: Sendable {
        /// Whether the app is hidden.
        var isHidden: @MainActor @Sendable () -> Bool
        /// Leaves the hidden state without asking for activation.
        var unhideWithoutActivation: @MainActor @Sendable () -> Void
        /// Asks for activation; a no-op while the app is already active.
        var activate: @MainActor @Sendable () -> Void

        static let live = ForegroundControl(
            isHidden: { NSApp.isHidden },
            unhideWithoutActivation: { NSApp.unhideWithoutActivation() },
            activate: {
                guard !NSApp.isActive else { return }
                NSApp.activate()
            })
    }

    // MARK: - Automation front doors

    /// Opens every out-of-process front door, so a request delivered during
    /// launch is answered rather than failing for a door that isn't there yet.
    ///
    /// Every door shares one ``LibraryReadiness`` and waits on it before any
    /// verb: each is open before the app's first library read lands — which is
    /// the point, so that a request arriving during launch finds something to
    /// answer it — and a verb run against a library that has not landed yet
    /// finds no VM to address.
    ///
    /// The App Intents gateway is retained by the dependency manager and lives
    /// as long as the process. The command socket takes `copyClaim` and binds
    /// where it says, admitting peers this build's own team signed; a build with
    /// no claim or no team publishes no socket and the CLI finds nothing to
    /// connect to.
    func registerAutomationFrontDoors(copyClaim: Result<AppCopyClaim, AppCopyClaim.Unavailable>) {
        let readiness = LibraryReadiness(
            awaitReady: { [weak self] in
                guard let self else { return }
                await self.awaitLibraryReady()
            })
        let gateway = VMIntentGateway(
            commands: viewModel.commands,
            readiness: readiness,
            surfaceLibrary: { [weak self] in self?.presentSummonedInterface() })
        AppDependencyManager.shared.add(dependency: gateway)

        viewModel.attachSourceAuthority(PowerboxSourceAuthority())
        let socket = VMCommandSocketListener(
            router: VMCommandEnvelopeRouter(commands: viewModel.commands),
            authorizer: SameTeamPeerAuthorizer(),
            copyClaim: copyClaim,
            awaitReady: { await readiness.ready() },
            prepareToSurface: { [weak self] in self?.prepareForExternalSurface() })
        socket.start()
        commandSocket = socket

        urlGateway = VMURLGateway(
            commands: viewModel.commands,
            readiness: readiness,
            prepareToSurface: { [weak self] in self?.prepareForExternalSurface() },
            summonLibrary: { [weak self] in self?.presentSummonedInterface() },
            present: { [weak self] refusal in
                self?.viewModel.surfaceUnawaitedFailure(refusal)
            })

        scriptingGateway = VMScriptingGateway(
            commands: viewModel.commands, readiness: readiness,
            prepareToSurface: { [weak self] in self?.prepareForExternalSurface() })
    }

    /// Answers one `kernova:` link delivered to `application(_:open:)`.
    func openAutomationLink(_ url: URL) {
        guard let urlGateway else {
            #log(Self.logger, .warning, "A Kernova link arrived before the automation doors opened")
            return
        }
        Task { await urlGateway.handle(url) }
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
    /// *Continue running in the menu bar* off there is no status item, so a
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
    /// differ only in what goes on screen; both arm the same auto-start pass, so
    /// VMs marked `VMHostState.startsAutomaticallyOnLaunch` come up once the
    /// library read lands.
    ///
    /// `.headless` drops straight to `.accessory` — *not* through
    /// ``syncActivationPolicy()``, which reads a window list this launch has not
    /// built yet.
    func start(provenance: LaunchProvenance) {
        let line = Self.residentProvenanceLine(
            bundlePath: Bundle.main.bundlePath,
            build: Self.buildNumber,
            configuration: Self.buildConfiguration,
            vmNetworkingEntitled: viewModel.entitlements.hasVMNetworking,
            launch: provenance)
        #log(Self.logger, .notice, "Kernova resident app ready — \(line, privacy: .public)")
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
            // process (Launch Services, a login-item start, Finder) decides
            // whether it comes forward, and a hidden launch stays hidden. Arming
            // the auto-start pass rides along with it.
            presentSummonedInterface()
        case .headless:
            setActivationPolicy(.accessory)
            host?.armAutoStartPass()
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
            #log(logger, .fault, "CFBundleVersion not found in Info.plist")
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
            onOpen: { [weak self] entryID in self?.summonStatusItemTarget(for: entryID) },
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
    /// *Continue running in the menu bar* is on.
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

    /// Summons the surface the status item's per-VM commands land on — the one
    /// ``VMCapabilityCatalog/revealSurface(for:)`` names, so a click here and a
    /// `reveal` from any other door bring the same window forward.
    ///
    /// Summons *only* that surface: bringing one VM forward must not drag the
    /// library or other VMs' windows back on screen, and summoning the library
    /// ("Open Kernova") must not restore any display windows.
    ///
    /// An arrival's row opens the library with the arrival selected, since the
    /// library is its only surface. A `nil` or unknown id opens the library,
    /// which is where a VM that has left the library is looked for.
    func summonStatusItemTarget(for entryID: UUID?) {
        guard
            let entry = entryID.flatMap({ id in
                viewModel.entries.first(where: { $0.id == id })
            })
        else {
            summonUserInterface()
            return
        }
        viewModel.selectedID = entry.id
        guard let instance = entry.vm else {
            summonUserInterface()
            return
        }
        switch viewModel.capabilities.revealSurface(for: instance) {
        case .displayWindow:
            summonUserInterface(showing: .display(instance))
        case .library:
            summonUserInterface()
        }
    }

    /// What a reopen (a Dock click, `open`) does to the GUI, as decided by
    /// ``reopenPresentation(hasOnScreenUserWindow:)``.
    enum ReopenPresentation: Equatable {
        /// Present the library.
        case library
        /// Do nothing — a window already on screen owns the presentation.
        case nothing
    }

    /// Decides the reopen leg's presentation: a window already on screen owns
    /// it, so a reopen never drags the library forward over a per-VM display or
    /// clipboard window the status item opened alone — matching
    /// ``summonStatusItemTarget(for:)``'s "opens only the chosen surface" rule.
    nonisolated static func reopenPresentation(hasOnScreenUserWindow: Bool) -> ReopenPresentation {
        hasOnScreenUserWindow ? .nothing : .library
    }

    /// The resident app's reopen leg: present the library only when nothing is
    /// already on screen. Never requests activation — a reopen already carries
    /// one.
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

    /// Brings the resident app's GUI forward for an in-app click — the status
    /// item, its clipboard notice, the Dock menu: morph to `.regular`, show the
    /// summoned surface, then ask for activation.
    ///
    /// The sole path that asks for activation itself — a launch or reopen leg
    /// presents through ``presentSummonedInterface()`` instead, since whoever
    /// delivered it already asked. Idempotent.
    func summonUserInterface() {
        summonUserInterface(showing: .library)
    }

    private func summonUserInterface(showing target: SummonTarget) {
        let event = NSApp.currentEvent
        let eventAge = event.map { ProcessInfo.processInfo.systemUptime - $0.timestamp }
        #log(
            Self.logger, .debug,
            "Summon: isActive=\(NSApp.isActive, privacy: .public) hasCurrentEvent=\(event != nil, privacy: .public) eventAge=\(eventAge.map { String(format: "%.3f", $0) } ?? "n/a", privacy: .public)"
        )
        presentSummonedInterface(showing: target, arrival: .summoned)
    }

    /// Who asks for activation when a surface goes on screen.
    private enum Arrival {
        /// A launch, a reopen, a document open or an App Intent: whoever
        /// delivered it already asked, so the app asks nothing.
        case delivered
        /// An in-app click: the app leaves the hidden state, orders the surface
        /// front, and asks for activation itself.
        case summoned
    }

    /// Puts the summoned library on screen without requesting activation, for
    /// a request whose deliverer already asked for it — a launch, a reopen, a
    /// document open, a link, an App Intent.
    func presentSummonedInterface() {
        presentSummonedInterface(showing: .library, arrival: .delivered)
    }

    /// Puts `target` on screen, and for a summon asks for activation once it is
    /// ordered front.
    private func presentSummonedInterface(showing target: SummonTarget, arrival: Arrival) {
        // Idempotent — re-asserted here since a reopen can arrive with the
        // policy already `.regular`.
        setActivationPolicy(.regular)
        // Defer the show to the next runloop tick so the menu bar has refreshed
        // (the .accessory→.regular menu-bar quirk, FB7743313).
        Task { @MainActor in
            if arrival == .summoned { self.leaveHiddenState() }
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
            // Activation may be refused; the window has to arrive either way.
            // `orderFrontRegardless` is the only ordering call that doesn't
            // depend on the app being active.
            summoned?.orderFrontRegardless()
            // After the order-front: WindowServer denies an activation request
            // from an app presenting no window (`CPS: … presents 0 windows …
            // Denying the request`, #1377's macOS 27 probe).
            if arrival == .summoned { self.foreground.activate() }
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
        host?.armAutoStartPass()
    }

    /// Leaves the hidden state without asking for activation, so the surface
    /// the caller puts up next is actually on screen.
    ///
    /// A launch that asked for the app hidden — `kernova`'s `hides`, an App
    /// Intents launch — stays hidden for the life of the process, and a hidden
    /// app displays no window however it is ordered, `orderFrontRegardless`
    /// included. A `.present` launch builds its library behind the hide, where
    /// the Dock icon is what brings it forward, so only a summon and an
    /// outside request call this.
    ///
    /// A summon puts its surface up in the same main-actor job: the unhide
    /// reconcile ``noteDidUnhide()`` schedules runs as a later job and reads
    /// the window list, where a surface not yet shown would read as a window
    /// closed during the hide.
    private func leaveHiddenState() {
        guard foreground.isHidden() else { return }
        #log(Self.logger, .notice, "Surfacing while hidden — unhiding")
        foreground.unhideWithoutActivation()
    }

    /// Readies the app to put up a surface something outside the process asked
    /// for, without activating it.
    ///
    /// Anything the app does to activate itself is refused with no user event
    /// behind it, so this asks for none. Whoever holds the request activates
    /// the app: the `kernova` tool by pid, a link's opener through its Launch
    /// Services request, a script that says `activate`. Reached through
    /// ``ActivationRequester/requestActivation()``, once the verb has passed
    /// its checks and is about to surface.
    private func prepareForExternalSurface() {
        setActivationPolicy(.regular)
        leaveHiddenState()
    }

    /// What the resident app is presenting.
    ///
    /// The activation policy is the whole signal for absence: `.accessory` is
    /// asserted exactly while the app is status-item-only — a login or hidden
    /// launch (``start(provenance:)``) and a soft quit
    /// (``closeGUIForSoftQuit()``) — and every path that puts a window up
    /// asserts `.regular` first, through ``prepareToPresentWindow()`` or
    /// ``presentSummonedInterface()``. ``syncActivationPolicy()`` then keeps
    /// the two in step for the life of the process.
    var guiPosture: GUIPosture {
        guard NSApp.activationPolicy() == .regular else { return .absent }
        return NSApp.isActive ? .foreground : .background
    }

    /// Re-asserts `.regular` before a window is shown, so a window can never be
    /// presented while the resident app is still headless `.accessory`.
    func prepareToPresentWindow() {
        // The chokepoint every window that bypasses `presentSummonedInterface`
        // passes through — a display window an `open` verb asked for, a
        // clipboard window, Settings.
        host?.armAutoStartPass()
        setActivationPolicy(.regular)
    }

    // MARK: - Soft Quit

    /// Closes the GUI, drops to the status item, then anchors the soft-quit
    /// reminder — in that order.
    ///
    /// `.accessory` is asserted rather than reconciled: this path has just
    /// closed every window and is only reached with *Continue running in the
    /// menu bar* on (``AppTerminationController/shouldTerminateOnQuit``), so it knows
    /// the answer the reconcile would have to infer — and while the app is
    /// hidden the reconcile infers nothing, which would leave a window-less app
    /// holding a Dock icon that only an unhide could clear.
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
    /// flipping the app back to `.accessory` mid-summon.
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
    /// With *Continue running in the menu bar* off there is neither a Dock icon nor
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
    ///   running in the menu bar* governs is the last close, not a hide.
    /// - **Work in flight.** Termination abandons the creates, clones and imports
    ///   still writing (`abandonArrivalsForTermination()`) and hard-aborts a VM that is
    ///   mid-save, mid-restore, mid-start or mid-install — `applicationShouldTerminate`
    ///   only save-suspends VMs already settled at `.running` or `.paused`. An
    ///   ordinary window close must not destroy that work, so it keeps the Dock
    ///   icon (not headless — the app has to stay reachable to show progress)
    ///   until the work settles and the observation re-runs this.
    ///
    /// A settled `.running` VM does *not* hold the quit back:
    /// `applicationShouldTerminate` save-suspends it.
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
            #log(Self.logger, .notice, "Last window closed with the app set to quit — terminating")
            host?.requestFullQuit()
        }
    }

    /// What an unhide does with the resident app.
    enum UnhideOutcome: Equatable {
        /// Show the Dock icon — windows came back with the app.
        case showDockIcon
        /// Drop to a status-item-only app: the last window closed during the
        /// hide, which is the close *Continue running in the menu bar* answers.
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
    /// Not ``syncActivationPolicy()``: that one quits an app whose last
    /// window closed, and an unhide is the one moment where a person has just
    /// asked for the app.
    ///
    /// A summon's unhide runs this too, and finds the summoned surface already
    /// on screen (``leaveHiddenState()``).
    func noteDidUnhide() {
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
            #log(Self.logger, .notice, "Unhidden with no window left — dropping to the status item")
            setActivationPolicy(.accessory)
        case .presentLibrary:
            #log(Self.logger, .notice, "Unhidden with no window left — showing the library")
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
        #log(
            Self.logger, .notice,
            "Activation policy \(current.rawValue, privacy: .public) → \(policy.rawValue, privacy: .public) (hasVisibleWindow=\(self.hasVisibleUserWindow, privacy: .public))"
        )
    }
}

// MARK: - SoftQuitHosting

/// Where a downgraded quit lands: ``closeGUIForSoftQuit()`` is the whole
/// conformance.
extension AppResidencyController: SoftQuitHosting {}
