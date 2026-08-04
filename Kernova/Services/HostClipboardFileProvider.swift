import Foundation
import KernovaKit
import Observation
import os

/// The app-level host File Provider coordinator surface `VsockClipboardService`
/// depends on.
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

    /// Pre-connects the servicing relay at Copy-to-Mac click so a later
    /// paste-time publish doesn't pay extension-launch latency inside the paste.
    func prepareForCopy()

    /// Publishes an offer's plain-file reps (and directory reps as placeholder
    /// trees) as dataless placeholders at paste time, returning each rep's domain
    /// URL keyed by rep index.
    ///
    /// Returns `nil` when the File Provider isn't usable, so the caller falls
    /// back to the size-capped synchronous pull. `sourceName` is the publishing
    /// VM's name, shown in the progress readout; the shared domain is pointed at
    /// `progressTracker` for the duration of this offer.
    func publishItemsForPaste(
        source: any HostClipboardFileRepProviding, generation: UInt64, sourceName: String,
        progressTracker: ClipboardProgressTracker?, items: [FileProviderPublishItem],
        folders: [FileProviderPublishFolder]
    ) -> [Int: URL]?

    /// Clears the current offer, but only if `source` published it.
    func clearOffer(from source: any HostClipboardFileRepProviding)

    /// A service's progress readout changed, so app-level surfaces can render the
    /// most significant one across every live VM.
    func progressChanged(
        from source: any HostClipboardFileRepProviding, _ snapshot: ClipboardProgressSnapshot?)
}

extension HostClipboardDomainCoordinating {
    func progressChanged(
        from source: any HostClipboardFileRepProviding, _ snapshot: ClipboardProgressSnapshot?
    ) {}
}

/// App-level coordinator owning the single host "Copy to Mac" File Provider
/// domain.
///
/// Clipboard services are per-VM, but the Mac has one global pasteboard and one
/// File Provider manifest, so the domain is an app-level singleton — the last
/// "Copy to Mac" wins, and a per-service host would race the single relay
/// provider when an earlier VM re-published. Byte pulls relay through here
/// because the sandboxed extension can't open vsock; no bytes cross XPC.
@MainActor
@Observable
final class HostClipboardFileProvider: HostClipboardDomainCoordinating {
    /// The process-wide coordinator.
    static let shared = HostClipboardFileProvider()

    private let router = HostClipboardPullRouter()

    /// The host File Provider domain host, inert until `setEnabled(true)` so
    /// merely constructing it registers no system state.
    @ObservationIgnored
    private let domainHost: FileProviderDomainHost

    /// Number of live clipboard services that have called `serviceDidStart`.
    @ObservationIgnored
    private var activeServiceCount = 0

    /// `true` when running inside the unit-test host.
    ///
    /// RATIONALE: standing up the domain registers real system state — a File
    /// Provider domain visible in Finder — and `VsockClipboardServiceTests`
    /// constructs the service against the default `.shared` coordinator and calls
    /// `start()`, so without this guard every clipboard test would register a
    /// domain on the developer's machine. The pull bridge (`pullStagedFile`) is
    /// unaffected and stays directly testable.
    private static let isRunningUnderTests = ProcessInfo.processInfo.isRunningXCTests

    /// Current File Provider usability, mirrored from the domain host.
    ///
    /// Observe it for live updates: every transition is pushed through, so a user
    /// enabling or disabling the File-Providers toggle in System Settings while
    /// the clipboard window is open is reflected without a restart.
    private(set) var availability: FileProviderAvailability = .inactive

    /// The clipboard operation currently worth showing across every live VM, or
    /// `nil` when none is.
    ///
    /// Each VM's service aggregates its own transfers into one snapshot, and this
    /// picks the most significant of them, so a consumer never has to reason about
    /// individual pulls or about which VM they belong to.
    private(set) var materializationProgress: ClipboardProgressSnapshot?

    /// The latest snapshot from each live service, keyed by its identity.
    ///
    /// Per service rather than a single slot, because two VMs can transfer at once
    /// and the readout must not flicker between them; entries are dropped in
    /// `serviceDidStop` so a stopped VM can't pin the ring.
    @ObservationIgnored
    private var progressBySource: [ObjectIdentifier: ClipboardProgressSnapshot] = [:]

    private init() {
        let host = FileProviderDomainHost(config: .host(), pullProvider: router)
        domainHost = host
        host.setAvailabilityObserver { [weak self] availability in
            self?.availability = availability
        }
    }

    func serviceDidStart() {
        guard !Self.isRunningUnderTests else { return }
        activeServiceCount += 1
        guard activeServiceCount == 1 else { return }
        domainHost.setEnabled(true)
    }

    func serviceDidStop(_ source: any HostClipboardFileRepProviding) {
        router.clearSource(ifCurrently: source)
        // Ahead of the test guard and unconditional: a stopped VM's last snapshot
        // would otherwise pin the status-item ring forever.
        progressChanged(from: source, nil)
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
    /// Nothing exists in the domain until a paste, and the consumer resolves the
    /// URLs immediately, so this waits for the placeholder dirents.
    func publishItemsForPaste(
        source: any HostClipboardFileRepProviding, generation: UInt64, sourceName: String,
        progressTracker: ClipboardProgressTracker?, items: [FileProviderPublishItem],
        folders: [FileProviderPublishFolder]
    ) -> [Int: URL]? {
        router.setSource(source)
        // Pulls already in flight for an earlier VM keep reporting to the tracker
        // they started under — the relay captures it at entry — so a superseded
        // paste finishes on screen instead of vanishing.
        domainHost.setProgressTracker(progressTracker)
        return domainHost.publishItems(
            generation: generation, sourceName: sourceName, items: items, folders: folders,
            waitForPlaceholder: true)
    }

    /// Records a service's latest readout and republishes the most significant one
    /// across every live VM.
    func progressChanged(
        from source: any HostClipboardFileRepProviding, _ snapshot: ClipboardProgressSnapshot?
    ) {
        let key = ObjectIdentifier(source)
        if let snapshot {
            progressBySource[key] = snapshot
        } else {
            progressBySource.removeValue(forKey: key)
        }
        materializationProgress = Self.mostSignificant(of: progressBySource)
    }

    /// The snapshot with the most bytes left to move, or `nil` when none is live.
    ///
    /// Ties break on the source's identity — arbitrary, but *stable*, which
    /// dictionary iteration order is not: two VMs whose readouts are level would
    /// otherwise swap the status item's headline between them.
    private static func mostSignificant(
        of snapshots: [ObjectIdentifier: ClipboardProgressSnapshot]
    ) -> ClipboardProgressSnapshot? {
        func remaining(_ snapshot: ClipboardProgressSnapshot) -> UInt64 {
            snapshot.totalBytes - min(snapshot.bytesTransferred, snapshot.totalBytes)
        }
        return snapshots.max { lhs, rhs in
            let lhsRemaining = remaining(lhs.value)
            let rhsRemaining = remaining(rhs.value)
            if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
            return lhs.key < rhs.key
        }?.value
    }

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
/// off-main on the XPC queue, while the coordinator sets/clears the source on
/// the main actor.
final class HostClipboardPullRouter: FileProviderPullProvider, @unchecked Sendable {
    /// Addresses one in-flight pull as `(generation, repIndex)`, since two reps
    /// of the *same* generation can legitimately be in flight at once — keying
    /// on `generation` alone would let one rep's completion evict the dispatch
    /// record for a sibling rep still in flight.
    private struct PullKey: Hashable {
        let generation: UInt64
        let repIndex: Int
    }

    private let lock = NSLock()
    private weak var source: (any HostClipboardFileRepProviding)?
    /// The service each in-flight `(generation, repIndex)` was dispatched to, so a
    /// cancel reaches the VM that owns the pull rather than whichever VM happens
    /// to be `source` *now*.
    ///
    /// Another VM's publish can reassign `source` mid-pull, and the two VMs'
    /// `(generation, repIndex)` numbering collides trivially — both are small
    /// per-VM counters starting at 1 — so a cancel forwarded to the new `source`
    /// either no-ops or aborts that VM's unrelated live transfer.
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
        // Fall back to whichever service is current for a cancel that arrives
        // before (or without ever) being recorded.
        let key = PullKey(generation: generation, repIndex: repIndex)
        let source = lock.withLock { dispatchedSources[key] ?? self.source }
        source?.cancelStagedPull(generation: generation, repIndex: repIndex)
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
    /// relay's XPC queue). `onProgress` is fed the receiver's cumulative
    /// `(bytesTransferred, totalBytes)` per chunk, off-main on the transfer's
    /// queue.
    func pullStagedFile(
        generation: UInt64, repIndex: Int,
        onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
    ) -> Result<String, FileProviderPullError>

    /// Aborts an in-flight `pullStagedFile` for `(generation, repIndex)`, stopping
    /// the vsock transfer and waking the blocked pull.
    ///
    /// Best-effort and idempotent — a cancel for an unknown or already-finished
    /// transfer is a no-op. Called off-main on the File Provider relay's XPC queue.
    func cancelStagedPull(generation: UInt64, repIndex: Int)

    /// Resolves the pasteboard `.fileURL` for a promised rep at paste time, or
    /// `nil` when nothing can be served.
    ///
    /// Serves the materialization cache when the rep was already pulled, else
    /// runs a deadline-bound blocking pull gated all-or-nothing by the offer's
    /// paste-bound byte total. Safe to call on the main thread even though it
    /// blocks.
    func copyToMacFileURL(generation: UInt64, repIndex: Int) -> URL?

    /// Resolves an inline pasteboard flavor's bytes for a promised rep at paste
    /// time, or `nil` when nothing can be served.
    ///
    /// Serves the materialization cache when the rep was already pulled (a
    /// preview, or the item's sibling flavor), else runs a blocking pull. Safe to
    /// call on the main thread even though it blocks.
    func copyToMacData(generation: UInt64, repIndex: Int, uti: String) -> Data?
}
