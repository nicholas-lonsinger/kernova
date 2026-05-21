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
    /// tracked path. `@ObservationIgnored` because nothing outside this class
    /// reads it — wrapping it in observation accessors would only waste cycles.
    @ObservationIgnored
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

    /// Most recent path set requested via `setPaths(_:)`.
    ///
    /// Recorded synchronously at the start of each call so that, after an
    /// `await` for the off-main existence probe, we can drop work whose
    /// path the caller has since un-requested. This is the single source of
    /// truth for "what the UI currently wants tracked" during the window
    /// when a stale-mount syscall is in flight.
    @ObservationIgnored
    private var desiredPaths: Set<String> = []

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
    /// Returns `true` for paths whose existence has not yet been determined
    /// (either never requested via `setPaths(_:)`, or requested but still
    /// in flight on the off-main probe). The optimistic default means the
    /// UI does not flash a missing-file indicator while the first probe
    /// settles.
    func exists(_ path: String) -> Bool {
        existsByPath[path] ?? true
    }

    /// Replaces the set of paths being watched.
    ///
    /// Idempotent: only diff churn (added / removed paths) triggers FS work.
    /// The synchronous portion (computing the diff, dropping removed paths,
    /// cancelling their watchers) runs immediately on the main actor; the
    /// blocking syscalls (`FileManager.fileExists`, `open(O_EVTONLY)` on
    /// each new parent directory) run on a detached utility-priority Task
    /// so a stale network mount cannot freeze the UI.
    ///
    /// Concurrent calls coalesce safely: the last call wins for *desired
    /// state*, and any in-flight probe whose paths have been un-desired by
    /// a later call has its results discarded on resume.
    func setPaths(_ paths: Set<String>) async {
        let next = paths.filter { !$0.isEmpty }
        desiredPaths = next

        // Drop entries no longer wanted. All in-memory, runs immediately.
        let removed = Set(existsByPath.keys).subtracting(next)
        for path in removed {
            detach(path: path)
        }

        // Identify the off-main work needed: any path whose existence we
        // don't yet know, and any parent directory we don't yet watch.
        let added = next.subtracting(Set(existsByPath.keys))
        let newParents = Set(added.map { Self.parent(of: $0) })
            .subtracting(Set(parentSources.keys))
        guard !added.isEmpty || !newParents.isEmpty else { return }

        let probe = await Task.detached(priority: .utility) { [added, newParents] in
            ProbeResult(
                existence: Dictionary(
                    uniqueKeysWithValues: added.map {
                        ($0, FileManager.default.fileExists(atPath: $0))
                    }
                ),
                parentFDs: Dictionary(
                    uniqueKeysWithValues: newParents.compactMap { parent -> (String, Int32)? in
                        let fd = open(parent, O_EVTONLY)
                        return fd >= 0 ? (parent, fd) : nil
                    }
                )
            )
        }.value

        // Apply results — filtered through the *current* desire so that any
        // path un-requested during the await is silently dropped.
        for (path, exists) in probe.existence
        where desiredPaths.contains(path) && existsByPath[path] == nil {
            existsByPath[path] = exists
            pathsByParent[Self.parent(of: path), default: []].insert(path)
        }
        for (parent, fd) in probe.parentFDs {
            // Close the fd if the parent is no longer wanted, or if a
            // concurrent setPaths already installed a watcher for it.
            guard pathsByParent[parent] != nil, parentSources[parent] == nil else {
                close(fd)
                continue
            }
            installWatcher(fd: fd, parent: parent)
        }
    }

    /// Tear-down for a single path.
    ///
    /// Used by the `setPaths` removal branch (and reserved for future
    /// targeted removals).
    private func detach(path: String) {
        existsByPath.removeValue(forKey: path)
        let parent = Self.parent(of: path)
        guard var siblings = pathsByParent[parent] else { return }
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

    /// Synchronous watcher attachment.
    ///
    /// Used by `refreshAll` after a volume mount notification — the
    /// directory just became reachable, so `open()` is hot-cache fast.
    /// `setPaths` instead opens the fd inside its detached probe.
    private func startWatching(parent: String) {
        let fd = open(parent, O_EVTONLY)
        guard fd >= 0 else {
            // Parent directory unreachable (e.g. unmounted volume). Tracked
            // existence stays `false`; the next mount notification retries.
            Self.logger.debug(
                "Could not open parent for monitoring (errno=\(errno, privacy: .public)): \(parent, privacy: .public)"
            )
            return
        }
        installWatcher(fd: fd, parent: parent)
    }

    /// No-syscall step: takes an already-open `O_EVTONLY` fd and wires it
    /// into a `DispatchSource` registered against the main queue.
    private func installWatcher(fd: Int32, parent: String) {
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

    /// Parent directory of `path` as a string.
    ///
    /// Wrapping the `NSString` idiom in one place keeps call sites compact.
    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Result of one off-main probe batch. `Sendable` because the detached
    /// Task hands it back across actor boundaries.
    private struct ProbeResult: Sendable {
        let existence: [String: Bool]
        let parentFDs: [String: Int32]
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
