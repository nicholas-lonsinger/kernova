import Foundation
import KernovaLogging

/// Pauses every VM with a live session before the system sleeps, holding
/// sleep until each pause has ended, and resumes exactly the VMs it paused on
/// wake.
///
/// Each pause and resume is a ``VMFollowUp`` on the VM, so a VM an operation
/// holds is paused when that operation frees it, and each one's own admission
/// decides whether it still applies — the passes filter nothing by status.
///
/// Drives ``VMLifecycleCoordinator`` directly rather than going through the
/// command verbs: `resume` as a verb surfaces a display window the user never
/// asked for.
///
/// Headless: anything a user has to be told about leaves through ``onFailure``.
@MainActor
final class VMSleepWakeCoordinator {
    nonisolated private static let logger = KernovaLogger(
        subsystem: "app.kernova", category: "VMSleepWakeCoordinator")

    private let lifecycle: VMLifecycleCoordinator
    private let roster: any VMInstanceRoster

    /// Receives every failure the pass needs a user to see.
    var onFailure: ((any Error) -> Void)?

    /// A pause the sleep pass followed on one VM's session.
    private struct SleepPause {
        weak var instance: VMInstance?
        let name: String
        let sessionID: UUID
        let followUp: VMFollowUp
    }

    /// The pauses the sleep pass followed that no wake has settled yet.
    private var sleepPauses: [SleepPause] = []

    /// What drives the passes; `nil` for a coordinator only its caller
    /// drives.
    private let systemSleep: SystemSleepWatcher?

    private var instances: [VMInstance] { roster.instances }

    init(
        lifecycle: VMLifecycleCoordinator, roster: any VMInstanceRoster,
        systemSleep: SystemSleepWatcher? = nil
    ) {
        self.lifecycle = lifecycle
        self.roster = roster
        self.systemSleep = systemSleep
        systemSleep?.start(
            onSleep: { [weak self] allowSleep in
                guard let self else { return allowSleep() }
                self.pauseAllForSleep(thenAllowSleep: allowSleep)
            },
            onWake: { [weak self] in
                self?.resumeAllAfterWake()
            })
    }

    /// Follows a pause on every VM with a live session before this returns;
    /// the task it answers then waits for every one of them to end, reports
    /// those that failed, and only then calls `allowSleep`.
    ///
    /// A VM at rest has nothing to pause and gets nothing. A pause whose VM
    /// was not running when it drained, whose session ended first, or that the
    /// app's termination refused, ends without being reported.
    @discardableResult
    func pauseAllForSleep(
        thenAllowSleep allowSleep: @escaping @MainActor () -> Void
    ) -> Task<Void, Never> {
        let pauses = instances.compactMap(followPauseForSleep)
        sleepPauses.append(contentsOf: pauses)
        if pauses.isEmpty {
            #log(Self.logger, .notice, "System going to sleep — no VM has a live session to pause")
        } else {
            #log(
                Self.logger, .notice,
                "System going to sleep — pausing \(pauses.count, privacy: .public) VM(s) with a live session"
            )
        }
        return Task { @MainActor [weak self] in
            var failedNames: [String] = []
            for pause in pauses {
                do {
                    try await pause.followUp.outcome.value()
                    #log(Self.logger, .notice, "Paused '\(pause.name, privacy: .public)' for sleep")
                } catch {
                    guard
                        Self.isReported(
                            error, of: pause.followUp, step: "pause '\(pause.name)' for sleep")
                    else { continue }
                    failedNames.append(pause.name)
                }
            }
            if !failedNames.isEmpty {
                self?.onFailure?(SleepWakeError.pauseFailed(vmNames: failedNames))
            }
            #log(Self.logger, .notice, "Every sleep pause has ended — allowing sleep")
            allowSleep()
        }
    }

    /// Settles every pause the sleep pass followed before this returns: one
    /// still queued is withdrawn and reported as not paused, and every other
    /// that has not failed gets a resume followed on its session — behind the
    /// pause itself while that still runs. The task this answers waits for
    /// the resumes and reports those that failed.
    ///
    /// A resume whose VM is no longer live-paused on that session — its pause
    /// failed as it ended, the user resumed it, it came to rest or left the
    /// library — ends without being reported.
    @discardableResult
    func resumeAllAfterWake() -> Task<Void, Never> {
        let pauses = sleepPauses
        sleepPauses.removeAll()
        var notPausedNames: [String] = []
        var resumes: [(name: String, followUp: VMFollowUp)] = []
        for pause in pauses {
            guard let instance = pause.instance else { continue }
            if instance.activity.withdraw(pause.followUp) {
                #log(
                    Self.logger, .notice,
                    "Withdrew the sleep pause still queued on '\(pause.name, privacy: .public)': the system slept first"
                )
                notPausedNames.append(pause.name)
                continue
            }
            // The sleep pass accounted for a pause that did not pause.
            if case .failure = pause.followUp.outcome.result { continue }
            resumes.append((pause.name, followResume(after: pause, on: instance)))
        }
        if !notPausedNames.isEmpty {
            onFailure?(SleepWakeError.notPausedBeforeSleep(vmNames: notPausedNames))
        }
        if !resumes.isEmpty {
            #log(
                Self.logger, .notice,
                "System woke up — resuming \(resumes.count, privacy: .public) VM(s) paused for sleep")
        }
        return Task { @MainActor [weak self] in
            var failedNames: [String] = []
            for resume in resumes {
                do {
                    try await resume.followUp.outcome.value()
                    #log(Self.logger, .notice, "Resumed '\(resume.name, privacy: .public)' after wake")
                } catch {
                    guard
                        Self.isReported(
                            error, of: resume.followUp, step: "resume '\(resume.name)' after wake")
                    else { continue }
                    failedNames.append(resume.name)
                }
            }
            if !failedNames.isEmpty {
                self?.onFailure?(SleepWakeError.resumeFailed(vmNames: failedNames))
            }
        }
    }

    /// Follows a resume on the session `pause` paused.
    private func followResume(after pause: SleepPause, on instance: VMInstance) -> VMFollowUp {
        let resume = VMFollowUp(scope: .session(pause.sessionID), rank: .ordinary) {
            [lifecycle, weak instance] outcome in
            guard let instance else { throw CancellationError() }
            try lifecycle.launchResume(instance, resolving: outcome)
        }
        instance.activity.follow(resume)
        return resume
    }

    /// Follows a pause on the live session of `instance`, or nothing when it
    /// has none.
    private func followPauseForSleep(_ instance: VMInstance) -> SleepPause? {
        guard let sessionID = instance.liveSessionID else { return nil }
        let followUp = VMFollowUp(scope: .session(sessionID), rank: .ordinary) {
            [lifecycle, weak instance] outcome in
            guard let instance else { throw CancellationError() }
            try lifecycle.launchPause(instance, resolving: outcome)
        }
        let pause = SleepPause(
            instance: instance, name: instance.name, sessionID: sessionID, followUp: followUp)
        instance.activity.follow(followUp)
        return pause
    }

    /// Logs a `step` — "pause 'VM' for sleep" — that `followUp` ended with
    /// `error`, answering whether the user is told, by
    /// ``VMFollowUp/isReportable(_:scope:)``.
    private static func isReported(
        _ error: any Error, of followUp: VMFollowUp, step: String
    ) -> Bool {
        guard VMFollowUp.isReportable(error, scope: followUp.scope) else {
            #log(
                logger, .notice,
                "Did not \(step, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
        #log(
            logger, .error,
            "Failed to \(step, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return true
    }

    /// Error type for sleep/wake lifecycle failures.
    private enum SleepWakeError: LocalizedError {
        case pauseFailed(vmNames: [String])
        case notPausedBeforeSleep(vmNames: [String])
        case resumeFailed(vmNames: [String])

        var errorDescription: String? {
            switch self {
            case .pauseFailed(let vmNames):
                assert(!vmNames.isEmpty, "pauseFailed requires at least one VM name")
                return
                    "Failed to pause the following VMs before sleep: \(vmNames.joined(separator: ", "))."
            case .notPausedBeforeSleep(let vmNames):
                assert(!vmNames.isEmpty, "notPausedBeforeSleep requires at least one VM name")
                return
                    "The Mac slept before the following VMs could be paused, because another operation was still holding each of them: \(vmNames.joined(separator: ", "))."
            case .resumeFailed(let vmNames):
                assert(!vmNames.isEmpty, "resumeFailed requires at least one VM name")
                return
                    "Failed to resume the following VMs after wake: \(vmNames.joined(separator: ", ")). You may need to restart them manually."
            }
        }
    }
}
