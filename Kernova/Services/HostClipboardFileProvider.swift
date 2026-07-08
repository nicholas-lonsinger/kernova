import Foundation
import KernovaKit
import Observation
import os

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
final class HostClipboardFileProvider {
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

    /// Publishes a single file rep from `source` as the current File Provider offer.
    ///
    /// Returns the placeholder's pasteboard URL, or `nil` when the File Provider
    /// isn't usable (no transport attached / toggle off / not ready) so the
    /// caller falls back to the size-capped synchronous paste.
    func publishSingleFile(
        source: any HostClipboardFileRepProviding,
        generation: UInt64, repIndex: Int, filename: String, byteCount: UInt64, uti: String
    ) -> URL? {
        router.setSource(source)
        return domainHost.publishSingleFile(
            generation: generation, repIndex: repIndex, filename: filename,
            byteCount: byteCount, uti: uti)
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
/// `@unchecked Sendable`: `source` is read and written only under `lock` — the
/// relay calls `fetchStagedFile` off-main on the broker's XPC queue, while the
/// coordinator sets/clears the source on the main actor.
final class HostClipboardPullRouter: FileProviderPullProvider, @unchecked Sendable {
    private let lock = NSLock()
    private weak var source: (any HostClipboardFileRepProviding)?

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
        generation: UInt64, repIndex: Int
    ) -> Result<String, FileProviderPullError> {
        let source = lock.withLock { self.source }
        guard let source else { return .failure(.noCurrentOffer) }
        return source.pullStagedFile(generation: generation, repIndex: repIndex)
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
    func pullStagedFile(
        generation: UInt64, repIndex: Int
    ) -> Result<String, FileProviderPullError>
}
