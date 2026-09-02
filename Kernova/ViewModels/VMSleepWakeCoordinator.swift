import Foundation
import os

/// Pauses every running VM before the system sleeps and resumes exactly those
/// again on wake.
///
/// Drives ``VMLifecycleCoordinator`` directly rather than going through the
/// command verbs: the pass pre-filters to running and paused VMs, so the verbs'
/// gates buy nothing, and `resume` as a verb surfaces a display window the user
/// never asked for.
///
/// Headless: anything a user has to be told about leaves through ``onFailure``.
@MainActor
final class VMSleepWakeCoordinator {
    nonisolated private static let logger = Logger(
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

    /// Pauses all running VMs before system sleep, tracking which were auto-paused so
    /// only those are resumed on wake.
    func pauseAllForSleep() async {
        let runningInstances = instances.filter { $0.status == .running }
        guard !runningInstances.isEmpty else {
            Self.logger.debug("pauseAllForSleep: no running VMs, nothing to pause")
            return
        }

        Self.logger.notice("System going to sleep — pausing \(runningInstances.count, privacy: .public) running VM(s)")

        var failedNames: [String] = []
        for instance in runningInstances {
            do {
                try await lifecycle.pause(instance)
                sleepPausedInstanceIDs.insert(instance.id)
                Self.logger.debug(
                    "Paused '\(instance.name, privacy: .public)' for sleep (status: \(instance.status.displayName, privacy: .public))"
                )
            } catch {
                Self.logger.error(
                    "Failed to pause '\(instance.name, privacy: .public)' for sleep: \(error.localizedDescription, privacy: .public)"
                )
                failedNames.append(instance.name)
            }
        }
        if !failedNames.isEmpty {
            onFailure?(SleepWakeError.pauseFailed(vmNames: failedNames))
        }
    }

    /// Resumes only VMs that were auto-paused by `pauseAllForSleep()`.
    func resumeAllAfterWake() async {
        let idsToResume = sleepPausedInstanceIDs
        sleepPausedInstanceIDs.removeAll()
        guard !idsToResume.isEmpty else {
            Self.logger.debug("resumeAllAfterWake: no sleep-paused VMs to resume")
            return
        }

        let instancesToResume = instances.filter { idsToResume.contains($0.id) && $0.status == .paused }
        guard !instancesToResume.isEmpty else { return }

        Self.logger.notice("System woke up — resuming \(instancesToResume.count, privacy: .public) sleep-paused VM(s)")

        var failedNames: [String] = []
        for instance in instancesToResume {
            do {
                try await lifecycle.resume(instance)
                Self.logger.debug(
                    "Resumed '\(instance.name, privacy: .public)' after wake (status: \(instance.status.displayName, privacy: .public))"
                )
            } catch {
                Self.logger.error(
                    "Failed to resume '\(instance.name, privacy: .public)' after wake: \(error.localizedDescription, privacy: .public)"
                )
                failedNames.append(instance.name)
            }
        }
        if !failedNames.isEmpty {
            onFailure?(SleepWakeError.resumeFailed(vmNames: failedNames))
        }
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
