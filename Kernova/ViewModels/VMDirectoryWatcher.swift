import Foundation
import KernovaLogging

/// Triggers a reconciliation when something outside the app may have changed
/// the VMs directory: after a write to the directory itself (a bundle added,
/// removed or renamed, Finder's "Put Back" among them) settles, and at once
/// each time the app becomes active.
///
/// A write inside a bundle raises no event on the directory, so a bundle copied
/// in by hand is listed only once its configuration lands, which nothing
/// watched reports; activation is when the user looks again.
@MainActor
final class VMDirectoryWatcher {
    private static let logger = KernovaLogger(subsystem: "app.kernova", category: "VMDirectoryWatcher")

    /// `nonisolated(unsafe)` because `DispatchSource` is not `Sendable` and it must
    /// be cancelled in `deinit` (which is nonisolated); safe because it is only
    /// written in `start()` and read in `deinit`.
    nonisolated(unsafe) private var directorySource: DispatchSourceFileSystemObject?
    private var activationObservation: HostNotification.Observation?
    private var debounceTask: Task<Void, Never>?
    private let appActivation: HostNotification
    private let onReconcile: @MainActor () -> Void

    init(appActivation: HostNotification, onReconcile: @MainActor @escaping () -> Void) {
        self.appActivation = appActivation
        self.onReconcile = onReconcile
    }

    deinit {
        directorySource?.cancel()
    }

    /// Starts both triggers. The activation trigger starts even when the
    /// directory cannot be opened for monitoring.
    func start(directory: URL) {
        activationObservation = appActivation.observe { [weak self] in
            self?.reconcileNow()
        }

        let fd = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else {
            #log(
                Self.logger, .warning,
                "Could not open VMs directory for monitoring: \(directory.path(percentEncoded: false), privacy: .public)"
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )

        source.setEventHandler { [weak self] in
            self?.scheduleReconciliation()
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        directorySource = source

        #log(
            Self.logger, .info,
            "Started directory watcher on \(directory.path(percentEncoded: false), privacy: .public)")
    }

    /// Debounces rapid FS events into a single reconciliation pass after 0.5 seconds of quiet.
    private func scheduleReconciliation() {
        #log(Self.logger, .debug, "Directory change detected, scheduling reconciliation")
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            onReconcile()
        }
    }

    /// Reconciles at once, absorbing a pass a directory write had scheduled.
    private func reconcileNow() {
        debounceTask?.cancel()
        debounceTask = nil
        onReconcile()
    }
}
