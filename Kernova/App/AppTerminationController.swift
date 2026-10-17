import Foundation
import KernovaLogging

/// The GUI close a downgraded quit needs, which the residency cluster owns.
@MainActor
protocol SoftQuitHosting: AnyObject {
    /// Closes every user-facing window and settles the headless state.
    func closeGUIForSoftQuit()
}

/// The one owner of what a quit does: which senders terminate the agent, the
/// async save pass that suspends every live guest before the process exits, and
/// the relaunch a TCC revocation needs.
///
/// The latches that decide a pending quit are read and written nowhere else.
@MainActor
final class AppTerminationController {
    private let viewModel: VMLibraryViewModel
    /// Where a downgraded quit closes the GUI.
    private let residency: any SoftQuitHosting

    /// Latched once a termination save pass has started, so a second quit can't
    /// start a second one: its save would be refused as busy on the VM the
    /// first is saving, and the catch would force-stop it mid-save.
    ///
    /// Never reset, matching the quit flags below: every later quit joins the
    /// pass, which always ends by terminating the app.
    private var isRunningTerminationSavePass = false

    /// Latched once that pass has finished, which is what lets the gate answer
    /// `.now` for the quit the pass itself then asks for.
    private var hasCompletedTerminationSavePass = false

    /// Whether the gate has answered `.later` and AppKit is waiting on
    /// the reply the finished pass owes it.
    private var owesDeferredTerminationReply = false

    /// Latched at the gate when a quit Apple Event's sender is System Settings /
    /// TCC.
    private var terminationIsTCCRevocation = false

    /// Set in ``handleTerminationRequest()`` when TCC revocation is detected AND
    /// running VMs require an async save (`.later`).
    private var relaunchAfterTermination = false

    /// Set by the true-quit affordances (the status item's Quit, the app menu's
    /// "Quit Kernova") so ``handleTerminationRequest()`` proceeds instead of
    /// downgrading the quit to a GUI close.
    private var userRequestedAgentQuit = false

    /// Latched at the gate via `classifyQuit` whenever an external quit Apple
    /// Event must actually terminate the agent rather than downgrade to a GUI
    /// close, short of a TCC revocation.
    ///
    /// Latches for every sender `classifyQuit` maps to `.terminateAndSave`: a
    /// system quit must never leave the system waiting on the agent at logout, a
    /// programmatic quit is explicit and honored, and an unattributable sender
    /// fails toward saving state rather than vetoing a possible power-off.
    private var externalQuitRequiresTermination = false

    /// Reads the quit Apple Event being handled — `nil` when the pending quit
    /// was not delivered by one.
    private let pendingQuitEvent: @MainActor () -> QuitEvent?

    /// What the gate learns about a quit Apple Event's sender.
    private let senderProbe: QuitSenderProbe

    /// Ends the termination a finished save pass ran for.
    private let endTermination: @MainActor (TerminationEnding) -> Void

    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "AppTermination")

    init(
        viewModel: VMLibraryViewModel, residency: any SoftQuitHosting,
        pendingQuitEvent: @escaping @MainActor () -> QuitEvent?,
        senderProbe: QuitSenderProbe,
        endTermination: @escaping @MainActor (TerminationEnding) -> Void
    ) {
        self.viewModel = viewModel
        self.residency = residency
        self.pendingQuitEvent = pendingQuitEvent
        self.senderProbe = senderProbe
        self.endTermination = endTermination
    }

    // MARK: - Quit Classification

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
    /// itself.
    ///
    /// The governing principle: user-facing quit affordances soft-quit;
    /// programmatic and external quits are honored as real quits, and an
    /// unattributable sender fails safe toward termination.
    nonisolated static func classifyQuit(senderPID: pid_t?, sender: QuitSenderProbe) -> QuitClassification {
        // A non-positive PID targets a process group, not a single process, so it
        // can't be probed the same way: unattributable.
        guard let senderPID, senderPID > 0 else { return .terminateAndSave }

        guard sender.isProcessAlive(senderPID) else { return .terminateAndSave }

        if senderPID == getpid() { return .stayResident }

        // Live sender with no resolvable bundle ID (e.g. `osascript` running an
        // AppleScript `quit`) — a programmatic quit; honor it.
        guard let bundleID = sender.bundleID(senderPID) else { return .terminateAndSave }

        if tccSenderBundleIDs.contains(bundleID) { return .terminateAndRelaunch }
        if systemQuitSenderBundleIDs.contains(bundleID) { return .terminateAndSave }
        // The Dock's Quit is a user-facing affordance — soft-quit like ⌘Q.
        if dockSenderBundleIDs.contains(bundleID) { return .stayResident }
        return .terminateAndSave
    }

    /// Whether a pending quit should actually terminate the resident app.
    ///
    /// While *Continue running in the menu bar* is on (the default), GUI-origin quits (⌘Q,
    /// "Close All Windows", the Dock's Quit) only close the GUI and leave the app
    /// resident with its VMs running headless.
    var shouldTerminateOnQuit: Bool {
        userRequestedAgentQuit || externalQuitRequiresTermination
            || terminationIsTCCRevocation || !viewModel.keepInMenuBarOnQuit
    }

    /// Latches what `classification` demands of the pending quit.
    ///
    /// Flags are only ever set to `true` here, never reset to `false`: a `true`
    /// flag always drives the process toward actual termination on the same call
    /// that set it, so there is never a stale `true` left over. Resetting on
    /// `.stayResident` would let a later, unrelated GUI-origin quit clear the very
    /// flag an in-flight `.later` VM-save depends on.
    func latchQuitClassification(_ classification: QuitClassification) {
        switch classification {
        case .stayResident:
            break
        case .terminateAndSave:
            externalQuitRequiresTermination = true
        case .terminateAndRelaunch:
            terminationIsTCCRevocation = true
        }
    }

    /// A quit Apple Event, as the gate classifies it.
    struct QuitEvent: Equatable {
        /// The sender's PID, as the event carries it — `nil` when it names none.
        var senderPID: pid_t?
    }

    /// What the gate can learn about the process that sent a quit Apple Event.
    struct QuitSenderProbe {
        /// Whether a process with this PID is running.
        let isProcessAlive: (pid_t) -> Bool
        /// The bundle identifier of the application with this PID, or `nil`
        /// when it is no application that has one.
        let bundleID: (pid_t) -> String?
    }

    /// Latches what the quit Apple Event being handled demands, if the pending
    /// quit was delivered by one: the sender is what decides — see
    /// ``classifyQuit(senderPID:sender:)``.
    ///
    /// Read at the gate, from the event being handled, rather than by a handler
    /// of the controller's own: which handler receives a quit changes with the
    /// process's history. AppKit's own has it until the first scripting Apple
    /// event loads Cocoa Scripting's suite registry, which installs the Standard
    /// Suite's `quit` over any handler registered before it — and every one of
    /// them calls `terminate:` inside the event's callout, where the event is
    /// `currentAppleEvent`.
    private func latchClassificationOfQuitEvent() {
        guard let event = pendingQuitEvent() else { return }
        latchClassificationOfQuit(senderPID: event.senderPID)
    }

    /// Latches what a quit delivered by `senderPID` demands.
    private func latchClassificationOfQuit(senderPID: pid_t?) {
        // Resolved once and fed to `classifyQuit` as fixed values so the same
        // attribution result also drives the logging below.
        let attributablePID: pid_t? = senderPID.flatMap { pid in
            guard pid > 0, senderProbe.isProcessAlive(pid) else { return nil }
            return pid
        }
        let bundleID = attributablePID.flatMap(senderProbe.bundleID)

        let classification = Self.classifyQuit(
            senderPID: senderPID,
            sender: QuitSenderProbe(
                isProcessAlive: { _ in attributablePID != nil }, bundleID: { _ in bundleID }))

        if let attributablePID {
            if let bundleID {
                #log(
                    Self.logger, .debug,
                    "Quit Apple Event from PID \(attributablePID, privacy: .public) (bundle: \(bundleID, privacy: .public)) classified as \(String(describing: classification), privacy: .public)"
                )
            } else {
                #log(
                    Self.logger, .warning,
                    "Quit Apple Event: sender PID \(attributablePID, privacy: .public) is alive but could not be resolved to an application with a bundle identifier — classified as \(String(describing: classification), privacy: .public)"
                )
            }
        } else {
            #log(
                Self.logger, .warning,
                "Quit Apple Event sender could not be attributed (PID \(senderPID.map(String.init) ?? "none", privacy: .public)) — failing safe to \(String(describing: classification), privacy: .public)"
            )
        }

        latchQuitClassification(classification)
    }

    // MARK: - Termination Gate

    /// What the termination gate does with a quit request.
    enum TerminationOutcome: Equatable {
        /// Downgrade the quit to a GUI close; the app stays resident.
        case closeGUI
        /// Wait on the save pass already running, without starting a second one.
        case deferToSavePass
        /// Nothing to save and nothing to wait out.
        case terminateNow
        /// Reply later: wait out whatever a quit must not exit through, then
        /// save-suspend whatever is still live.
        case saveThenTerminate
    }

    /// The gate's answer to `applicationShouldTerminate(_:)`.
    enum TerminationReply: Equatable {
        /// The quit does not happen.
        case cancel
        /// Terminate at once.
        case now
        /// Terminate once the save pass answers.
        case later
    }

    /// Decides the termination gate's reply.
    ///
    /// `quitMustWaitOut` forces the deferred reply even when the gate has
    /// nothing of its own to save — ``VMLibrary/quitMustWaitOut``. The window
    /// reconcile answers a different question with `hasUninterruptibleWork`: it
    /// may defer a quit nobody asked for indefinitely, where an explicit quit
    /// may only wait out what termination would corrupt.
    ///
    /// A running save pass outranks the soft-quit downgrade: the app is already
    /// on its way out, so closing the GUI and telling the user it stays resident
    /// would be false.
    ///
    /// A *completed* pass outranks everything: it is the app's own two-phase
    /// quit asking to leave, with the saving already done, and the gate has only
    /// to get out of the way.
    nonisolated static func terminationOutcome(
        hasCompletedSavePass: Bool,
        shouldTerminateAgent: Bool,
        isSavePassRunning: Bool,
        quitMustWaitOut: Bool,
        hasInstancesToSave: Bool
    ) -> TerminationOutcome {
        if hasCompletedSavePass { return .terminateNow }
        if isSavePassRunning { return .deferToSavePass }
        guard shouldTerminateAgent else { return .closeGUI }
        if quitMustWaitOut || hasInstancesToSave { return .saveThenTerminate }
        return .terminateNow
    }

    /// Answers `applicationShouldTerminate(_:)`.
    ///
    /// Every quit path funnels through `terminate:` and thus this method, so
    /// this single gate covers them all — see ``shouldTerminateOnQuit``. A quit
    /// an Apple Event asked for is classified here by that event, whichever
    /// handler delivered it.
    ///
    /// `.later` is reached only by a termination AppKit begins on its own, and
    /// is answered by the save pass — see ``requestFullQuit()``.
    func handleTerminationRequest() -> TerminationReply {
        latchClassificationOfQuitEvent()
        switch Self.terminationOutcome(
            hasCompletedSavePass: hasCompletedTerminationSavePass,
            shouldTerminateAgent: shouldTerminateOnQuit,
            isSavePassRunning: isRunningTerminationSavePass,
            quitMustWaitOut: viewModel.quitMustWaitOut,
            hasInstancesToSave: viewModel.instances.contains(where: \.hasLiveSession)
        ) {
        case .closeGUI:
            #log(Self.logger, .notice, "GUI-origin quit — closing the GUI; app stays resident")
            // Defer so the close runs after this termination request is fully
            // cancelled.
            Task { @MainActor in
                self.residency.closeGUIForSoftQuit()
            }
            return .cancel

        case .deferToSavePass:
            // Deferred, never cancelled: a `.cancel` here would report a veto to
            // whoever asked, and loginwindow reads that as the app refusing a
            // logout, restart, or shut down. `.later` runs a
            // nested wait instead, and the reply this records is what the
            // running pass answers it with when it finishes.
            if terminationIsTCCRevocation {
                relaunchAfterTermination = true
            }
            owesDeferredTerminationReply = true
            #log(Self.logger, .notice, "Quit requested while the termination save pass is running — deferring to it")
            return .later

        case .terminateNow:
            viewModel.abandonArrivalsForTermination()
            return .now

        case .saveThenTerminate:
            // macOS quits and relaunches the app when a TCC permission is revoked, and
            // its built-in relaunch times out while VMs are saving. Mark for relaunch
            // so `applicationWillTerminate` launches the helper after saves complete.
            if terminationIsTCCRevocation {
                relaunchAfterTermination = true
            }
            isRunningTerminationSavePass = true
            owesDeferredTerminationReply = true
            runSavePassThenEndTermination()
            return .later
        }
    }

    /// Answers `applicationWillTerminate(_:)`.
    func handleWillTerminate() {
        if relaunchAfterTermination {
            launchRelaunchHelper()
        }
    }

    /// The single "truly terminate the resident app" path: save every live
    /// guest, then ask AppKit to terminate.
    ///
    /// Two phases, in that order, because the one-phase form cannot work from
    /// here. Terminating first makes the gate reply `.later`, and
    /// AppKit answers that by spinning a nested run loop — which the save pass
    /// this controller runs cannot make progress inside, since it is a
    /// main-actor `Task` and the caller may already be occupying the main queue.
    /// Saving first leaves the gate nothing to wait for, so the caller's context
    /// stops mattering: a command verb, an intent, an observation-driven
    /// reconcile and a menu action all reach this the same way.
    ///
    /// A termination AppKit begins itself — a quit Apple Event, a logout, a TCC
    /// revocation — arrives from its event loop, where that nested wait is safe,
    /// so ``handleTerminationRequest()`` keeps the deferred reply for those and
    /// the pass answers it on the way out.
    ///
    /// A second request while the pass runs joins it rather than starting
    /// another: the pass always ends by ending the termination.
    func requestFullQuit() {
        userRequestedAgentQuit = true
        guard !isRunningTerminationSavePass else {
            #log(Self.logger, .notice, "Full quit requested again — joining the save pass already running")
            return
        }
        #log(Self.logger, .notice, "User-requested full quit — saving live guests, then terminating")
        isRunningTerminationSavePass = true
        runSavePassThenEndTermination()
    }

    /// How a finished save pass ends the termination it ran for.
    enum TerminationEnding: Equatable {
        /// Answer the reply AppKit is waiting on; it resumes the termination it
        /// began and deferred.
        case deferredReply
        /// Ask AppKit to terminate — nothing deferred, so nothing is waiting.
        case terminate
    }

    /// Runs the save pass, then ends the termination it ran for.
    ///
    /// The single body both passes share: one this controller started for a
    /// quit the app initiated, and one the gate started for a termination
    /// AppKit began. They differ only in the ending, which
    /// ``owesDeferredTerminationReply`` decides.
    ///
    /// Begins the library's termination first, so from then on admission
    /// refuses every operation the pass did not ask for — the launch
    /// auto-start's next guest, a create's start-after-create, a user's verb —
    /// and the pass never has to chase a guest brought up behind it.
    private func runSavePassThenEndTermination() {
        viewModel.beginTermination()
        viewModel.abandonArrivalsForTermination()
        Task { @MainActor in
            await self.runTerminationSavePass()
            // A drop/odoc delivered during the async save window above can
            // register a fresh arrival, so sweep again before leaving or its
            // staged tree waits for the next launch's reclaim.
            self.viewModel.abandonArrivalsForTermination()
            self.hasCompletedTerminationSavePass = true
            let ending: TerminationEnding = self.owesDeferredTerminationReply ? .deferredReply : .terminate
            self.owesDeferredTerminationReply = false
            self.endTermination(ending)
        }
    }

    // MARK: - Save Pass

    /// Save-suspends every VM settled live, one session at a time, and waits
    /// out whatever a quit must not exit through whenever nothing is left to
    /// save.
    ///
    /// Saving comes first, so an operation that never ends holds back only
    /// the process's exit, never another VM's save. The wait ends as soon as
    /// another VM settles live, and more work a quit waits out can follow:
    /// an Ephemeral VM's power-off — a save's force-stop fallback among them —
    /// admits its baseline revert, and an operation's end admits the reconcile
    /// an edit admitted before the quit owes that VM. Nothing else can: the
    /// library's termination has begun, so admission refuses every other
    /// operation — which is also why a VM selected here is still settled live
    /// when its save is decided, in the same main-actor turn.
    ///
    /// Each session is saved at most once: a force stop that failed leaves the
    /// same session live, and re-selecting it would loop forever, while a VM
    /// brought back live by a revert holds a new session and is saved again.
    private func runTerminationSavePass() async {
        var handled: Set<UUID> = []
        var savedCount = 0
        var failedCount = 0
        while true {
            if let (instance, sessionID) = nextSessionToSave(excluding: handled) {
                handled.insert(sessionID)
                if await saveForTermination(instance) {
                    savedCount += 1
                } else {
                    failedCount += 1
                }
                continue
            }
            guard viewModel.quitMustWaitOut else { break }
            #log(Self.logger, .notice, "Termination waiting on work a quit must not exit through")
            let saved = handled
            await waitForObservedChange { [viewModel] in
                !viewModel.quitMustWaitOut || self.nextSessionToSave(excluding: saved) != nil
            }
        }
        #log(
            Self.logger, .notice,
            "Termination save complete: \(savedCount, privacy: .public) saved, \(failedCount, privacy: .public) failed"
        )
    }

    /// The first VM settled live on a session not in `handled`, and that
    /// session.
    private func nextSessionToSave(excluding handled: Set<UUID>) -> (VMInstance, UUID)? {
        for instance in viewModel.instances {
            guard instance.phase.isSettledLive, let sessionID = instance.phase.sessionID,
                !handled.contains(sessionID)
            else { continue }
            return (instance, sessionID)
        }
        return nil
    }

    /// Save-suspends one VM for termination, force-stopping it when the save
    /// fails and left a guest still live, so a half-live VM can't outlive the
    /// process.
    ///
    /// A save that failed on its own terms ended its session on the way out,
    /// which is why the termination is asked for only where a Force Stop is
    /// still admitted: the VM it is owed to is one handed back live.
    ///
    /// - Returns: `true` when the state was saved.
    private func saveForTermination(_ instance: VMInstance) async -> Bool {
        do {
            try await viewModel.saveForTermination(instance)
            return true
        } catch {
            #log(
                Self.logger, .error,
                "Failed to save '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
            )
            guard instance.activity.decide(.sessionAction(.forceStop), posture: .commit) == .admit
            else { return false }
            do {
                try await viewModel.tryForceStop(instance)
            } catch {
                #log(
                    Self.logger, .error,
                    "Failed to force-stop '\(instance.name, privacy: .public)' during termination: \(error.localizedDescription, privacy: .public)"
                )
            }
            return false
        }
    }

    // MARK: - Relaunch

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
            #log(Self.logger, .fault, "Relaunch helper not found in app bundle")
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
            #log(Self.logger, .notice, "Launched relaunch helper (watching PID \(pid, privacy: .public))")
        } catch {
            #log(
                Self.logger, .error, "Failed to launch relaunch helper: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
