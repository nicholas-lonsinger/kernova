import AppKit
import Foundation
import os

/// Reactive existence tracker for the user-supplied file paths surfaced as
/// VM attachments (external storage disks, removable media).
///
/// The settings view binds to `exists(_:)` to render a missing-file
/// indicator. Watching avoids both the per-render `fileExists` syscall
/// and the staleness that comes from only checking on body evaluation:
///
/// - Each unique parent directory of a tracked path gets a single
///   `DispatchSourceFileSystemObject` watching for write / delete /
///   rename events. On any event we debounce briefly, then re-check
///   the tracked paths whose parent fired the event.
/// - `NSWorkspace.didMountNotification` / `didUnmountNotification` trigger
///   a full refresh so paths on removable volumes flip immediately when
///   the volume is ejected (FSEvents on the mount point disappears with
///   the volume itself), and so we can attach a parent watcher we
///   couldn't open earlier because the volume wasn't mounted yet.
@MainActor
@Observable
final class AttachmentFileMonitor {
    private static let logger = Logger(subsystem: "com.kernova.app", category: "AttachmentFileMonitor")

    /// Latest known existence flag for each watched path.
    ///
    /// Reads inside a SwiftUI `body` register an Observation dependency, so
    /// updates re-render the row without a synchronous filesystem check.
    private(set) var existsByPath: [String: Bool] = [:]

    /// Parent directory -> live watcher. `nonisolated(unsafe)` so `deinit`
    /// can cancel sources; `@ObservationIgnored` keeps the Observation
    /// macro from synthesizing main-actor-isolated access wrappers around
    /// this internal bookkeeping (it otherwise re-isolates the storage
    /// and the directive looks "no-op" to the compiler).
    @ObservationIgnored
    nonisolated(unsafe) private var parentSources: [String: DispatchSourceFileSystemObject] = [:]

    /// Parent directory -> tracked paths whose direct parent is that directory.
    ///
    /// Enables a targeted re-check on an FS event instead of rescanning every
    /// tracked path.
    private var pathsByParent: [String: Set<String>] = [:]

    /// Per-parent debounce so a burst of FS events coalesces into one
    /// existence re-check.
    @ObservationIgnored
    private var debounceTasks: [String: Task<Void, Never>] = [:]

    /// Notification-center tokens for volume mount/unmount observers.
    ///
    /// `@ObservationIgnored` + `nonisolated(unsafe)` so `deinit` can hand the
    /// tokens back to `NSNotificationCenter`; only mutated on the main actor.
    @ObservationIgnored
    nonisolated(unsafe) private var volumeObservers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // RATIONALE: `queue: .main` guarantees this fires on the
                // main thread; `assumeIsolated` lets a `@Sendable` block
                // call MainActor-isolated state under strict concurrency.
                MainActor.assumeIsolated {
                    self?.refreshAll()
                }
            }
            volumeObservers.append(token)
        }
    }

    deinit {
        for source in parentSources.values {
            source.cancel()
        }
        let center = NSWorkspace.shared.notificationCenter
        for token in volumeObservers {
            center.removeObserver(token)
        }
    }

    /// Latest known existence flag for `path`.
    ///
    /// Returns `true` for paths that aren't being watched so the UI does
    /// not flash a missing-file indicator during the brief window between
    /// the view appearing and the first `setPaths(_:)` call.
    func exists(_ path: String) -> Bool {
        existsByPath[path] ?? true
    }

    /// Replaces the set of paths being watched.
    ///
    /// Idempotent: only diff churn (added / removed paths) triggers FS
    /// work. Existence flags for newly added paths are populated
    /// synchronously here so the first row render shows the correct
    /// state.
    func setPaths(_ paths: Set<String>) {
        let nextPaths = paths.filter { !$0.isEmpty }
        let currentPaths = Set(existsByPath.keys)
        let added = nextPaths.subtracting(currentPaths)
        let removed = currentPaths.subtracting(nextPaths)

        for path in removed {
            existsByPath.removeValue(forKey: path)
            let parent = (path as NSString).deletingLastPathComponent
            guard var siblings = pathsByParent[parent] else { continue }
            siblings.remove(path)
            if siblings.isEmpty {
                pathsByParent.removeValue(forKey: parent)
                parentSources[parent]?.cancel()
                parentSources.removeValue(forKey: parent)
                debounceTasks[parent]?.cancel()
                debounceTasks.removeValue(forKey: parent)
            } else {
                pathsByParent[parent] = siblings
            }
        }

        for path in added {
            existsByPath[path] = FileManager.default.fileExists(atPath: path)
            let parent = (path as NSString).deletingLastPathComponent
            pathsByParent[parent, default: []].insert(path)
            if parentSources[parent] == nil {
                startWatching(parent: parent)
            }
        }
    }

    private func startWatching(parent: String) {
        let fd = open(parent, O_EVTONLY)
        guard fd >= 0 else {
            // Parent directory unreachable (e.g. unmounted volume). Tracked
            // existence stays `false`; a volume-mount notification will
            // retry this path's parent.
            Self.logger.debug(
                "Could not open parent for monitoring (errno=\(errno, privacy: .public)): \(parent, privacy: .public)"
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.scheduleRefresh(for: parent)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        parentSources[parent] = source

        Self.logger.debug("Started attachment watcher on \(parent, privacy: .public)")
    }

    private func scheduleRefresh(for parent: String) {
        debounceTasks[parent]?.cancel()
        debounceTasks[parent] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refreshPaths(in: parent)
        }
    }

    private func refreshPaths(in parent: String) {
        guard let paths = pathsByParent[parent] else { return }
        for path in paths {
            let exists = FileManager.default.fileExists(atPath: path)
            if existsByPath[path] != exists {
                Self.logger.notice(
                    "Attachment existence changed: \(path, privacy: .public) -> \(exists, privacy: .public)"
                )
                existsByPath[path] = exists
            }
        }
    }

    private func refreshAll() {
        // After a volume mount/unmount, retry parents we couldn't open
        // earlier and re-check every tracked path.
        for parent in pathsByParent.keys {
            if parentSources[parent] == nil {
                startWatching(parent: parent)
            }
            refreshPaths(in: parent)
        }
    }
}
