import Foundation
import KernovaKit
import Observation
import ServiceManagement
import os

/// App-level coordinator that owns the single host "Copy to Mac" File Provider
/// domain (issue #424).
///
/// Clipboard services are per-VM (`VMInstance` creates one per live macOS guest),
/// but the Mac has ONE global pasteboard and ONE File Provider manifest (the
/// `.host` app-group container), so the domain is owned here as an app-level
/// singleton rather than per service — the last "Copy to Mac" wins, exactly like
/// `NSPasteboard.general`. A per-service domain host would race the single broker
/// provider when an earlier VM re-published.
///
/// The sandboxed File Provider extension can't open vsock, so a byte pull is
/// relayed — extension → launchd broker → here → the publishing service — via the
/// `BrokerRelayTransport` (the main app can't vend a Mach service itself; the
/// Phase-0 spike proved launchd refuses it). No bytes cross XPC; only
/// `(generation, repIndex)` and a staged app-group path do.
@MainActor
@Observable
final class HostClipboardFileProvider {
    /// The process-wide coordinator.
    static let shared = HostClipboardFileProvider()

    private static let logger = Logger(
        subsystem: "app.kernova", category: "HostClipboardFileProvider")

    private let router = HostClipboardPullRouter()
    private let domainHost: ClipboardFileProviderDomainHost

    /// Number of live clipboard services that have called `serviceDidStart`.
    ///
    /// The domain stands up on 0→1 and tears down on 1→0, so the broker
    /// LaunchAgent and File Provider domain exist only while at least one VM has
    /// clipboard sharing on — never in the CI test host, which starts no service.
    @ObservationIgnored
    private var activeServiceCount = 0

    /// `true` once the broker LaunchAgent has been registered this launch.
    @ObservationIgnored
    private var brokerRegistered = false

    /// `true` when running inside the unit-test host.
    ///
    /// RATIONALE: standing up the domain registers real system state — a File
    /// Provider domain (a Finder location) and an `SMAppService` LaunchAgent (a
    /// login item). In production the service is created only when a VM enables
    /// clipboard sharing, but the unit-test host instantiates `VsockClipboardService`
    /// directly (so `serviceDidStart` runs ~40 times), which would pollute the dev
    /// machine. Gate the side-effectful activation out of test runs — mirroring how
    /// the guest agent wires its File Provider host from the production app
    /// delegate, never from the agent's `start()`. The pull bridge itself
    /// (`pullStagedFile`) is unaffected and stays directly testable.
    private static let isRunningUnderTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Current File Provider usability, mirrored from the domain host's polled
    /// availability for the clipboard window's enablement UI.
    ///
    /// Observe it for live updates: the domain host polls the System-Settings
    /// toggle and pushes every transition through `setAvailabilityObserver`, so a
    /// user enabling (or disabling) the File-Providers toggle while the window is
    /// open is reflected without a restart.
    private(set) var availability: ClipboardFileProviderAvailability = .inactive

    private init() {
        domainHost = ClipboardFileProviderDomainHost(
            config: .host, pullProvider: router,
            relayTransport: BrokerRelayTransport(
                loggerSubsystem: ClipboardFileProviderConfig.host.loggerSubsystem))
        domainHost.setAvailabilityObserver { [weak self] availability in
            self?.availability = availability
        }
    }

    /// A clipboard service started — stand up the domain on the first one.
    func serviceDidStart() {
        guard !Self.isRunningUnderTests else { return }
        activeServiceCount += 1
        guard activeServiceCount == 1 else { return }
        // Order matters: the broker LaunchAgent must be registered before the
        // domain host's `BrokerRelayTransport` connects out to it on enable.
        registerBrokerIfNeeded()
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
    /// isn't usable (toggle off / not ready) so the caller falls back to the
    /// size-capped synchronous paste.
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

    private func registerBrokerIfNeeded() {
        guard !brokerRegistered else { return }
        let service = SMAppService.agent(
            plistName: ClipboardFileProviderBrokerIdentity.brokerLaunchAgentPlistName)
        do {
            try service.register()
            brokerRegistered = true
            // `register()` returns without throwing even when the background item
            // still needs the user's approval in System Settings → Login Items &
            // Extensions; the broker only demand-launches once it's `.enabled`. Log
            // the real status so a placeholder paste that can't reach the broker
            // (File-Providers toggle on, but the Login Item not allowed) is
            // diagnosable rather than a silent serverUnreachable.
            if service.status == .enabled {
                Self.logger.notice("Clipboard relay broker LaunchAgent registered and enabled")
            } else {
                Self.logger.warning(
                    "Clipboard relay broker registered but not enabled (status=\(String(describing: service.status), privacy: .public)) — large-file paste needs it allowed in Login Items & Extensions"
                )
            }
        } catch {
            // Leave `brokerRegistered` false so the next service start retries.
            // The domain still stands up and the toggle-off synchronous paste
            // fallback keeps working without the broker.
            Self.logger.error(
                "Failed to register clipboard relay broker: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Routes the File Provider relay's byte pulls to the clipboard service that
/// published the current offer.
///
/// `@unchecked Sendable`: `source` is read and written only under `lock` — the
/// relay calls `fetchStagedFile` off-main on the broker's XPC queue, while the
/// coordinator sets/clears the source on the main actor.
final class HostClipboardPullRouter: ClipboardFileProviderPullProvider, @unchecked Sendable {
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
    ) -> Result<String, ClipboardFileProviderPullError> {
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
    ) -> Result<String, ClipboardFileProviderPullError>
}
