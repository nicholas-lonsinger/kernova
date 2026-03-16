import Foundation
import os

/// Watches the VMs directory for external file system changes (e.g., Trash restore via Finder "Put Back")
/// and triggers a reconciliation callback after a debounce period.
@MainActor
final class VMDirectoryWatcher {

    private static let logger = Logger(subsystem: "com.kernova.app", category: "VMDirectoryWatcher")

    /// `nonisolated(unsafe)` because `DispatchSource` is not `Sendable` and we need
    /// to cancel it in `deinit` (which is nonisolated). Safe because it is only
    /// written in `start()` and read in `deinit`.
    nonisolated(unsafe) private var directorySource: DispatchSourceFileSystemObject?
    private var debounceTask: Task<Void, Never>?
    private let onReconcile: @MainActor () -> Void

    init(onReconcile: @MainActor @escaping () -> Void) {
        self.onReconcile = onReconcile
    }

    deinit {
        directorySource?.cancel()
    }

    /// Starts watching the given directory for file system write events.
    func start(directory: URL) {
        let fd = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else {
            Self.logger.warning("Could not open VMs directory for monitoring: \(directory.path(percentEncoded: false))")
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

        Self.logger.info("Started directory watcher on \(directory.path(percentEncoded: false))")
    }

    /// Debounces rapid FS events into a single reconciliation pass after 0.5 seconds of quiet.
    private func scheduleReconciliation() {
        Self.logger.debug("Directory change detected, scheduling reconciliation")
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            onReconcile()
        }
    }
}
