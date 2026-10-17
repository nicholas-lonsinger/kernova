import AppIntents
import Cocoa
import KernovaCore
import KernovaKit
import KernovaLogging

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
    /// The alerts waiting for a window, which the status item reports.
    private let heldAlerts: HeldAlerts
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

    /// The app's activation policy, hidden state and activation.
    private let presence: any AppPresence

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppResidency")

    init(
        viewModel: VMLibraryViewModel, windows: AppWindowRegistry, heldAlerts: HeldAlerts,
        presence: any AppPresence
    ) {
        self.viewModel = viewModel
        self.windows = windows
        self.heldAlerts = heldAlerts
        self.presence = presence
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
            showSearchResults: { [weak self] term in self?.presentSearchResults(for: term) })
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

    /// Brings the resident app up in the posture
    /// ``AppResidencyPolicy/launchPosture(for:keepInMenuBar:)`` gives the launch.
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
    func start(provenance: AppResidencyPolicy.LaunchProvenance) {
        let line = AppResidencyPolicy.residentProvenanceLine(
            bundlePath: viewModel.library.bundleProducts.bundleURL.path,
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

        switch AppResidencyPolicy.launchPosture(
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

    // MARK: - Status Item

    /// Builds the menu-bar status item.
    ///
    /// Extracted from ``start(provenance:)`` so ``syncStatusItem()`` can rebuild
    /// it when the residency toggle flips back on.
    private func makeStatusItemController() -> HostAgentStatusItemController {
        HostAgentStatusItemController(
            viewModel: viewModel,
            heldAlerts: heldAlerts,
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
                self.viewModel.selectRevealing(vmID)
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
        /// The library window with its sidebar shown, where a search's results
        /// are listed.
        case librarySidebar
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
        viewModel.selectRevealing(entry.id)
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

    /// The resident app's reopen leg: present the library only when no user
    /// window — a miniaturized one included, which AppKit deminiaturizes —
    /// remains once the app is out of hiding. Never requests activation — the
    /// reopen's deliverer already did.
    func handleReopen() {
        let wasHidden = presence.isHidden
        // Only a windowless app is ever `.accessory`, and a windowless reopen
        // presents, so this is the policy any show lands on — asserted a tick
        // ahead of it for the menu-bar quirk (FB7743313).
        setActivationPolicy(.regular)
        Task { @MainActor in
            // A reopen can arrive before the system's own unhide (Chromium's
            // `FocusWindowSetOnCurrentSpace`: "this call races with the system
            // unhiding the application"), and a hidden app's windows all read
            // `isVisible == false` — so the unhide comes first, and the show
            // shares its job (``leaveHiddenState()``).
            self.leaveHiddenState()
            let presentation = AppResidencyPolicy.reopenPresentation(
                hasVisibleUserWindow: self.hasVisibleUserWindow)
            #log(
                Self.logger, .notice,
                "Reopen: wasHidden=\(wasHidden, privacy: .public) presentation=\(String(describing: presentation), privacy: .public)"
            )
            switch presentation {
            case .library:
                self.putOnScreen(.library)
            case .nothing:
                break
            }
        }
    }

    /// Brings the resident app's GUI forward for an in-app click — the status
    /// item, its clipboard notice, the Dock menu: morph to `.regular`, show the
    /// summoned surface, then ask for activation.
    ///
    /// The sole path that asks for activation itself — a launch leg presents
    /// through ``presentSummonedInterface()`` and a reopen through
    /// ``handleReopen()`` instead, since whoever delivered it already asked.
    /// Idempotent.
    func summonUserInterface() {
        summonUserInterface(showing: .library)
    }

    private func summonUserInterface(showing target: SummonTarget) {
        let event = NSApp.currentEvent
        let eventAge = event.map { ProcessInfo.processInfo.systemUptime - $0.timestamp }
        #log(
            Self.logger, .debug,
            "Summon: isActive=\(self.presence.isActive, privacy: .public) hasCurrentEvent=\(event != nil, privacy: .public) eventAge=\(eventAge.map { String(format: "%.3f", $0) } ?? "n/a", privacy: .public)"
        )
        presentSummonedInterface(showing: target, arrival: .summoned)
    }

    /// Who asks for activation when a surface goes on screen.
    private enum Arrival {
        /// A launch, a document open or an App Intent: whoever delivered it
        /// already asked, so the app asks nothing.
        case delivered
        /// An in-app click: the app leaves the hidden state, orders the surface
        /// front, and asks for activation itself.
        case summoned
    }

    /// Puts the summoned library on screen without requesting activation, for
    /// a request whose deliverer already asked for it — a launch, a document
    /// open, a link, an App Intent.
    func presentSummonedInterface() {
        presentSummonedInterface(showing: .library, arrival: .delivered)
    }

    /// Fills the library's search with `term` and puts the library on screen
    /// with its sidebar shown, as ``presentSummonedInterface()`` does — what
    /// an App Intent's search lands on.
    func presentSearchResults(for term: String) {
        viewModel.library.showSearchResults(for: term)
        presentSummonedInterface(showing: .librarySidebar, arrival: .delivered)
    }

    /// Puts `target` on screen, and for a summon asks for activation once it is
    /// ordered front.
    private func presentSummonedInterface(showing target: SummonTarget, arrival: Arrival) {
        setActivationPolicy(.regular)
        // Defer the show to the next runloop tick so the menu bar has refreshed
        // (the .accessory→.regular menu-bar quirk, FB7743313).
        Task { @MainActor in
            if arrival == .summoned { self.leaveHiddenState() }
            self.putOnScreen(target)
            // After the order-front: WindowServer denies an activation request
            // from an app presenting no window (`CPS: … presents 0 windows …
            // Denying the request`, #1377's macOS 27 probe).
            if arrival == .summoned { self.presence.activate() }
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

    /// Shows `target` and orders it front whether or not the app is active.
    private func putOnScreen(_ target: SummonTarget) {
        let summoned: NSWindow?
        switch target {
        case .library:
            windows.showLibrary(bringToFront: true)
            summoned = windows.libraryWindow
        case .librarySidebar:
            windows.showLibrary(bringToFront: true)
            windows.revealLibrarySidebar()
            summoned = windows.libraryWindow
        case .display(let instance):
            windows.displayPlacement.showDisplayWindow(for: instance)
            summoned = windows.displayPlacement.window(for: instance.instanceID)
        case .clipboard(let instance):
            windows.showClipboard(for: instance)
            summoned = windows.clipboardWindow(for: instance.instanceID)
        }
        // Activation may be refused; the window has to arrive either way.
        // `orderFrontRegardless` is the only ordering call that doesn't
        // depend on the app being active.
        summoned?.orderFrontRegardless()
    }

    /// Leaves the hidden state without asking for activation, so the surface
    /// the caller puts up next is actually on screen.
    ///
    /// A launch that asked for the app hidden — `kernova`'s `hides`, an App
    /// Intents launch — stays hidden for the life of the process, and a hidden
    /// app displays no window however it is ordered, `orderFrontRegardless`
    /// included. A `.present` launch builds its library behind the hide, where
    /// the Dock icon is what brings it forward, so only a summon, a reopen and
    /// an outside request call this.
    ///
    /// A summon or reopen puts its surface up in the same main-actor job: the
    /// unhide reconcile ``noteDidUnhide()`` schedules runs as a later job and
    /// reads the window list, where a surface not yet shown would read as a
    /// window closed during the hide.
    private func leaveHiddenState() {
        guard presence.isHidden else { return }
        #log(Self.logger, .notice, "Surfacing while hidden — unhiding")
        presence.unhideWithoutActivation()
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
        guard presence.activationPolicy == .regular else { return .absent }
        return presence.isActive ? .foreground : .background
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
    /// reconcile leaves the policy the app already had (``AppResidencyPolicy/ResidencyOutcome/waitForUnhide``).
    private var hasVisibleUserWindow: Bool {
        windows.hasUserWindow
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

    /// Reconciles the resident app with its open windows: `.regular` (Dock icon)
    /// while any user window is on screen, and when none are, either `.accessory`
    /// (status-item only) or a quit — see
    /// ``AppResidencyPolicy/residencyOutcome(hasVisibleUserWindow:isHidden:keepInMenuBar:hasUninterruptibleWork:)``.
    ///
    /// Re-run on every window open and close, and on the unhide that makes a
    /// hidden app's windows legible again, so a partial close can never strand
    /// the policy.
    func syncActivationPolicy() {
        switch AppResidencyPolicy.residencyOutcome(
            hasVisibleUserWindow: hasVisibleUserWindow,
            isHidden: presence.isHidden,
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

    /// Runs the decision a hide deferred: every window a hidden app has reports
    /// `isVisible == false`, so a close landing meanwhile is only legible once
    /// the app is back on screen.
    ///
    /// Not ``syncActivationPolicy()``: that one quits an app whose last
    /// window closed, and an unhide is the one moment where a person has just
    /// asked for the app.
    ///
    /// A summon's or reopen's unhide runs this too, and finds the surface it
    /// put up already on screen (``leaveHiddenState()``).
    func noteDidUnhide() {
        Task { @MainActor in self.reconcileUnhide() }
    }

    /// Applies ``AppResidencyPolicy/unhideOutcome(hasVisibleUserWindow:keepInMenuBar:)`` to the app
    /// AppKit has just brought back.
    private func reconcileUnhide() {
        let outcome = AppResidencyPolicy.unhideOutcome(
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
        let current = presence.activationPolicy
        guard current != policy else { return }
        presence.setActivationPolicy(policy)
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
