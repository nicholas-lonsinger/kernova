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
    /// login-item registration, activation-policy switching). `false` for the
    /// normal resident app. Replaces the old three-way launch role: with the
    /// LaunchAgent dropped (#460) there is no launcher/agent split, only this
    /// test-vs-production distinction.
    private let isTestHost: Bool
    private var mainWindowController: MainWindowController?
    private let viewModel: VMLibraryViewModel
    private var clipboardWindows: [UUID: ClipboardWindowController] = [:]
    private var clipboardObservers: [UUID: Any] = [:]
    private var displayWindows: [UUID: VMDisplayWindowController] = [:]
    private var displayWindowObservers: [UUID: Any] = [:]
    private var terminationObservation: ObservationLoop?
    private let clipboardMenuItem: NSMenuItem
    private var settingsWindowController: SettingsWindowController?

    /// Single close-side trigger for the activation-policy reconcile (#437).
    ///
    /// Fires `scheduleAgentActivationPolicySync()` on every window close, tracked
    /// or not (e.g. the standard About panel), rather than each window kind
    /// scheduling its own reconcile. Installed once in `startResidentApp` (called
    /// from `applicationDidFinishLaunching`) for the resident app; unused in the
    /// test host.
    private var globalWindowCloseObserver: Any?

    /// The menu-bar status item (resident app only): the always-visible "Kernova
    /// is running" affordance and a discoverable way to summon the GUI while
    /// headless.
    private var statusItemController: HostAgentStatusItemController?

    /// Cold-launch resolution latch (#460).
    ///
    /// The resident app starts headless and resolves exactly once: the launch
    /// Apple event's login-item property classifies most launches deterministically
    /// (`resolveColdLaunch(from:)`), and an unreadable event falls back to the
    /// activation-settle heuristic — show the window if the app activates (manual
    /// launch), stay headless if a short settle window elapses without activation
    /// (assumed login launch). This latch makes the resolution idempotent so later
    /// ordinary activations don't re-trigger it.
    private var coldLaunchResolved = false
    /// Set in `applicationWillBecomeActive` and read in `applicationShouldHandleReopen`
    /// to distinguish a dock click that activates the app from one on an already-active app.
    ///
    /// Cleared in two places: synchronously in `applicationShouldHandleReopen` (for dock clicks)
    /// and asynchronously via Task (for non-dock activations like Cmd-Tab where the reopen
    /// callback never fires). The synchronous clear prevents rapid successive dock clicks from
    /// reading a stale `true` before the async Task has run.
    private var wasJustActivated = false

    /// Set by `handleQuitAppleEvent` when the sender is System Settings / TCC.
    private var terminationIsTCCRevocation = false

    /// Set in `applicationShouldTerminate` when TCC revocation is detected AND
    /// running VMs require an async save (`.terminateLater`).
    ///
    /// Checked in
    /// `applicationWillTerminate` to launch the relaunch helper at the last moment.
    private var relaunchAfterTermination = false

    /// Set by the status item's Quit — the one affordance that truly kills the
    /// resident agent — so `applicationShouldTerminate` proceeds instead of
    /// downgrading the quit to a GUI close.
    private var userRequestedAgentQuit = false

    /// Set by `handleQuitAppleEvent` via `classifyQuit` for a system power-off or an unattributable sender.
    ///
    /// Covers the quit's sender resolving to `loginwindow` (logout / restart /
    /// shutdown) *or* not being positively classifiable at all (no sender PID
    /// attribute; the PID no longer resolves to a running process). Either way a
    /// system-initiated quit terminates the agent (and saves running VMs) rather
    /// than being downgraded to a GUI close — the agent must never leave the
    /// system waiting on it at logout, and an unattributable sender fails toward
    /// saving state rather than vetoing a possible power-off. See `classifyQuit`
    /// for the full classification matrix.
    ///
    /// Detected synchronously by sender (like `terminationIsTCCRevocation`) rather
    /// than via `NSWorkspace.willPowerOffNotification`: the notification is delivered
    /// on a separate run-loop source from the quit Apple Event with no guaranteed
    /// ordering (a deferred observer could set the flag *after* the AE-driven
    /// `applicationShouldTerminate` already ran and vetoed the power-off), and it
    /// would also latch `true` on an *aborted* logout — making a later ⌘Q wrongly
    /// terminate the agent, with no clean "logout aborted" notification to reset it.
    /// Setting it in the same handler that calls `terminate:` avoids both: it is set
    /// immediately before termination and only when a quit actually arrives.
    private var systemIsPoweringOff = false

    /// Whether a pending quit should actually terminate the resident app.
    ///
    /// GUI-origin quits (⌘Q, the app menu's Quit item, the Dock's Quit) only close
    /// the GUI and leave the app resident with its VMs running headless; it truly
    /// exits only on an explicit status-item Quit, a system logout/shutdown, or a
    /// TCC revocation. Only consulted for the resident app (not the test host).
    private var quitShouldTerminateAgent: Bool {
        userRequestedAgentQuit || systemIsPoweringOff || terminationIsTCCRevocation
    }

    /// Bundle identifiers that indicate a TCC-initiated quit.
    ///
    /// Stable since macOS 13 (Ventura) when System Preferences was replaced by
    /// System Settings with per-pane extensions. May differ on earlier versions.
    ///
    /// `nonisolated` (safe: an immutable `Set<String>` is `Sendable`) so the
    /// `nonisolated` `classifyQuit` can read it without a MainActor hop.
    private nonisolated static let tccSenderBundleIDs: Set<String> = [
        "com.apple.settings.PrivacySecurity.extension"
    ]

    /// Bundle identifiers whose quit means the whole session is ending
    /// (logout / restart / shutdown). `loginwindow` sends each app a
    /// `kAEQuitApplication` event as it tears the session down; that quit must
    /// terminate the agent, never be downgraded to a GUI close.
    ///
    /// Residual: if `loginwindow` ever resolved to a different (but still valid)
    /// bundle ID on some macOS version, `classifyQuit` couldn't tell that apart
    /// from an AppleScript-driven quit by sender alone — the fix would be adding
    /// that bundle ID here, not more sender heuristics.
    ///
    /// `nonisolated` for the same reason as `tccSenderBundleIDs` above.
    private nonisolated static let systemQuitSenderBundleIDs: Set<String> = [
        "com.apple.loginwindow"
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
    /// itself so the full matrix is unit-testable with injected probes instead of
    /// a live Apple Event.
    ///
    /// ⌘Q, the app-menu Quit item, and the status-item Quit all call `terminate:`
    /// directly and never reach this classifier (only *external* senders — Dock,
    /// loginwindow, System Settings/TCC, `osascript` — deliver a quit Apple Event).
    /// So the `senderPID == getpid()` branch below is defensive, not load-bearing:
    /// ⌘Q's stay-resident behavior rests on the final fallthrough, not on that check.
    ///
    /// Defaults toward `.terminateAndSave` for any sender this can't positively
    /// identify (no PID, a non-positive PID, or a PID that no longer resolves to a
    /// live process) — the fail-safe direction for a possible power-off, since
    /// staying resident risks vetoing a real logout/shutdown. A *live* but
    /// unclassified sender (Dock, AppleScript's `osascript`, any other app) falls
    /// through to `.stayResident` instead, since those are known not to be
    /// system-initiated quits.
    nonisolated static func classifyQuit(
        senderPID: pid_t?,
        bundleIDResolver: (pid_t) -> String?,
        isProcessAlive: (pid_t) -> Bool
    ) -> QuitClassification {
        // No sender PID, or a non-positive PID (kill(≤0) targets process groups,
        // not a single process, so it can't be probed the same way): unattributable.
        guard let senderPID, senderPID > 0 else { return .terminateAndSave }

        // Sender process has already exited: unattributable.
        guard isProcessAlive(senderPID) else { return .terminateAndSave }

        if senderPID == getpid() { return .stayResident }

        // Live sender with no resolvable bundle ID (e.g. `osascript` running an
        // AppleScript `quit`) — not a system-initiated quit, stay resident.
        guard let bundleID = bundleIDResolver(senderPID) else { return .stayResident }

        if tccSenderBundleIDs.contains(bundleID) { return .terminateAndRelaunch }
        if systemQuitSenderBundleIDs.contains(bundleID) { return .terminateAndSave }
        // Any other live, identifiable sender — the Dock, a script host, etc.
        return .stayResident
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
        // Teardown helper (#467) — removes the host clipboard File Provider domain
        // so no Finder location lingers (e.g. a ghost domain left by a deleted
        // build). Handled before any NSApplication setup so it works headless.
        if CommandLine.arguments.contains("--remove-clipboard-domain") {
            FileProviderDomainHost.removeAllDomainsBlocking()
            exit(0)
        }

        let isTestHost = ProcessInfo.processInfo.isRunningXCTests
        let app = NSApplication.shared

        // Resident app: start headless in `.accessory` (no Dock blip / focus
        // steal). Whether the window then shows is decided by the launch Apple
        // event's provenance (manual → show, login item → stay headless), with the
        // activation heuristic as fallback — see `resolveColdLaunch(from:)`. The
        // unit-test host stays a plain `.regular` foreground app so the existing
        // suite that launches `Kernova.app` is unaffected.
        if !isTestHost {
            app.setActivationPolicy(.accessory)
        }

        // `NSApplication.delegate` is weak, so the local binding retains the
        // delegate for the process lifetime (`run()` never returns).
        let delegate = AppDelegate(isTestHost: isTestHost)
        app.delegate = delegate
        app.run()
    }

    init(isTestHost: Bool) {
        self.isTestHost = isTestHost
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
    }

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()

        // Reclaim orphaned host-side clipboard staging files from a previous
        // run or crash. The staging supersedes per copy and the staged file URL
        // must outlive the clipboard window (paste-after-close), so it never
        // sweeps on close; a one-time sweep at launch — before any clipboard
        // window opens — clears prior-session orphans, mirroring the guest
        // agent's sweep-on-start.
        ClipboardFileStaging(label: ClipboardContentViewController.stagingLabel).sweep()

        // Intercept the Quit Apple Event to inspect its sender. TCC revocations
        // arrive from System Settings or tccd; Dock Quit, AppleScript, and system
        // shutdown arrive from other senders. This lets us positively identify TCC.
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )

        if isTestHost {
            // Plain foreground app (the unit-test host): show the window and arm
            // idle-termination exactly as the app behaved before the launch model
            // changed. None of the resident-app machinery (login-item migration,
            // status item, activation-policy switching, File Provider domain) runs
            // here — so CI unit tests never register login items or FP domains.
            let windowController = MainWindowController(viewModel: viewModel)
            windowController.showWindow(nil)
            mainWindowController = windowController
            observeForTermination()
        } else {
            startResidentApp()
        }
    }

    // MARK: - Resident App

    /// Brings up the resident, headless app: stands up the menu-bar status item
    /// and resolves the cold launch.
    ///
    /// The VM library is already loaded (`VMLibraryViewModel.init`); VMs are
    /// **not** auto-started — they appear at their last-logout state. Idle
    /// termination is not armed: the app stays resident until an explicit
    /// status-item Quit, with any running VMs executing headless. Whether a window
    /// shows at launch is decided by the launch event's provenance (with the
    /// activation heuristic as fallback).
    private func startResidentApp() {
        // No legacy-agent migration (#460): the old launch-at-login agent's
        // registration can only be unregistered while its `app.kernova.plist` is
        // still bundled, and this build removed it — so a programmatic cleanup here
        // would be a guaranteed no-op. Pre-release, a stale "Kernova" Login Items
        // entry from an old dev build is cleared by hand once, not with transition
        // scaffolding.

        // Always-visible menu-bar presence: the app has no Dock icon while
        // headless, so the status item is how the user sees it's running and
        // summons the GUI (mirrors OrbStack/Docker/Tailscale and the guest agent).
        statusItemController = HostAgentStatusItemController(
            viewModel: viewModel,
            onOpen: { [weak self] vmID in
                if let vmID { self?.viewModel.selectedID = vmID }
                self?.summonUserInterface()
            },
            onQuit: { [weak self] in
                // The only affordance that truly quits the app — everything else
                // (⌘Q, app-menu Quit, Dock Quit) just closes the GUI.
                self?.userRequestedAgentQuit = true
                NSApp.terminate(nil)
            }
        )

        // Single close-side activation-policy reconcile trigger (#437): fires on
        // every window close, tracked or not — so an untracked AppKit panel (the
        // standard About panel) closing as the last window still drops the Dock
        // icon, and one closing while a tracked window remains never strips it.
        // See `hasVisibleUserWindow`.
        globalWindowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleAgentActivationPolicySync() }
        }

        // Cold-launch resolution (#460): the launch Apple event classifies most
        // launches deterministically (manual → show the window; login item → stay
        // headless); an unreadable event falls back to the activation heuristic.
        resolveColdLaunch(from: NSAppleEventManager.shared().currentAppleEvent)

        // Provenance line (#455): the XPC peer pin on the File Provider servicing
        // connection checks only identifier + team, so a mismatched-version
        // interaction (an old resident copy still answering while a new one was
        // just installed) is otherwise only diagnosable by correlating logs
        // across processes. One greppable line at startup makes "which copy is
        // this" a single `log show` away instead.
        let provenance = Self.residentProvenanceLine(
            bundlePath: Bundle.main.bundlePath,
            build: Self.buildNumber,
            configuration: Self.buildConfiguration)
        Self.logger.notice(
            "Kernova resident app ready (headless, .accessory) — \(provenance, privacy: .public)")
    }

    #if DEBUG
    private static let buildConfiguration = "Debug"
    #else
    private static let buildConfiguration = "Release"
    #endif

    /// `CFBundleVersion` is a compile-time-known Info.plist key (`Kernova/App/
    /// Info.plist`, substituted by `Tools/set-build-number.sh`), so a missing
    /// value indicates a build misconfiguration rather than a runtime condition.
    private static let buildNumber: String = {
        guard let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String else {
            logger.fault("CFBundleVersion not found in Info.plist")
            assertionFailure("CFBundleVersion not found in Info.plist")
            return "?"
        }
        return build
    }()

    /// Formats the resident-app startup provenance line — bundle path, build
    /// number, and configuration — factored out pure for unit testing (mirrors
    /// `launchProvenance`).
    nonisolated static func residentProvenanceLine(
        bundlePath: String, build: String, configuration: String
    ) -> String {
        "bundle=\(bundlePath) build=\(build) config=\(configuration)"
    }

    // MARK: - Cold-launch resolution

    /// How the process was launched, as told by the launch Apple event.
    enum LaunchProvenance: Equatable {
        /// The `oapp` event carries `keyAELaunchedAsLogInItem` — a login-item launch.
        case loginItem
        /// A plain `oapp` event without the login-item property — a manual launch
        /// (Finder double-click, Dock, `open`, LaunchServices on another app's behalf).
        case manual
        /// No readable `oapp` event — fall back to the activation heuristic.
        case indeterminate
    }

    /// Classifies the launch Apple event, factored out pure for unit testing
    /// (mirrors `coldLaunchOutcome`).
    ///
    /// Takes the event's already-extracted `(eventID, keyAEPropData enum code)`
    /// rather than the descriptor so tests don't have to construct Apple events.
    nonisolated static func launchProvenance(
        eventID: AEEventID?, launchPropData: OSType?
    ) -> LaunchProvenance {
        guard eventID == AEEventID(kAEOpenApplication) else { return .indeterminate }
        return launchPropData == OSType(keyAELaunchedAsLogInItem) ? .loginItem : .manual
    }

    /// Resolves the cold launch from the launch Apple event, falling back to the
    /// activation-settle heuristic when the event is unreadable.
    ///
    /// The `oapp` event's `keyAEPropData` property carries
    /// `keyAELaunchedAsLogInItem` for a login-item launch — legacy-documented
    /// (Cocoa Scripting Guide, "may contain") and field-proven against
    /// `SMAppService.mainApp` login items (Electron ≥ 29.4 ships the same check).
    /// There is no modern purpose-built API for launch provenance (FB10207829),
    /// and Apple never re-documented the property for `SMAppService` — hence the
    /// heuristic fallback for an unreadable event rather than trusting silence.
    /// Must run while the launch event is still current (i.e. from
    /// `applicationDidFinishLaunching`'s call stack); later, `currentAppleEvent`
    /// is nil and this degrades gracefully to the heuristic.
    private func resolveColdLaunch(from launchEvent: NSAppleEventDescriptor?) {
        let provenance = Self.launchProvenance(
            eventID: launchEvent?.eventID,
            launchPropData: launchEvent?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?
                .enumCodeValue)
        switch provenance {
        case .loginItem:
            Self.logger.notice("Launch event carries the login-item property")
            resolveColdLaunch(showWindow: false)
        case .manual:
            Self.logger.notice("Launch event is a plain open (manual launch)")
            resolveColdLaunch(showWindow: true)
        case .indeterminate:
            Self.logger.notice("No readable launch event — falling back to activation heuristic")
            armColdLaunchActivationHeuristic()
        }
    }

    /// Arms the fallback heuristic: resolve immediately if the app is already
    /// active (a fast manual launch can activate before this runs), otherwise wait
    /// a short settle window and assume a login launch → stay headless.
    ///
    /// The settle window has no visible cost (a headless app shows nothing), so
    /// a login launch simply stays headless when it elapses. A manual launch
    /// resolves earlier via `applicationDidBecomeActive`.
    private func armColdLaunchActivationHeuristic() {
        if NSApp.isActive {
            resolveColdLaunch(showWindow: true)
            return
        }
        // RATIONALE: this fallback only runs when the launch Apple event was
        // unreadable (`launchProvenance` → `.indeterminate`), where no API-derived
        // signal remains (FB10207829) — so a fixed settle window is inherent to the
        // heuristic, not a tunable bug. A manual launch resolves via the
        // `NSApp.isActive` fast path above or an early `applicationDidBecomeActive`;
        // this timer only decides the case where neither has fired yet. If a manual
        // launch's activation is delayed past the window it latches headless and the
        // window doesn't auto-show — but the app is never unreachable: the
        // always-present status item summons the GUI on demand. Longer would delay
        // the (correct) headless outcome of a genuine login launch for no gain.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.resolveColdLaunch(showWindow: false)
        }
    }

    /// The cold-launch decision, factored out pure for unit testing.
    enum ColdLaunchOutcome: Equatable {
        /// First resolution, manual launch (event- or activation-signalled) →
        /// show the window.
        case showWindow
        /// First resolution, login launch (event-signalled or settle-window
        /// elapsed) → stay headless.
        case stayHeadless
        /// Already resolved — ignore (a later ordinary activation).
        case alreadyResolved
    }

    /// Given the resolved show/stay signal and whether the cold launch already
    /// resolved, returns what to do — exactly once.
    ///
    /// `nonisolated` + pure so it is unit-testable without the AppKit timing
    /// (mirrors `classifyQuit`).
    nonisolated static func coldLaunchOutcome(
        showWindow: Bool, alreadyResolved: Bool
    ) -> ColdLaunchOutcome {
        guard !alreadyResolved else { return .alreadyResolved }
        return showWindow ? .showWindow : .stayHeadless
    }

    /// Applies `coldLaunchOutcome`, latching the resolution so later ordinary
    /// activations don't re-trigger it.
    private func resolveColdLaunch(showWindow: Bool) {
        switch Self.coldLaunchOutcome(
            showWindow: showWindow, alreadyResolved: coldLaunchResolved)
        {
        case .alreadyResolved:
            return
        case .showWindow:
            coldLaunchResolved = true
            Self.logger.notice("Cold launch resolved: showing window (manual launch)")
            summonUserInterface()
        case .stayHeadless:
            coldLaunchResolved = true
            Self.logger.notice("Cold launch resolved: staying headless (login launch)")
        }
    }

    /// Brings the resident app's GUI forward: morph to `.regular`, then activate
    /// and show the library window.
    ///
    /// The sole GUI-summon path — a Finder reopen (`applicationShouldHandleReopen`),
    /// the status-item Open, and the cold-launch heuristic all route here. Idempotent.
    private func summonUserInterface() {
        // Morph to a regular app so the Dock icon + menu bar appear (no-op if
        // already `.regular`). Defer the activate + show to the next runloop tick
        // so the menu bar has refreshed (works around the .accessory→.regular
        // menu-bar quirk, FB7743313).
        setAgentActivationPolicy(.regular)
        Task { @MainActor in
            // RATIONALE: after a login launch the app is a background, unactivated
            // `.accessory` process, so cooperative activation would deny it the
            // foreground. `ignoringOtherApps` forces it — the user explicitly asked
            // for the window (the modern argument-less `activate()` does not
            // reliably front a background-launched process). Harmless (a no-op) on
            // the manual-launch path, where the app is already frontmost.
            NSApp.activate(ignoringOtherApps: true)
            self.showLibraryWindow(bringToFront: true)
            // Summoning from the status-item menu leaves the freshly-appeared main
            // menu bar with its first menu (File) highlighted — the status menu's
            // dismissal bleeds into the menu bar that the `.accessory`→`.regular`
            // morph just installed. Clear that stray selection.
            NSApp.mainMenu?.cancelTracking()
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
        // RATIONALE: deliberately do NOT special-case `NSApp.isHidden`. Plain ⌘H
        // closes no window, so no reconcile fires and `.regular` (Dock icon)
        // persists — the hidden-app behavior users expect. Forcing `.regular`
        // while hidden instead strands the agent with a Dock icon and zero windows
        // when a background close (e.g. a VM shutting down empties the last display
        // window mid-hide) fires the reconcile; there `.accessory` is correct and
        // the menu-bar status item is the way back.
        func onScreen(_ window: NSWindow?) -> Bool {
            guard let window else { return false }
            return window.isVisible || window.isMiniaturized
        }
        if onScreen(mainWindowController?.window) { return true }
        if displayWindows.values.contains(where: { onScreen($0.window) }) { return true }
        if clipboardWindows.values.contains(where: { onScreen($0.window) }) { return true }
        if onScreen(settingsWindowController?.window) { return true }
        // AppKit-owned top-level panels opened from the menu bar — the standard
        // About panel is the motivating case — are genuine on-screen windows we
        // don't track. Count any so a reconcile can't strip the Dock icon + menu
        // bar while one is the last window visible (#437).
        if NSApp.windows.contains(where: Self.isUntrackedUserPanel) { return true }
        return false
    }

    /// Whether `window` is an untracked, AppKit-owned top-level panel whose
    /// presence must keep the Dock icon.
    ///
    /// The standard About panel is the motivating example (#437) — unlike the
    /// toolbar customization palette, which AppKit presents as a sheet attached to
    /// its target window and so can never be the sole surviving window; that
    /// window is already covered by the tracked-window checks above. Excludes the
    /// always-present status-bar window and other chrome by requiring a visible,
    /// normal-level, titled window — the status item's backing `NSStatusBarWindow`
    /// is borderless and sits above `.normal`, so an unfiltered `NSApp.windows`
    /// scan would pin the agent to `.regular` forever.
    static func isUntrackedUserPanel(_ window: NSWindow) -> Bool {
        (window.isVisible || window.isMiniaturized)
            && window.level == .normal
            && window.styleMask.contains(.titled)
    }

    /// Reconciles the resident app's activation policy with its open windows:
    /// `.regular` (Dock icon) while any user window is on screen, `.accessory`
    /// (status-item only) when none are.
    ///
    /// The single source of truth — re-run on every window open and close — so a
    /// partial close (e.g. popping a display back into the still-open main
    /// window) can never strand the policy. No-op in the test host.
    private func syncAgentActivationPolicy() {
        guard !isTestHost else { return }
        setAgentActivationPolicy(hasVisibleUserWindow ? .regular : .accessory)
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
        // Resident app: closing the last window drops back to a headless
        // `.accessory` app (no Dock icon). Any running VMs keep executing headless;
        // the process stays resident until an explicit Quit. This is the
        // OrbStack/Docker "it's still running" behavior. macOS gives same-user
        // single-instance for free (a second open → reopen event, not a new
        // process), so no instance lock is needed.
        if !isTestHost {
            // Stay resident. The global `willClose` observer (#437) already
            // schedules the Dock-presence reconcile for this same window close;
            // no need to schedule it again here.
            return false
        }

        let hasActiveVMs = viewModel.instances.contains(where: \.isKeepingAppAlive)

        // Stay alive if VMs are active or display windows still exist
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
        // Clear after the current event cycle so the flag doesn't remain stale
        // for non-dock activations (e.g., Cmd-Tab, clicking a window) where
        // applicationShouldHandleReopen is never called. When it IS called
        // (dock clicks), it runs synchronously during the same event dispatch,
        // so it reads the flag before this Task body executes.
        //
        // Note: DispatchQueue.main.async cannot be used here — its @Sendable
        // closure cannot access @MainActor-isolated state under strict concurrency.
        Task { @MainActor [weak self] in
            self?.wasJustActivated = false
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // The fallback heuristic's positive signal: a manual launch activates the
        // app, so its first activation resolves the cold launch by showing the
        // window (idempotent thereafter — the event-based resolution or a prior
        // activation has usually latched it already, and later ordinary
        // activations are ignored). No-op in the test host, which shows its
        // window in didFinishLaunching.
        guard !isTestHost else { return }
        resolveColdLaunch(showWindow: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Resident app: a Finder reopen (double-click / Dock click / `open` routed
        // to the existing instance — macOS reactivates the single running instance
        // rather than spawning a second) summons the GUI, morphing
        // `.accessory`→`.regular` first. This is the sole GUI-summon path on a
        // re-launch now that the launcher/agent split is gone (#460).
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
    /// `.accessory` state — the response to a GUI-origin quit.
    ///
    /// Display windows are closed as app-initiated dismissals (`closeForAppDismissal`)
    /// so their close handler skips the user-close side effects (reverting
    /// `displayPreference` and restoring the library window). The remaining windows'
    /// close observers reconcile the activation policy, so no explicit sync is needed
    /// here. Collections are snapshotted because closing mutates them.
    private func closeAllGUIWindows() {
        for controller in Array(displayWindows.values) { controller.closeForAppDismissal() }
        for controller in Array(clipboardWindows.values) { controller.window?.close() }
        settingsWindowController?.window?.close()
        mainWindowController?.window?.close()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Resident app: a GUI-origin quit (⌘Q, the app menu's Quit, the Dock's
        // Quit) only closes the GUI — the app stays resident with its VMs running
        // headless. It truly terminates only on an explicit status-item Quit, a
        // system logout/shutdown, or a TCC revocation (`quitShouldTerminateAgent`).
        // Every quit path funnels through `terminate:` and thus this method, so this
        // single gate covers them all.
        if !isTestHost && !quitShouldTerminateAgent {
            Self.logger.notice("GUI-origin quit — closing the GUI; app stays resident")
            // Defer so the close runs after this termination request is fully cancelled.
            Task { @MainActor in self.closeAllGUIWindows() }
            return .terminateCancel
        }

        // Cancel all preparing operations and remove phantom rows before terminating
        cancelAndCleanupPreparingInstances()

        // Save VMs that have a live virtual machine; cold-paused VMs already have state on disk
        let runningInstances = viewModel.instances.filter {
            ($0.status == .running || $0.status == .paused) && $0.virtualMachine != nil
        }

        guard !runningInstances.isEmpty else {
            return .terminateNow
        }

        // When a TCC permission is revoked (e.g., microphone toggled in System Settings),
        // macOS quits and relaunches the app. The built-in relaunch times out while VMs
        // are saving. Mark for relaunch so applicationWillTerminate can launch the helper
        // at the last moment, after saves are complete.
        if terminationIsTCCRevocation {
            relaunchAfterTermination = true
        }

        Task { @MainActor in
            var savedCount = 0
            var failedCount = 0
            for instance in runningInstances {
                do {
                    try await viewModel.trySave(instance)
                    viewModel.saveConfiguration(for: instance)
                    savedCount += 1
                } catch {
                    Self.logger.error(
                        "Failed to save '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
                    )
                    failedCount += 1
                    do {
                        try await viewModel.tryForceStop(instance)
                    } catch {
                        Self.logger.error(
                            "Failed to force-stop '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                }
            }
            Self.logger.notice(
                "Termination save complete: \(savedCount, privacy: .public) saved, \(failedCount, privacy: .public) failed of \(runningInstances.count, privacy: .public) total"
            )
            // A drop/odoc delivered during the async save window above can register a fresh
            // phantom (import reservation is synchronous and no longer gated by termination),
            // so sweep again right before the deferred reply so such a bundle isn't orphaned on
            // disk (#491).
            self.cancelAndCleanupPreparingInstances()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    /// Cancels every preparing instance's task and trashes its partial bundle.
    ///
    /// Best effort, since `FileManager.copyItem` isn't interruptible (the copy already in
    /// flight keeps writing until it finishes or fails on its own). Every accepted import bundle
    /// registers its phantom row synchronously, so this sweep sees them all (#491).
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
    /// Routes through `classifyQuit` and sets the flags
    /// `applicationShouldTerminate`'s gate reads. Flags are only ever set to
    /// `true` here, never reset to `false`: a `true` flag always drives the
    /// process toward actual termination on the same call that set it (per
    /// `quitShouldTerminateAgent`'s gate), so there is never a stale `true` left
    /// over from a quit whose termination didn't happen. Resetting on
    /// `.stayResident` was considered and rejected — a later, unrelated
    /// GUI-origin quit arriving while an earlier system-initiated quit's
    /// `.terminateLater` VM-save is still in flight would clear the very flag
    /// that save depends on, risking a wrongful veto of an already-accepted
    /// termination.
    @objc private func handleQuitAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent _: NSAppleEventDescriptor
    ) {
        let senderPID = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value
        // Resolved once and fed to `classifyQuit` as fixed values (rather than
        // letting it re-probe) so the same attribution result also drives the log
        // level below without a second syscall.
        //
        // Residual: `kill` (liveness) and `NSRunningApplication` (identity) are two
        // separate, non-atomic probes of the same PID — a sender that exits in the
        // narrow window between them reads as "alive but unidentifiable" and falls
        // through to `.stayResident` rather than the fail-safe default. Collapsing
        // to a single probe isn't available: `NSRunningApplication` alone (the old
        // code's approach) would misclassify a live-but-non-GUI sender like
        // `osascript` as "dead", the opposite bug. Same class of residual as
        // `systemQuitSenderBundleIDs`'s doc comment above, now for liveness instead
        // of identity.
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
                // Persisted (not .debug): a live sender we can't identify might be a
                // TCC/system sender this classifier is failing to recognize.
                Self.logger.warning(
                    "Quit Apple Event: sender PID \(attributablePID, privacy: .public) is alive but could not be resolved to an application with a bundle identifier — classified as \(String(describing: classification), privacy: .public)"
                )
            }
        } else {
            // The fail-safe path #438 exists for: an unattributable sender. Persisted
            // (.warning, not .debug) so a stalled-logout post-mortem can confirm this
            // path was taken rather than the sender simply being unrecognized.
            Self.logger.warning(
                "Quit Apple Event sender could not be attributed (PID \(senderPID.map(String.init) ?? "none", privacy: .public)) — failing safe to \(String(describing: classification), privacy: .public)"
            )
        }

        switch classification {
        case .stayResident:
            break
        case .terminateAndSave:
            systemIsPoweringOff = true
        case .terminateAndRelaunch:
            terminationIsTCCRevocation = true
        }

        NSApp.terminate(nil)
    }

    /// Launches the relaunch helper, which monitors this process and re-opens
    /// the app after it terminates.
    ///
    /// Used for TCC permission revocations where
    /// the built-in relaunch mechanism times out during VM save.
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
        // Opening a document is an explicit request to see the app, so summon the
        // GUI. The cold-launch heuristic covers only a fresh launch; a double-click
        // while the app is already resident+headless gets no activation-driven
        // summon (the heuristic already latched, and macOS sends no reopen for a
        // document open), so surface the window here. Idempotent; skipped in the
        // test host, which manages its own window.
        if !isTestHost {
            summonUserInterface()
        }
    }

    /// Filters to `.kernova` bundles and imports the batch.
    ///
    /// AppKit delivers the odoc event to the single running instance in both the
    /// cold-launch and already-running cases, so this one path covers both — no
    /// launcher→XPC forwarding is needed (#460 dropped the launcher; #439).
    /// `viewModel` exists from `init`, so importing this early is safe; the caller
    /// summons the GUI (the heuristic alone only covers a cold launch).
    /// `VMLibraryViewModel.importVMs(fromDroppedURLs:)` reserves each bundle's destination
    /// synchronously and runs the copies concurrently, so this synchronous delegate callback
    /// isn't blocked, every bundle in the batch imports rather than only the first (#444), and
    /// this batch can't collide with a still-copying batch from another trigger (#487/#491).
    private func importVMs(from urls: [URL]) {
        viewModel.importVMs(fromDroppedURLs: urls)
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
        let controller = settingsWindowController ?? SettingsWindowController()
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
            viewModel.stop(instance)
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
        // Reveal the sidebar surface first — front the library window and
        // uncollapse the sidebar — then start its inline rename, so the
        // command always lands on a visible row (see the "Rename" routing
        // rationale in ARCHITECTURE.md; #320).
        showLibraryWindow(bringToFront: true)
        mainWindowController?.revealSidebar()
        viewModel.renameVMInSidebar(instance)
    }

    @objc func cloneVM(_ sender: Any?) {
        guard let instance = activeInstance else { return }
        viewModel.cloneVM(instance)
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
    ///
    /// This method manages the full lifecycle: reuse an existing window if one
    /// is already open for this VM, otherwise create one via `factory`, register
    /// a `willCloseNotification` observer for cleanup, and store both the
    /// controller and observer token in the provided dictionary pair.
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

        // RATIONALE: ReferenceWritableKeyPath is not Sendable, but the observer closure
        // runs on queue: .main where AppDelegate is @MainActor-isolated. We use
        // nonisolated(unsafe) to suppress the false-positive data-race diagnostic.
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
                // The global `willClose` observer (#437) already schedules the Dock-
                // presence reconcile for this same window close.
            }
        }
        self[keyPath: observersPath][vmID] = token

        controller.showWindow(nil)
    }

    @objc func showClipboard(_ sender: Any?) {
        guard let instance = activeInstance else { return }
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
        // never disagree with the title the user clicked. The viewModel handles
        // the missing-DMG case with a fault + assertionFailure.
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
            existing.window?.close()
            return
        }

        viewModel.updateConfiguration(of: instance) { $0.displayPreference = .popOut }
        openDisplayWindow(for: instance, enterFullscreen: false)
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

        // Already showing a display window for this VM
        guard displayWindows[vmID] == nil else { return }
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
            // The observer closure is @Sendable (nonisolated), but queue: .main guarantees
            // main thread execution, making MainActor.assumeIsolated safe.
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
                if let controller = self.displayWindows.removeValue(forKey: vmID) {
                    self.viewModel.updateConfiguration(of: instance) { config in
                        // Always remember which display the VM was on
                        if let displayID = controller.lastDisplayID {
                            config.lastFullscreenDisplayID = displayID
                        }
                        if !controller.closedProgrammatically {
                            // User manually closed the display window
                            config.displayPreference = .inline
                            Self.logger.debug(
                                "Cleared displayPreference for '\(instance.name, privacy: .public)' (user closed display window)"
                            )
                        }
                    }

                    Self.logger.notice(
                        "Display window closed for '\(instance.name, privacy: .public)' (programmatic=\(controller.closedProgrammatically, privacy: .public), policy=\(NSApp.activationPolicy().rawValue, privacy: .public))"
                    )
                    if controller.closedProgrammatically {
                        // VM stopped/errored/cold-paused — check if app should quit.
                        // The global `willClose` observer (#437) already schedules the
                        // Dock-presence reconcile for this same window close.
                        self.terminateIfIdle()
                        return
                    }
                }
                self.viewModel.selectedID = vmID

                // Restore library window for user-initiated close:
                // - Key + active app: user deliberately closed display → focus library
                // - App not active: user closed display while elsewhere → show library in background
                // - Active but not key: user is in another Kernova window → no action needed
                if wasKeyWindow && appWasActive {
                    self.showLibrary(nil)
                } else if !appWasActive {
                    self.showLibraryWindow(bringToFront: false)
                }
                // Reconcile immediately (not `scheduleAgentActivationPolicySync()`'s
                // extra deferred tick): the global `willClose` observer (#437) also
                // schedules a reconcile for this same window close, but as an
                // independent `Task` it isn't guaranteed to run after the
                // `showLibrary`/`showLibraryWindow` restore above — an ordering race
                // that could otherwise flip the Dock icon to `.accessory` and back.
                // Calling it synchronously here, after the restore, is the
                // authoritative reconcile for this path.
                self.syncAgentActivationPolicy()
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

    /// Returns the best screen for entering fullscreen, using a fallback chain.
    ///
    /// 1. The display the VM was last fullscreen on (persisted in configuration)
    /// 2. The library window's current display
    /// 3. The primary display
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
    /// Distinguishes closed from hidden (Cmd+H) and minimized (Cmd+M) via runtime inspection.
    /// Returns `false` if the window controller or its window is nil (no window to inspect).
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
        // Preparing instances disable all VM menu bar actions (cancel is only available
        // via sidebar context menu). Show in Finder stays available, matching the
        // sidebar's preparing menu — the bundle already exists on disk.
        if let instance = activeInstance, instance.isPreparing {
            switch menuItem.action {
            case #selector(showLibrary(_:)), #selector(newVM(_:)), #selector(openVMsFolder(_:)),
                #selector(showVMInFinder(_:)):
                return true
            default:
                return false
            }
        }

        switch menuItem.action {
        case #selector(startVM(_:)):
            guard let instance = activeInstance else { return false }
            // Install-flavored title for pending-install VMs, matching the sidebar
            // context menu and the toolbar's play segment.
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
            // the discard-saved-state confirmation, and the title names that
            // consequence (matching the sidebar context menu).
            menuItem.title = instance.stopActionMenuTitle
            return instance.canStop || instance.isColdPaused
        case #selector(forceStopVM(_:)):
            // Instance-level: cold-paused is excluded, where the retitled stop item
            // ("Discard Saved State…") is the one surface for the same underlying
            // action — two enabled items must not alias one action under two names.
            return activeInstance?.canForceStop ?? false
        case #selector(saveVM(_:)):
            return activeInstance?.canSave ?? false
        case #selector(renameVM(_:)):
            return activeInstance?.status.canRename ?? false
        case #selector(cloneVM(_:)):
            guard let instance = activeInstance else { return false }
            return instance.status.canEditSettings && !viewModel.hasPreparing
        case #selector(deleteVM(_:)), #selector(deleteImmediatelyVM(_:)):
            // Same gate for both the primary and its ⌥-alternate so the collapsed
            // menu row stays consistent.
            return activeInstance?.status.canEditSettings ?? false
        case #selector(showVMInFinder(_:)):
            return activeInstance != nil
        // AppKit bypasses NSMenuItemValidation for windowsMenu items, so
        // menuNeedsUpdate(_:) handles visual state. This case covers keyboard
        // shortcut validation, which still routes through validateMenuItem(_:).
        case #selector(showClipboard(_:)):
            return activeInstance?.canShowClipboard ?? false
        case #selector(toggleGuestAgentDisk(_:)):
            // Hard gates (not status-derived): a live VM for USB hot-plug and a
            // bundled DMG to attach. The status→title/enabled/action mapping is
            // the single source of truth in `GuestAgentDiskMenuItem.model`,
            // shared with `toggleGuestAgentDisk(_:)` so they never disagree.
            guard let instance = activeInstance, instance.canAttachUSBDevices else { return false }
            guard Self.guestAgentDiskPath != nil else { return false }
            let model = GuestAgentDiskMenuItem.model(
                status: instance.agentStatus,
                isInstallerMounted: viewModel.isGuestAgentInstallerMounted(on: instance))
            menuItem.title = model.title
            return model.isEnabled
        case #selector(togglePopOut(_:)):
            guard let instance = activeInstance else { return false }
            let canUse = instance.canUseExternalDisplay
            menuItem.title = displayWindows[instance.instanceID] != nil ? "Pop In Display" : "Pop Out Display"
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
        }
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
        appMenu.addItem(withTitle: "Quit Kernova", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Virtual Machine…", action: #selector(newVM(_:)), keyEquivalent: "n")
        fileMenu.addItem(.separator())
        // "Open … Folder" (a Finder window of the folder's contents, like the Script
        // menu's "Open Scripts Folder"), not "Show in Finder", which reveals an item
        // selected in its parent folder. And "VMs Folder", not "Library" — the Window
        // menu already uses Library for the main window (#333).
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
        // Nil-target standard NSWindow actions resolve against the key window's
        // responder chain: AppKit retitles Show/Hide Toolbar, disables both items
        // for windows without a toolbar, and disables Customize Toolbar… when the
        // key window's toolbar doesn't allow customization. AppKit augments this
        // menu automatically with window-tabbing items (Show Tab Bar / Show All
        // Tabs); fullscreen and tiling commands live in the AppKit-populated
        // section of the Window menu, separate from the VM menu's "Fullscreen
        // Display" (⇧⌘F), which targets the guest display rather than the key
        // window.
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
        // Advanced action, always visible in the menu bar (⌥⌘R). The menu bar is the
        // full discoverability surface where every action is enumerated and
        // `validateMenuItem(_:)` greys out what doesn't apply (here `canStartInRecovery`:
        // stopped macOS guests) — matching "Force Stop", the other advanced lifecycle
        // action, which is likewise an always-visible sibling here. The
        // `alwaysShowAdvancedOptions` preference governs only the Option-reveal in the
        // sidebar context menu, not the menu bar. The ⌥⌘R shortcut is shared with
        // "Resume" — unambiguous because a VM is never both stopped and paused, and
        // recovery precedes Resume in menu order.
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
        // Finder's single-item Rename), not a dialog — and matches the sidebar context
        // menu's title.
        vmMenu.addItem(withTitle: "Rename", action: #selector(renameVM(_:)), keyEquivalent: "")
        vmMenu.addItem(withTitle: "Clone", action: #selector(cloneVM(_:)), keyEquivalent: "d")
        vmMenu.addItem(withTitle: "Show in Finder", action: #selector(showVMInFinder(_:)), keyEquivalent: "")
        vmMenu.addItem(.separator())
        // "Move to Trash…" gathers input (the delete sheet lets the user pick which
        // external files to remove too), so the ellipsis is HIG-correct here.
        let deleteItem = vmMenu.addItem(
            withTitle: "Move to Trash…", action: #selector(deleteVM(_:)), keyEquivalent: "\u{08}")
        deleteItem.keyEquivalentModifierMask = [.command]
        // ⌥-alternate (Finder's File-menu idiom for this exact pair): holding Option swaps
        // "Move to Trash…" (⌘⌫) for "Delete Immediately…" (⌥⌘⌫). Unlike the always-visible
        // advanced items above (Start in Recovery, Force Stop), this one is intentionally
        // tucked behind ⌥ because it's irreversible and shouldn't be one slip from the pointer.
        let deleteImmediatelyItem = vmMenu.addItem(
            withTitle: "Delete Immediately…", action: #selector(deleteImmediatelyVM(_:)), keyEquivalent: "\u{08}")
        deleteImmediatelyItem.keyEquivalentModifierMask = [.command, .option]
        deleteImmediatelyItem.isAlternate = true
        vmMenu.addItem(.separator())
        // Title is a placeholder — `validateMenuItem(_:)` retitles per agent
        // status / attach state on every menu open (Install / Update / Reinstall
        // / Manage / Eject Guest Agent Media).
        vmMenu.addItem(
            NSMenuItem(
                title: "Install Guest Agent…",
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
