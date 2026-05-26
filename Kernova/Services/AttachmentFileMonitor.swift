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
    /// Reads inside a `withObservationTracking` block register an Observation
    /// dependency, so updates refresh the affected rows without a sync check.
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

    /// Off-main probe step invoked by `setPaths(_:)`.
    ///
    /// Default implementation hops to a detached utility-priority task and
    /// performs the blocking syscalls (`FileManager.fileExists` and
    /// `open(O_EVTONLY)` on each new parent) there. Tests inject a stub
    /// via the initializer so race-coalescing assertions can be made
    /// deterministic.
    @ObservationIgnored
    private let probe: Probe

    /// Type of the off-main probe step.
    ///
    /// `@Sendable` so the default implementation can dispatch its body to
    /// a detached task without violating strict concurrency.
    typealias Probe = @Sendable (_ paths: Set<String>, _ parents: Set<String>) async -> ProbeResult

    /// Single-flight coordination for volume mount/unmount refreshes.
    ///
    /// `inFlight` is set while a `refreshAll` is running; `pending` is set
    /// when a new notification arrives during that window. The draining
    /// loop in `drainRefreshAll` keeps running until no new notifications
    /// landed during the previous pass, collapsing a burst of mount
    /// events (one per volume) into a single refresh sweep.
    @ObservationIgnored
    private var refreshAllInFlight: Bool = false
    @ObservationIgnored
    private var refreshAllPending: Bool = false

    init(probe: @escaping Probe = AttachmentFileMonitor.defaultProbe) {
        self.probe = probe
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // RATIONALE: `queue: .main` runs the block on the main
                // thread; spawning an explicitly `@MainActor`-isolated
                // Task lets us call `requestRefreshAll` (sync, MainActor)
                // without an extra hop.
                Task { @MainActor [weak self] in
                    self?.requestRefreshAll()
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

        let result = await probe(added, newParents)

        // Apply results — filtered through the *current* desire so that any
        // path un-requested during the await is silently dropped.
        for (path, exists) in result.existence
        where desiredPaths.contains(path) && existsByPath[path] == nil {
            existsByPath[path] = exists
            pathsByParent[Self.parent(of: path), default: []].insert(path)
        }

        var newlyWatched: [String] = []
        for (parent, fd) in result.parentFDs {
            // Close the fd if the parent is no longer wanted, or if a
            // concurrent setPaths already installed a watcher for it.
            // `close` can briefly block on a network mount, so hop off
            // main to release the descriptor.
            guard pathsByParent[parent] != nil, parentSources[parent] == nil else {
                Self.closeOffMain(fd)
                continue
            }
            installWatcher(fd: fd, parent: parent)
            newlyWatched.append(parent)
        }

        // Close the staleness window between the probe's `fileExists` and
        // the watcher's `source.resume()`: any change that happened in that
        // gap would be invisible to the freshly-installed source, so do
        // one more off-main check now that the watcher is live.
        for parent in newlyWatched {
            await refreshPaths(in: parent)
        }
    }

    /// Releases a file descriptor on a detached utility-priority task.
    ///
    /// `close()` can block briefly on a network mount even for an
    /// `O_EVTONLY` descriptor (the kernel may need to release locks or
    /// flush state), so every `close` call site hops off the main actor.
    private static func closeOffMain(_ fd: Int32) {
        Task.detached(priority: .utility) {
            close(fd)
        }
    }

    /// Default `probe` implementation: runs the blocking syscalls on a
    /// detached utility-priority task so a stale network mount cannot
    /// freeze the main actor. `nonisolated` so it can be used as a
    /// default value for the `init` parameter.
    nonisolated private static let defaultProbe: Probe = { added, newParents in
        await Task.detached(priority: .utility) { [added, newParents] in
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

    /// Async watcher attachment.
    ///
    /// Opens the parent directory's `O_EVTONLY` fd on a detached
    /// utility-priority task — `open()` on a stale network mount can
    /// block, and we never want that on the main actor. Callers must
    /// already hold the main actor; this method `await`s the open then
    /// re-checks invariants before installing the watcher.
    private func startWatching(parent: String) async {
        let (fd, openErrno) = await Task.detached(priority: .utility) {
            let result = open(parent, O_EVTONLY)
            return (result, errno)
        }.value

        guard fd >= 0 else {
            // Parent directory unreachable (e.g. unmounted volume). Tracked
            // existence stays `false`; the next mount notification retries.
            Self.logger.debug(
                "Could not open parent for monitoring (errno=\(openErrno, privacy: .public)): \(parent, privacy: .public)"
            )
            return
        }
        // Recheck after the await: the parent could have been dropped
        // or a concurrent caller could have already installed a watcher.
        guard pathsByParent[parent] != nil, parentSources[parent] == nil else {
            Self.closeOffMain(fd)
            return
        }
        installWatcher(fd: fd, parent: parent)
    }

    /// No-syscall step: takes an already-open `O_EVTONLY` fd and wires it
    /// into a `DispatchSource` registered against the main queue.
    ///
    /// Callers must verify `parentSources[parent] == nil` first — if an
    /// existing source is found we cancel it (closing its fd via the
    /// cancel handler) to avoid a silent leak, and trap in debug builds
    /// so the misuse is caught at the call site.
    private func installWatcher(fd: Int32, parent: String) {
        if let existing = parentSources[parent] {
            Self.logger.fault(
                "installWatcher called with an existing source for parent \(parent, privacy: .public)"
            )
            assertionFailure("installWatcher: parent already watched: \(parent)")
            existing.cancel()
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
            // `setCancelHandler` runs on the source's main queue; spawn
            // a detached task so the close can't stall the UI if the
            // underlying mount is slow to respond.
            Task.detached(priority: .utility) {
                close(fd)
            }
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

    /// Result of one off-main probe batch.
    ///
    /// `Sendable` because the detached probe hands it back across actor
    /// boundaries. `internal` because the test target injects a custom
    /// `probe` closure and needs to construct this directly.
    struct ProbeResult: Sendable {
        /// Existence flag for each path passed in `paths`.
        let existence: [String: Bool]
        /// Open `O_EVTONLY` fd for each parent in `parents` that was reachable.
        ///
        /// Caller takes ownership and is responsible for closing fds that
        /// don't get adopted by a watcher.
        let parentFDs: [String: Int32]

        init(existence: [String: Bool], parentFDs: [String: Int32]) {
            self.existence = existence
            self.parentFDs = parentFDs
        }
    }

    private func scheduleRefresh(for parent: String) {
        debounceTasks[parent]?.cancel()
        debounceTasks[parent] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.refreshPaths(in: parent)
        }
    }

    /// Re-checks every tracked path under `parent` after an FS event.
    ///
    /// The `fileExists` syscalls run on a detached utility-priority task
    /// so an unmount-in-flight (where the path's stat may briefly block)
    /// cannot stall the main actor. After the probe completes we re-read
    /// `pathsByParent` to drop any path the caller un-requested mid-await.
    private func refreshPaths(in parent: String) async {
        guard let snapshot = pathsByParent[parent] else { return }

        let existence = await Task.detached(priority: .utility) { [snapshot] in
            Dictionary(
                uniqueKeysWithValues: snapshot.map {
                    ($0, FileManager.default.fileExists(atPath: $0))
                }
            )
        }.value

        // Re-check the parent — it may have been emptied during the await.
        guard let currentPaths = pathsByParent[parent] else { return }
        for (path, exists) in existence where currentPaths.contains(path) {
            if existsByPath[path] != exists {
                Self.logger.notice(
                    "Attachment existence changed: \(path, privacy: .public) -> \(exists, privacy: .public)"
                )
                existsByPath[path] = exists
            }
        }
    }

    /// Entry point from the volume mount/unmount observers.
    ///
    /// Coalesces a burst of notifications (one per mounted volume when a
    /// USB hub or disk image arrives all at once, say) into a single
    /// refresh sweep. If a refresh is already in flight, sets a "pending"
    /// flag so the drain loop runs one more pass when the current one
    /// finishes; otherwise kicks off the drain.
    private func requestRefreshAll() {
        refreshAllPending = true
        guard !refreshAllInFlight else { return }
        refreshAllInFlight = true
        Task { @MainActor [weak self] in
            await self?.drainRefreshAll()
        }
    }

    private func drainRefreshAll() async {
        while refreshAllPending {
            refreshAllPending = false
            await runRefreshAllPass()
        }
        refreshAllInFlight = false
    }

    /// After a volume mount/unmount, retry parents we couldn't open
    /// earlier and re-check every tracked path.
    ///
    /// Snapshots `pathsByParent.keys` up front so concurrent mutations
    /// during the awaits (a `setPaths` call landing between mount events,
    /// say) can't dereference a missing entry.
    private func runRefreshAllPass() async {
        let parents = Array(pathsByParent.keys)
        for parent in parents where pathsByParent[parent] != nil {
            if parentSources[parent] == nil {
                await startWatching(parent: parent)
            }
            // Re-check after the await: `startWatching` may have hopped
            // through a detached task during which the parent's last
            // tracked path could have been dropped.
            guard pathsByParent[parent] != nil else { continue }
            await refreshPaths(in: parent)
        }
    }

    #if DEBUG
    /// Snapshot of currently-watched parent directories.
    ///
    /// DEBUG-only so tests can verify watcher lifecycle (install / cancel)
    /// without promoting `parentSources` to internal access.
    var watchedParentsForTesting: Set<String> {
        Set(parentSources.keys)
    }
    #endif
}
