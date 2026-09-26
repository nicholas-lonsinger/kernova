import Foundation
import KernovaLogging

/// Pauses every VM whose guest is executing before the system sleeps and
/// resumes exactly those again on wake.
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

    /// The VMs this coordinator paused for sleep, and so the only ones it
    /// resumes on wake.
    private(set) var sleepPausedInstanceIDs: Set<UUID> = []

    private var sleepWatcher: SystemSleepWatcher?

    private var instances: [VMInstance] { roster.instances }

    init(lifecycle: VMLifecycleCoordinator, roster: any VMInstanceRoster) {
        self.lifecycle = lifecycle
        self.roster = roster
        startSleepWatcher()
    }

    /// Pauses every VM whose guest is executing before system sleep, tracking
    /// which were paused so only those are resumed on wake.
    ///
    /// A VM an operation holds refuses the pause as busy, and is reported.
    func pauseAllForSleep() async {
        let executing = instances.filter(\.phase.guestIsExecuting)
        guard !executing.isEmpty else {
            #log(Self.logger, .debug, "pauseAllForSleep: no running VMs, nothing to pause")
            return
        }

        #log(
            Self.logger, .notice,
            "System going to sleep — pausing \(executing.count, privacy: .public) running VM(s)")

        var failedNames: [String] = []
        for instance in executing {
            do {
                try await lifecycle.pause(instance)
                sleepPausedInstanceIDs.insert(instance.id)
                #log(
                    Self.logger, .debug,
                    "Paused '\(instance.name, privacy: .public)' for sleep (status: \(instance.status.displayName, privacy: .public))"
                )
            } catch {
                guard Self.isReported(error, step: "pause '\(instance.name)' for sleep") else {
                    continue
                }
                failedNames.append(instance.name)
            }
        }
        if !failedNames.isEmpty {
            onFailure?(SleepWakeError.pauseFailed(vmNames: failedNames))
        }
    }

    /// Resumes only VMs that were paused by `pauseAllForSleep()` and are still
    /// live-paused — admission decides which: one that came to rest meanwhile,
    /// or left the library, is passed over, and one an operation holds is
    /// tried and reported.
    func resumeAllAfterWake() async {
        let idsToResume = sleepPausedInstanceIDs
        sleepPausedInstanceIDs.removeAll()
        guard !idsToResume.isEmpty else {
            #log(Self.logger, .debug, "resumeAllAfterWake: no sleep-paused VMs to resume")
            return
        }

        let instancesToResume = instances.filter { instance in
            guard idsToResume.contains(instance.id) else { return false }
            switch instance.activity.decide(.operation(.resuming), posture: .commit) {
            case .admit, .refuse(.busy): return true
            case .join, .refuse: return false
            }
        }
        guard !instancesToResume.isEmpty else { return }

        #log(
            Self.logger, .notice,
            "System woke up — resuming \(instancesToResume.count, privacy: .public) sleep-paused VM(s)")

        var failedNames: [String] = []
        for instance in instancesToResume {
            do {
                try await lifecycle.resume(instance)
                #log(
                    Self.logger, .debug,
                    "Resumed '\(instance.name, privacy: .public)' after wake (status: \(instance.status.displayName, privacy: .public))"
                )
            } catch {
                guard Self.isReported(error, step: "resume '\(instance.name)' after wake") else {
                    continue
                }
                failedNames.append(instance.name)
            }
        }
        if !failedNames.isEmpty {
            onFailure?(SleepWakeError.resumeFailed(vmNames: failedNames))
        }
    }

    /// Logs a `step` — "pause 'VM' for sleep" — that failed, answering
    /// whether the user is told: a refusal the app's own termination raised is
    /// not reported.
    private static func isReported(_ error: any Error, step: String) -> Bool {
        guard (error as? VMAdmissionRefusal)?.refusal != .terminating else {
            #log(logger, .notice, "Did not \(step, privacy: .public): the app is terminating")
            return false
        }
        #log(
            logger, .error,
            "Failed to \(step, privacy: .public): \(error.localizedDescription, privacy: .public)")
        return true
    }

    private func startSleepWatcher() {
        let watcher = SystemSleepWatcher(
            onSleep: { [weak self] in
                await self?.pauseAllForSleep()
            },
            onWake: { [weak self] in
                await self?.resumeAllAfterWake()
            }
        )
        watcher.start()
        sleepWatcher = watcher
    }

    /// Error type for sleep/wake lifecycle failures.
    private enum SleepWakeError: LocalizedError {
        case pauseFailed(vmNames: [String])
        case resumeFailed(vmNames: [String])

        var errorDescription: String? {
            switch self {
            case .pauseFailed(let vmNames):
                assert(!vmNames.isEmpty, "pauseFailed requires at least one VM name")
                return
                    "Failed to pause the following VMs before sleep: \(vmNames.joined(separator: ", ")). They may experience data corruption."
            case .resumeFailed(let vmNames):
                assert(!vmNames.isEmpty, "resumeFailed requires at least one VM name")
                return
                    "Failed to resume the following VMs after wake: \(vmNames.joined(separator: ", ")). You may need to restart them manually."
            }
        }
    }
}
