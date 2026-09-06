import Cocoa
import Darwin
import os

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
final class AppTerminationController: NSObject {
    private let viewModel: VMLibraryViewModel
    /// Where a downgraded quit closes the GUI. `nil` for the test host, which
    /// has no headless mode to downgrade into — so every quit there is a real
    /// one.
    weak var residency: (any SoftQuitHosting)?
    /// The launch work a quit cancels, handed over by
    /// ``registerLaunchWork(_:)``.
    ///
    /// One slot: the launch cluster arms the pass once per process, so a
    /// registration can never drop live work.
    private var cancellableLaunchWork: Task<Void, Never>?

    /// Latched once a termination save pass has started, so a second quit can't
    /// start a second one: its `trySave` would come back as
    /// `operationInProgress` and the catch would force-stop a VM mid-save.
    ///
    /// Never reset, matching the quit flags below: every later quit joins the
    /// pass, which always ends by terminating the app.
    private var isRunningTerminationSavePass = false

    /// Latched once that pass has finished, which is what lets the gate answer
    /// `.terminateNow` for the quit the pass itself then asks for.
    private var hasCompletedTerminationSavePass = false

    /// Whether the gate has answered `.terminateLater` and AppKit is waiting on
    /// the reply the finished pass owes it.
    private var owesDeferredTerminationReply = false

    /// Set by `handleQuitAppleEvent` when the sender is System Settings / TCC.
    private var terminationIsTCCRevocation = false

    /// Set in ``handleTerminationRequest()`` when TCC revocation is detected AND
    /// running VMs require an async save (`.terminateLater`).
    private var relaunchAfterTermination = false

    /// Set by the true-quit affordances (the status item's Quit, the app menu's
    /// "Quit Kernova") so ``handleTerminationRequest()`` proceeds instead of
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

    private static let logger = Logger(subsystem: "app.kernova", category: "AppTermination")

    init(viewModel: VMLibraryViewModel) {
        self.viewModel = viewModel
    }

    // MARK: - Install

    /// Intercepts the Quit Apple Event so `classifyQuit` can inspect its sender.
    ///
    /// The delegate must hold this controller strongly: `NSAppleEventManager`
    /// does not retain an event handler.
    func install() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    /// Takes ownership of a launch task the gate cancels on the way out.
    ///
    /// The auto-start pass outlives the library read, and left running it would
    /// keep starting *further* guests behind the termination save pass.
    /// Cancelling bounds the pass to the VMs it has already reached — the one
    /// inside VZ at that moment still finishes, and a quit does not wait on a
    /// `.starting` VM.
    func registerLaunchWork(_ task: Task<Void, Never>) {
        cancellableLaunchWork = task
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

    /// Whether a pending quit should actually terminate the resident app.
    ///
    /// While *Continue running in Status Bar* is on (the default), GUI-origin quits (⌘Q,
    /// "Close All Windows", the Dock's Quit) only close the GUI and leave the app
    /// resident with its VMs running headless.
    var shouldTerminateOnQuit: Bool {
        guard residency != nil else { return true }
        return userRequestedAgentQuit || externalQuitRequiresTermination
            || terminationIsTCCRevocation || !viewModel.keepInMenuBarOnQuit
    }

    /// Latches what `classification` demands of the pending quit.
    ///
    /// Flags are only ever set to `true` here, never reset to `false`: a `true`
    /// flag always drives the process toward actual termination on the same call
    /// that set it, so there is never a stale `true` left over. Resetting on
    /// `.stayResident` would let a later, unrelated GUI-origin quit clear the very
    /// flag an in-flight `.terminateLater` VM-save depends on.
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

    /// Handles the `kAEQuitApplication` Apple Event by classifying its sender.
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

        latchQuitClassification(classification)

        NSApp.terminate(nil)
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
    ///
    /// A *completed* pass outranks everything: it is the app's own two-phase
    /// quit asking to leave, with the saving already done, and the gate has only
    /// to get out of the way.
    nonisolated static func terminationOutcome(
        hasCompletedSavePass: Bool,
        shouldTerminateAgent: Bool,
        isSavePassRunning: Bool,
        hasSaveInFlight: Bool,
        hasRevertInFlight: Bool,
        hasInstancesToSave: Bool
    ) -> TerminationOutcome {
        if hasCompletedSavePass { return .terminateNow }
        if isSavePassRunning { return .deferToSavePass }
        guard shouldTerminateAgent else { return .closeGUI }
        if hasSaveInFlight || hasRevertInFlight || hasInstancesToSave { return .saveThenTerminate }
        return .terminateNow
    }

    /// Answers `applicationShouldTerminate(_:)`.
    ///
    /// Every quit path funnels through `terminate:` and thus this method, so
    /// this single gate covers them all — see ``shouldTerminateOnQuit``.
    ///
    /// `.terminateLater` is reached only by a termination AppKit begins on its
    /// own, and is answered by the save pass — see ``requestFullQuit()``.
    func handleTerminationRequest() -> NSApplication.TerminateReply {
        switch Self.terminationOutcome(
            hasCompletedSavePass: hasCompletedTerminationSavePass,
            shouldTerminateAgent: shouldTerminateOnQuit,
            isSavePassRunning: isRunningTerminationSavePass,
            hasSaveInFlight: viewModel.hasSaveInFlight,
            hasRevertInFlight: viewModel.hasRevertInFlight,
            hasInstancesToSave: viewModel.instances.contains(where: \.hasLiveSession)
        ) {
        case .closeGUI:
            Self.logger.notice("GUI-origin quit — closing the GUI; app stays resident")
            // Defer so the close runs after this termination request is fully
            // cancelled. `.closeGUI` is unreachable with no `residency`, which is
            // what makes `shouldTerminateOnQuit` unconditionally true there, so
            // the optional chain skips nothing.
            Task { @MainActor in
                self.residency?.closeGUIForSoftQuit()
            }
            return .terminateCancel

        case .deferToSavePass:
            // Deferred, never cancelled: a `.terminateCancel` here would report a
            // veto to whoever asked, and loginwindow reads that as the app
            // refusing a logout, restart, or shut down. `.terminateLater` runs a
            // nested wait instead, and the reply this records is what the
            // running pass answers it with when it finishes.
            if terminationIsTCCRevocation {
                relaunchAfterTermination = true
            }
            owesDeferredTerminationReply = true
            Self.logger.notice("Quit requested while the termination save pass is running — deferring to it")
            return .terminateLater

        case .terminateNow:
            cancellableLaunchWork?.cancel()
            viewModel.cancelAndCleanupPreparing()
            return .terminateNow

        case .saveThenTerminate:
            // Before the save pass, so it never has to chase a guest the launch
            // pass brings up behind it.
            cancellableLaunchWork?.cancel()
            // macOS quits and relaunches the app when a TCC permission is revoked, and
            // its built-in relaunch times out while VMs are saving. Mark for relaunch
            // so `applicationWillTerminate` launches the helper after saves complete.
            if terminationIsTCCRevocation {
                relaunchAfterTermination = true
            }
            isRunningTerminationSavePass = true
            owesDeferredTerminationReply = true
            runSavePassThenEndTermination()
            return .terminateLater
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
    /// here. Terminating first makes the gate reply `.terminateLater`, and
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
            Self.logger.notice("Full quit requested again — joining the save pass already running")
            return
        }
        Self.logger.notice("User-requested full quit — saving live guests, then terminating")
        isRunningTerminationSavePass = true
        // Before the save pass, so it never has to chase a guest the launch
        // pass brings up behind it.
        cancellableLaunchWork?.cancel()
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
    private func runSavePassThenEndTermination() {
        viewModel.cancelAndCleanupPreparing()
        Task { @MainActor in
            await self.runTerminationSavePass()
            // A drop/odoc delivered during the async save window above can
            // register a fresh phantom, so sweep again before leaving or that
            // bundle is orphaned on disk.
            self.viewModel.cancelAndCleanupPreparing()
            self.hasCompletedTerminationSavePass = true
            self.endTermination()
        }
    }

    /// Ends the termination the finished pass ran for.
    private func endTermination() {
        let ending: TerminationEnding = owesDeferredTerminationReply ? .deferredReply : .terminate
        owesDeferredTerminationReply = false
        #if DEBUG
        if let terminationEndingForTesting {
            terminationEndingForTesting(ending)
            return
        }
        #endif
        switch ending {
        case .deferredReply:
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        case .terminate:
            NSApp.terminate(nil)
        }
    }

    #if DEBUG
    /// Stands in for the AppKit call that ends the process, so a test can drive
    /// a full pass without taking the shared test host down.
    var terminationEndingForTesting: (@MainActor (TerminationEnding) -> Void)?
    #endif

    // MARK: - Save Pass

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
}
