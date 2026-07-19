import Foundation
import KernovaKit
import Observation
import os

/// The app-level host File Provider coordinator surface `VsockClipboardService`
/// depends on.
///
/// Injected into the service (defaulting to `HostClipboardFileProvider.shared`)
/// so tests can drive paste-time routing and the copy-click advisory without a
/// live File Provider domain — the host analog of the guest agent's injectable
/// `FileProviderPublishing` seam.
@MainActor
protocol HostClipboardDomainCoordinating: AnyObject {
    /// Current File Provider usability, for the Copy-to-Mac advisory check.
    var availability: FileProviderAvailability { get }

    /// A clipboard service started — ref-count the shared domain up (0→1 stands
    /// it up).
    func serviceDidStart()

    /// A clipboard service stopped — ref-count the shared domain down (1→0 tears
    /// it down), also releasing `source` as the relay pull source.
    func serviceDidStop(_ source: any HostClipboardFileRepProviding)

    /// Cheap warm-up at Copy-to-Mac click: pre-connects the servicing relay so a
    /// later paste-time publish doesn't also pay doorbell/extension-launch
    /// latency inside the paste (host mirror of the guest's `prepareForOffer`).
    func prepareForCopy()

    /// Paste-time publish of an offer's eligible plain-file reps (and directory
    /// reps as placeholder trees, folder D1b) as dataless placeholders, setting
    /// the relay pull source to `source` and waiting for the placeholders. Returns
    /// each rep's domain URL keyed by rep index, or `nil` when the File Provider
    /// isn't usable so the caller falls back to the size-capped synchronous pull.
    func publishItemsForPaste(
        source: any HostClipboardFileRepProviding, generation: UInt64,
        items: [FileProviderPublishItem], folders: [FileProviderPublishFolder]
    ) -> [Int: URL]?

    /// Clears the current offer, but only if `source` published it.
    func clearOffer(from source: any HostClipboardFileRepProviding)
}

/// App-level coordinator that owns the single host "Copy to Mac" File Provider
/// domain (issue #424 / #460 servicing migration).
///
/// Clipboard services are per-VM (`VMInstance` creates one per live macOS guest),
/// but the Mac has ONE global pasteboard and ONE File Provider manifest (the
/// `.host` app-group container), so the domain is owned here as an app-level
/// singleton rather than per service — the last "Copy to Mac" wins, exactly like
/// `NSPasteboard.general`. A per-service domain host would race the single relay
/// provider when an earlier VM re-published.
///
/// The sandboxed File Provider extension can't open vsock, so a byte pull is
/// relayed — extension → the domain host's `NSFileProviderServicing` connection →
/// here → the publishing service (#460). The domain host builds its default
/// servicing connector from `.host`; no separate broker or Mach service is
/// involved. No bytes cross XPC; only `(generation, repIndex)` and a staged
/// app-group path do.
@MainActor
@Observable
final class HostClipboardFileProvider: HostClipboardDomainCoordinating {
    /// The process-wide coordinator.
    static let shared = HostClipboardFileProvider()

    private let router = HostClipboardPullRouter()

    /// The host File Provider domain host, built in `init` with its default
    /// servicing connector.
    ///
    /// Inert until `setEnabled(true)` (the first clipboard service starting), so
    /// constructing it here registers no system state — notably never in the
    /// unit-test host, where `serviceDidStart`/`serviceDidStop` short-circuit on
    /// `isRunningUnderTests` before enabling it.
    @ObservationIgnored
    private let domainHost: FileProviderDomainHost

    /// Number of live clipboard services that have called `serviceDidStart`.
    ///
    /// The domain stands up on 0→1 and tears down on 1→0, so the File Provider
    /// domain exists only while at least one VM has clipboard sharing on — never
    /// in the CI test host, which starts no service.
    @ObservationIgnored
    private var activeServiceCount = 0

    /// `true` when running inside the unit-test host.
    ///
    /// RATIONALE: standing up the domain registers real system state — a File
    /// Provider domain (a Finder location). In production the service is created
    /// only when a VM enables clipboard sharing, but the unit-test host
    /// instantiates `VsockClipboardService` directly (so `serviceDidStart` runs
    /// ~40 times), which would pollute the dev machine. Gate the side-effectful
    /// activation out of test runs — mirroring how the guest agent wires its File
    /// Provider host from the production app delegate, never from the agent's
    /// `start()`. The pull bridge itself (`pullStagedFile`) is unaffected and
    /// stays directly testable. (The `domainHost` object exists here even in the
    /// test host, but it is inert until `setEnabled(true)`, which this guard
    /// prevents — so no File Provider domain is ever registered under test.)
    private static let isRunningUnderTests = ProcessInfo.processInfo.isRunningXCTests

    /// Current File Provider usability, mirrored from the domain host's
    /// availability for the clipboard window's enablement UI.
    ///
    /// Observe it for live updates: the domain host is event-driven — an
    /// `NSFileProviderDomainDidChange` observer reacts to the System-Settings
    /// toggle instantly, with a usage-triggered refresh in `publishSingleFile`
    /// as a backstop — and pushes every transition through
    /// `setAvailabilityObserver`, so a user enabling (or disabling) the
    /// File-Providers toggle while the window is open is reflected without a
    /// restart.
    private(set) var availability: FileProviderAvailability = .inactive

    private init() {
        let host = FileProviderDomainHost(config: .host(), pullProvider: router)
        domainHost = host
        host.setAvailabilityObserver { [weak self] availability in
            self?.availability = availability
        }
    }

    /// A clipboard service started — stand up the domain on the first one.
    func serviceDidStart() {
        guard !Self.isRunningUnderTests else { return }
        activeServiceCount += 1
        guard activeServiceCount == 1 else { return }
        domainHost.setEnabled(true)
    }

    /// A clipboard service stopped — tear the domain down when the last one goes.
    func serviceDidStop(_ source: any HostClipboardFileRepProviding) {
        router.clearSource(ifCurrently: source)
        guard !Self.isRunningUnderTests else { return }
        activeServiceCount = max(0, activeServiceCount - 1)
        guard activeServiceCount == 0 else { return }
        domainHost.setEnabled(false)
    }

    func prepareForCopy() {
        domainHost.prepareForOffer()
    }

    /// Publishes `items` from `source` as the current File Provider offer at paste
    /// time and returns each item's placeholder URL keyed by rep index.
    ///
    /// Returns `nil` when the File Provider isn't usable (no transport attached /
    /// toggle off / not ready) so the caller falls back to the size-capped
    /// synchronous paste. The consumer resolves the URLs immediately, so it waits
    /// for the placeholder dirents (`waitForPlaceholder: true`) — the #427 host
    /// mirror: nothing exists in the domain until a paste.
    func publishItemsForPaste(
        source: any HostClipboardFileRepProviding,
        generation: UInt64, items: [FileProviderPublishItem], folders: [FileProviderPublishFolder]
    ) -> [Int: URL]? {
        router.setSource(source)
        return domainHost.publishItems(
            generation: generation, items: items, folders: folders, waitForPlaceholder: true)
    }

    /// Clears the current offer, but only if `source` is the one that published
    /// it — so a stopping service doesn't wipe a newer service's live offer.
    func clearOffer(from source: any HostClipboardFileRepProviding) {
        guard router.isCurrent(source) else { return }
        domainHost.clearOffer()
    }
}

/// Routes the File Provider relay's byte pulls to the clipboard service that
/// published the current offer.
///
/// `@unchecked Sendable`: `source`/`dispatchedSources` are read and written
/// only under `lock` — the relay calls `fetchStagedFile`/`cancelStagedPull`
/// off-main on the broker's XPC queue, while the coordinator sets/clears the
/// source on the main actor.
final class HostClipboardPullRouter: FileProviderPullProvider, @unchecked Sendable {
    /// Addresses one in-flight pull the same way a wire `transferID` does —
    /// `(generation, repIndex)` — since two reps of the *same* generation can
    /// legitimately be in flight at once (the relay dispatches pulls onto its
    /// own concurrent queue precisely so independent multi-file pulls can
    /// overlap), and keying on `generation` alone would let one rep's
    /// completion evict the dispatch record for a sibling rep still in flight.
    private struct PullKey: Hashable {
        let generation: UInt64
        let repIndex: Int
    }

    private let lock = NSLock()
    private weak var source: (any HostClipboardFileRepProviding)?
    /// The service each in-flight `(generation, repIndex)` was dispatched to,
    /// so a cancel reaches the VM that actually owns the pull rather than
    /// whichever VM happens to be `source` *now* (#464).
    ///
    /// `HostClipboardFileProvider` is a single app-wide singleton router shared
    /// across every VM ("the last Copy to Mac wins" — see its doc), and a slow
    /// pull can run for a long time (that's the whole reason #464 exists), so
    /// another VM's publish can freely reassign `source` while an earlier VM's
    /// pull is still in flight. Without this, `cancelStagedPull` would forward
    /// to the new `source` — a VM that never received the `fetchFile` this
    /// cancel is for, and whose `(generation, repIndex)` numbering can
    /// trivially collide with the original VM's (both are small per-VM
    /// counters starting at 1), so the misrouted cancel is either a silent
    /// no-op (the real transfer keeps streaming, wasting vsock bandwidth — the
    /// exact regression #464 fixes) or an incorrect abort of the new VM's own
    /// unrelated live transfer. Entries are removed once their dispatched fetch
    /// returns, so this never grows past the number of genuinely in-flight
    /// pulls.
    private var dispatchedSources: [PullKey: any HostClipboardFileRepProviding] = [:]

    func setSource(_ source: any HostClipboardFileRepProviding) {
        lock.withLock { self.source = source }
    }

    func clearSource(ifCurrently source: any HostClipboardFileRepProviding) {
        lock.withLock { if self.source === source { self.source = nil } }
    }

    func isCurrent(_ source: any HostClipboardFileRepProviding) -> Bool {
        lock.withLock { self.source === source }
    }

    func fetchStagedFile(
        generation: UInt64, repIndex: Int,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }
    ) -> Result<String, FileProviderPullError> {
        let key = PullKey(generation: generation, repIndex: repIndex)
        let source: (any HostClipboardFileRepProviding)? = lock.withLock {
            guard let current = self.source else { return nil }
            dispatchedSources[key] = current
            return current
        }
        guard let source else { return .failure(.noCurrentOffer) }
        defer { lock.withLock { dispatchedSources[key] = nil } }
        return source.pullStagedFile(
            generation: generation, repIndex: repIndex, onProgress: onProgress)
    }

    func cancelStagedPull(generation: UInt64, repIndex: Int) {
        // Prefer the service this (generation, repIndex) was actually
        // dispatched to; fall back to whichever is current for a cancel that
        // arrives before (or without ever) being recorded — matching
        // `fetchStagedFile`'s own fallback behavior for an unknown/stale pull.
        let key = PullKey(generation: generation, repIndex: repIndex)
        let source = lock.withLock { dispatchedSources[key] ?? self.source }
        source?.cancelStagedPull(generation: generation, repIndex: repIndex)
    }

    func fetchStagedChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }
    ) -> Result<String, FileProviderPullError> {
        // Route the same way `fetchStagedFile` does — a folder's children are
        // pulled from the service that published the offer. `PullKey` keys on
        // (generation, repIndex), which is enough: only one directory rep per
        // (generation, repIndex) exists, and its children serialize through the
        // same publishing service.
        let key = PullKey(generation: generation, repIndex: repIndex)
        let source: (any HostClipboardFileRepProviding)? = lock.withLock {
            guard let current = self.source else { return nil }
            dispatchedSources[key] = current
            return current
        }
        guard let source else { return .failure(.noCurrentOffer) }
        defer { lock.withLock { dispatchedSources[key] = nil } }
        return source.pullStagedChild(
            generation: generation, repIndex: repIndex, childSeq: childSeq,
            relativePath: relativePath, onProgress: onProgress)
    }

    func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32) {
        let key = PullKey(generation: generation, repIndex: repIndex)
        let source = lock.withLock { dispatchedSources[key] ?? self.source }
        source?.cancelStagedChildPull(
            generation: generation, repIndex: repIndex, childSeq: childSeq)
    }
}

/// Implemented by a clipboard service so the host File Provider coordinator — and
/// the toggle-off synchronous paste fallback — can pull a file rep's bytes on
/// demand.
protocol HostClipboardFileRepProviding: AnyObject, Sendable {
    /// Pulls `(generation, repIndex)` over the transport, stages it into the host
    /// app-group container, and returns the staged file path (or why it failed).
    ///
    /// Synchronous and blocking; safe to call on the main thread (the toggle-off
    /// `NSPasteboardItemDataProvider` callback) or off-main (the File Provider
    /// relay's XPC queue) — the implementation snapshots per the calling thread
    /// and is woken off-main by the stream receiver.
    ///
    /// `onProgress` is fed the receiver's cumulative `(bytesTransferred,
    /// totalBytes)` per chunk, so the relay can drive the extension's determinate
    /// download bar (#426). Fires off-main on the transfer's queue.
    func pullStagedFile(
        generation: UInt64, repIndex: Int,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) -> Result<String, FileProviderPullError>

    /// Aborts an in-flight `pullStagedFile` for `(generation, repIndex)` (#464):
    /// stops the vsock transfer and wakes the blocked pull. Best-effort and
    /// idempotent — a cancel for an unknown or already-finished transfer is a
    /// no-op. Called off-main on the File Provider relay's XPC queue.
    func cancelStagedPull(generation: UInt64, repIndex: Int)

    /// Pulls one child file `(generation, repIndex, childSeq)` at `relativePath`
    /// within a directory rep's placeholder tree (folder D1b), stages it, and
    /// returns the staged path. Same off-main, no-deadline contract as
    /// `pullStagedFile`.
    func pullStagedChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) -> Result<String, FileProviderPullError>

    /// Aborts an in-flight `pullStagedChild` for `(generation, repIndex,
    /// childSeq)`. Best-effort and idempotent.
    func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32)

    /// Resolves the pasteboard `.fileURL` for a lazy plain-file rep at paste time.
    ///
    /// The host mirror of the guest's paste-time routing: it tries the File
    /// Provider first (publishing every eligible plain-file rep of the offer
    /// together on the first fire, latching on success so a sibling fire reads
    /// the latch and a failed publish retries on the next paste), returning the
    /// dataless placeholder's domain URL. When the File Provider is unusable it
    /// falls back to a deadline-bound synchronous pull, gated by the offer's
    /// total sync-bound byte count (all-or-nothing over the cap). Returns the
    /// URL to place on the pasteboard, or `nil` when nothing can be served.
    ///
    /// Synchronous and blocking on the sync-fallback path; safe to call on the
    /// main thread (the pasteboard server's `provideData` callback) or off-main.
    func copyToMacFileURL(generation: UInt64, repIndex: Int) -> URL?
}
