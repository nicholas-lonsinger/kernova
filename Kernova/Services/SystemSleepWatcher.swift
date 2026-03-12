import AppKit
import os

/// Observes system sleep/wake notifications and invokes callbacks.
///
/// Mirrors the `VMDirectoryWatcher` pattern: `@MainActor`-isolated, callback-driven,
/// with `nonisolated(unsafe)` for observer references needed in `deinit`.
@MainActor
final class SystemSleepWatcher {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "SystemSleepWatcher")

    /// `nonisolated(unsafe)` because `NSObjectProtocol` observer tokens are not `Sendable`
    /// and we need to remove them in `deinit` (which is nonisolated). Safe because they are
    /// only written in `start()` and read in `deinit`.
    nonisolated(unsafe) private var sleepObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var wakeObserver: (any NSObjectProtocol)?

    private let onSleep: @MainActor () async -> Void
    private let onWake: @MainActor () async -> Void

    init(
        onSleep: @MainActor @escaping () async -> Void,
        onWake: @MainActor @escaping () async -> Void
    ) {
        self.onSleep = onSleep
        self.onWake = onWake
    }

    deinit {
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    /// Registers observers for system sleep and wake notifications.
    func start() {
        let center = NSWorkspace.shared.notificationCenter

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                Self.logger.notice("System will sleep — invoking sleep handler")
                let onSleep = self.onSleep
                Task { @MainActor in
                    await onSleep()
                }
            }
        }

        wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                Self.logger.notice("System did wake — invoking wake handler")
                let onWake = self.onWake
                Task { @MainActor in
                    await onWake()
                }
            }
        }

        Self.logger.info("Started system sleep/wake watcher")
    }
}
