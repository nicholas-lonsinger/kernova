import AppKit
import Foundation
import os

/// Reactive existence tracker for the user-supplied file paths a VM points at
/// (external storage disks, removable media, shared directories).
///
/// One `DispatchSourceFileSystemObject` per unique parent directory, plus the
/// full re-probe `revalidate()` runs. Existence probes must go through each
/// path's security bookmark: under the sandbox a raw `fileExists` on an
/// out-of-container path is denied and would mark every present attachment
/// missing.
///
/// Watching is best-effort: a file-scoped bookmark never grants its parent
/// directory, so `open(parent, O_EVTONLY)` fails for most external attachments and
/// the `fd >= 0` guard leaves those parents unwatched. Freshness then rests on the
/// coarse triggers that reach `revalidate()` — app activation and `NSWorkspace`
/// mount/unmount from here, plus the settings shell's calls when its pane comes
/// back — which is why they are not redundant with the per-parent sources. The
/// authoritative check runs at VM start; this only backs a warning affordance.
@MainActor
@Observable
final class AttachmentFileMonitor {
    private static let logger = Logger(subsystem: "app.kernova", category: "AttachmentFileMonitor")

    /// Latest known existence flag for each watched path.
    private(set) var existsByPath: [String: Bool] = [:]

    /// Parent directory -> live watcher.
    ///
    /// `nonisolated(unsafe)` so `deinit` can cancel the sources;
    /// `@ObservationIgnored` keeps the macro from re-isolating the storage behind
    /// main-actor accessors.
    @ObservationIgnored
    nonisolated(unsafe) private var parentSources: [String: DispatchSourceFileSystemObject] = [:]

    /// Parent directory -> tracked paths whose direct parent is that directory.
    ///
    /// Enables a targeted re-check on an FS event instead of rescanning every
    /// tracked path.
    @ObservationIgnored
    private var pathsByParent: [String: Set<String>] = [:]

    /// Per-parent debounce so a burst of FS events coalesces into one
    /// existence re-check.
    @ObservationIgnored
    private var debounceTasks: [String: Task<Void, Never>] = [:]

    /// Notification tokens for the re-probe triggers, each paired with the center
    /// that minted it — `NSWorkspace.shared.notificationCenter` and
    /// `NotificationCenter.default` are different objects, and a token is only
    /// removable from its own.
    ///
    /// `nonisolated(unsafe)` so `deinit` can hand the tokens back to
    /// `NSNotificationCenter`; only mutated on the main actor.
    @ObservationIgnored
    nonisolated(unsafe) private var triggerObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    /// Most recent path set requested via `setPaths(_:)`.
    ///
    /// Recorded synchronously at the start of each call, so work whose path the
    /// caller has since un-requested can be dropped after an `await`.
    @ObservationIgnored
    private var desiredPaths: Set<String> = []

    /// Security bookmark for each tracked path that has one, so existence
    /// probes can run under a momentary scope (see the class doc).
    @ObservationIgnored
    private var bookmarkByPath: [String: Data] = [:]

    /// Off-main probe step invoked by `setPaths(_:)`.
    ///
    /// The default implementation hops to a detached utility-priority task and
    /// performs the blocking syscalls (`FileManager.fileExists`, and
    /// `open(O_EVTONLY)` on each new parent) there.
    @ObservationIgnored
    private let probe: Probe

    /// Type of the off-main probe step.
    ///
    /// `bookmarks` carries the security bookmark for each path that has one, so
    /// the existence syscall can run under a momentary scope.
    typealias Probe =
        @Sendable (
            _ paths: Set<String>, _ bookmarks: [String: Data], _ parents: Set<String>
        ) async -> ProbeResult

    /// Single-flight coordination for `revalidate()`.
    ///
    /// `drainRefreshAll` keeps looping while `pending` is set, collapsing a burst
    /// of triggers (one mount event per volume, an activation landing beside the
    /// shell's own call) into a single refresh sweep.
    @ObservationIgnored
    private var refreshAllInFlight: Bool = false
    @ObservationIgnored
    private var refreshAllPending: Bool = false

    init(probe: @escaping Probe = AttachmentFileMonitor.defaultProbe) {
        self.probe = probe
        let workspace = NSWorkspace.shared.notificationCenter
        let triggers: [(center: NotificationCenter, name: Notification.Name)] = [
            (workspace, NSWorkspace.didMountNotification),
            (workspace, NSWorkspace.didUnmountNotification),
            (.default, NSApplication.didBecomeActiveNotification),
        ]
        for trigger in triggers {
            let token = trigger.center.addObserver(
                forName: trigger.name, object: nil, queue: .main
            ) { [weak self] _ in
                // `queue: .main` delivers on the main thread, where the @MainActor
                // `revalidate` is callable synchronously.
                MainActor.assumeIsolated {
                    self?.revalidate()
                }
            }
            triggerObservers.append((trigger.center, token))
        }
    }

    deinit {
        for source in parentSources.values {
            source.cancel()
        }
        for observer in triggerObservers {
            observer.center.removeObserver(observer.token)
        }
    }

    /// Latest known existence flag for `path`.
    ///
    /// Optimistically `true` for paths not yet determined, so the UI does not
    /// flash a missing-file indicator while the first probe settles.
    func exists(_ path: String) -> Bool {
        existsByPath[path] ?? true
    }

    /// Replaces the set of paths being watched, keyed path → security bookmark
    /// (`nil` for paths without one).
    ///
    /// Idempotent: only diff churn triggers FS work, and the blocking syscalls run
    /// on a detached utility-priority Task so a stale network mount cannot freeze
    /// the UI. Concurrent calls coalesce — the last call wins for *desired state*,
    /// and an in-flight probe whose paths were since un-desired is discarded.
    func setPaths(_ refs: [String: Data?]) async {
        let next = Set(refs.keys.filter { !$0.isEmpty })
        desiredPaths = next
        bookmarkByPath = refs.reduce(into: [:]) { partial, entry in
            if !entry.key.isEmpty, let bookmark = entry.value {
                partial[entry.key] = bookmark
            }
        }

        // Drop entries no longer wanted. All in-memory, runs immediately.
        let removed = Set(existsByPath.keys).subtracting(next)
        for path in removed {
            detach(path: path)
        }

        let added = next.subtracting(Set(existsByPath.keys))
        let newParents = Set(added.map { Self.parent(of: $0) })
            .subtracting(Set(parentSources.keys))
        guard !added.isEmpty || !newParents.isEmpty else { return }

        let result = await probe(added, bookmarks(for: added), newParents)

        // Filtered through the *current* desire, so a path un-requested during the
        // await is silently dropped.
        for (path, exists) in result.existence
        where desiredPaths.contains(path) && existsByPath[path] == nil {
            existsByPath[path] = exists
            pathsByParent[Self.parent(of: path), default: []].insert(path)
        }

        var newlyWatched: [String] = []
        for (parent, fd) in result.parentFDs {
            // Close the fd if the parent is no longer wanted, or if a concurrent
            // setPaths already installed a watcher for it.
            guard pathsByParent[parent] != nil, parentSources[parent] == nil else {
                Self.closeOffMain(fd)
                continue
            }
            installWatcher(fd: fd, parent: parent)
            newlyWatched.append(parent)
        }

        // Any change between the probe's `fileExists` and the watcher's
        // `source.resume()` is invisible to the freshly-installed source, so
        // re-check now that it is live.
        for parent in newlyWatched {
            await refreshPaths(in: parent)
        }
    }

    /// Releases a file descriptor on a detached utility-priority task.
    ///
    /// `close()` can block briefly on a network mount even for an `O_EVTONLY`
    /// descriptor, so every `close` call site hops off the main actor.
    private static func closeOffMain(_ fd: Int32) {
        Task.detached(priority: .utility) {
            close(fd)
        }
    }

    /// Default `probe`: runs the blocking syscalls on a detached utility-priority
    /// task so a stale network mount cannot freeze the main actor.
    nonisolated private static let defaultProbe: Probe = { added, bookmarks, newParents in
        await Task.detached(priority: .utility) { [added, bookmarks, newParents] in
            ProbeResult(
                existence: Dictionary(
                    uniqueKeysWithValues: added.map {
                        ($0, SecurityScopedBookmark.fileExists(atPath: $0, bookmark: bookmarks[$0]))
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

    /// Bookmarks for the subset of `paths` that have one.
    private func bookmarks(for paths: Set<String>) -> [String: Data] {
        paths.reduce(into: [:]) { partial, path in
            partial[path] = bookmarkByPath[path]
        }
    }

    /// Tear-down for a single path.
    private func detach(path: String) {
        existsByPath.removeValue(forKey: path)
        bookmarkByPath.removeValue(forKey: path)
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
    /// utility-priority task — `open()` on a stale network mount can block, and
    /// never on the main actor — then re-checks invariants before installing.
    private func startWatching(parent: String) async {
        let (fd, openErrno) = await Task.detached(priority: .utility) {
            let result = open(parent, O_EVTONLY)
            return (result, errno)
        }.value

        guard fd >= 0 else {
            // Parent unreachable (e.g. unmounted volume, or a sandbox denial on an
            // out-of-container parent). Tracked existence stays as probed; the
            // next `revalidate()` retries.
            Self.logger.debug(
                "Could not open parent for monitoring (errno=\(openErrno, privacy: .public)): \(parent, privacy: .public)"
            )
            return
        }
        // Recheck after the await: the parent could have been dropped, or a
        // concurrent caller could have installed a watcher already.
        guard pathsByParent[parent] != nil, parentSources[parent] == nil else {
            Self.closeOffMain(fd)
            return
        }
        installWatcher(fd: fd, parent: parent)
    }

    /// No-syscall step: wires an already-open `O_EVTONLY` fd into a
    /// `DispatchSource` registered against the main queue.
    ///
    /// Callers must verify `parentSources[parent] == nil` first; an existing
    /// source is cancelled here (closing its fd) rather than silently leaked,
    /// and traps in debug builds.
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
            // `setCancelHandler` runs on the source's main queue; detach so the
            // close can't stall the UI if the mount is slow to respond.
            Task.detached(priority: .utility) {
                close(fd)
            }
        }
        source.resume()
        parentSources[parent] = source

        Self.logger.debug("Started attachment watcher on \(parent, privacy: .public)")
    }

    /// Parent directory of `path` as a string.
    private static func parent(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Result of one off-main probe batch.
    struct ProbeResult: Sendable {
        /// Existence flag for each path passed in `paths`.
        let existence: [String: Bool]
        /// Open `O_EVTONLY` fd for each parent in `parents` that was reachable.
        ///
        /// The caller takes ownership and must close any fd no watcher adopts.
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
    /// The `fileExists` syscalls run on a detached utility-priority task so an
    /// unmount in flight cannot stall the main actor; `pathsByParent` is re-read
    /// afterwards to drop any path un-requested mid-await.
    private func refreshPaths(in parent: String) async {
        guard let snapshot = pathsByParent[parent] else { return }
        let bookmarkSnapshot = bookmarks(for: snapshot)

        let existence = await Task.detached(priority: .utility) { [snapshot, bookmarkSnapshot] in
            Dictionary(
                uniqueKeysWithValues: snapshot.map {
                    ($0, SecurityScopedBookmark.fileExists(atPath: $0, bookmark: bookmarkSnapshot[$0]))
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

    /// Re-probes every tracked path and retries a watcher for each parent still
    /// unwatched.
    ///
    /// The re-probe entry point: `setPaths(_:)` only diffs, so a path it already
    /// answered for keeps that answer until this runs. Fired here on app
    /// activation and on volume mount/unmount, and called by the settings shell
    /// when its pane comes back.
    ///
    /// Coalesced: a pass already running only re-arms, so a burst of callers
    /// costs one extra sweep at most. Returns as soon as the sweep is scheduled.
    func revalidate() {
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

    /// Retries parents that couldn't be opened earlier and re-checks every
    /// tracked path.
    ///
    /// Snapshots `pathsByParent.keys` up front so a `setPaths` landing during the
    /// awaits can't dereference a missing entry.
    private func runRefreshAllPass() async {
        let parents = Array(pathsByParent.keys)
        for parent in parents where pathsByParent[parent] != nil {
            if parentSources[parent] == nil {
                await startWatching(parent: parent)
            }
            // Re-check after the await: `startWatching` hops through a detached
            // task, during which the parent's last tracked path may be dropped.
            guard pathsByParent[parent] != nil else { continue }
            await refreshPaths(in: parent)
        }
    }

    #if DEBUG
    /// Snapshot of currently-watched parent directories.
    var watchedParentsForTesting: Set<String> {
        Set(parentSources.keys)
    }
    #endif
}
