import FileProvider
import Foundation

// Shared clipboard File Provider domain host (issues #376 guest / #424 host).
//
// Owns the container-app side of the File Provider transport, parameterized by
// a `ClipboardFileProviderConfig` so the guest agent (host→guest paste) and the
// main app (guest→host "Copy to Mac") share one implementation:
//  1. The XPC relay the sandboxed extension calls on `fetchContents` — the
//     extension can't open vsock, so the owning process (which does) pulls for
//     it.
//  2. Registration of the clipboard File Provider domain so the system
//     instantiates the extension and surfaces the domain in Finder.
//  3. The offer manifest + `signalEnumerator` that declare the current file rep
//     to the system as a dataless placeholder.
//
// Gated on clipboard policy: the domain + listener stand up only once clipboard
// sharing is enabled, so the team-prefixed Mach listener never starts in a
// context that didn't enable clipboard (e.g. the CI test host).
//
// NOTE (#424): the guest vends the relay via the `NSXPCListener` here (its
// LaunchAgent registers the Mach name). The main app is neither sandboxed nor
// launchd-managed and cannot register a Mach service (Phase-0 spike proved
// `.resume()` is refused by launchd), so the host wiring (Phase 2b/3) will route
// relay vending through an SMAppService broker instead of this listener. The
// registration/manifest/availability machinery below is direction-agnostic and
// shared as-is.

// MARK: - Collaboration with the clipboard owner

/// Implemented by the clipboard owner so the relay can pull a file rep.
///
/// Called off-main on the relay's XPC queue when the extension's `fetchContents`
/// asks for the bytes.
public protocol ClipboardFileProviderPullProvider: AnyObject, Sendable {
    /// Pulls `(generation, repIndex)` over vsock, stages it into the shared
    /// container, and returns the staged file path (or why it failed).
    func fetchStagedFile(
        generation: UInt64, repIndex: Int
    ) -> Result<String, ClipboardFileProviderPullError>
}

/// Why a relay pull failed, mapped to an `NSFileProviderError` by the relay.
public enum ClipboardFileProviderPullError: Error {
    /// `(generation, repIndex)` isn't the current offer, or there's no live
    /// connection — a stale-placeholder read.
    case noCurrentOffer
    /// The vsock pull aborted, timed out, or the peer went away mid-transfer.
    case pullFailed
}

/// Implemented by the host so the clipboard owner can surface a file rep as a
/// placeholder.
///
/// Lets the clipboard owner publish a single inbound file rep as a dataless
/// placeholder and get its pasteboard URL. Called only on the main queue.
public protocol ClipboardFileProviderPublishing: AnyObject, Sendable {
    /// Publishes a single file item as the current offer and returns the
    /// `file://` URL to advertise on the pasteboard, or `nil` when the File
    /// Provider isn't usable (sharing off, domain not registered, or the user
    /// toggle is off) so the caller falls back to the synchronous provider path.
    func publishSingleFile(
        generation: UInt64, repIndex: Int, filename: String, byteCount: UInt64, uti: String
    ) -> URL?

    /// Clears the current offer's items on supersession/teardown.
    func clearOffer()
}

/// What the owner knows about the File Provider's usability, for the UI.
public enum ClipboardFileProviderAvailability: Equatable, Sendable {
    /// Not probed yet, or clipboard sharing is off.
    case inactive
    /// Domain registered and the user has it enabled — working.
    case ready
    /// Domain registered but the user's System-Settings File-Providers toggle is
    /// off (`userEnabled == false`); large-file paste falls back to the
    /// size-capped synchronous path.
    case needsEnabling
    /// The extension couldn't be found/launched or registration failed — an
    /// install/signing problem, not a user toggle.
    case unavailable
}

// MARK: - Host

/// Hosts the File Provider XPC relay, registers the clipboard domain, and
/// publishes the current offer's single file item — for one direction's config.
///
/// `@unchecked Sendable`: registration/manifest/availability state is touched
/// only on the main queue; `pullProvider`, `config`, `logger`, and `container`
/// are immutable `let`s the XPC listener delegate reads off-main.
public final class ClipboardFileProviderDomainHost: NSObject, ClipboardFileProviderPublishing,
    @unchecked Sendable
{
    private let config: ClipboardFileProviderConfig
    private let logger: KernovaLogger
    private let container: ClipboardFileProviderContainer
    private let pullProvider: ClipboardFileProviderPullProvider
    private let domain: NSFileProviderDomain
    /// Vends the relay to the extension — a Mach listener (guest) or the broker
    /// (host).
    ///
    /// The domain host owns the relay *service*; the transport owns *how* it's
    /// exposed.
    private let relayTransport: ClipboardFileProviderRelayTransport
    private let relayService: ClipboardFileProviderRelayService
    private let notificationCenter: NotificationCenter
    private let fetchDomains: @Sendable () async throws -> [NSFileProviderDomain]

    // MARK: Main-queue state

    private var enabled = false
    private var domainRegistered = false
    /// User-visible domain root, resolved after registration; `nil` until then
    /// (the File Provider path is unused while it's `nil`).
    private var rootURL: URL?
    private var availabilityStorage: ClipboardFileProviderAvailability = .inactive
    /// Token for the `NSFileProviderDomainDidChange` observer.
    ///
    /// The primary availability signal while enabled. Removed on disable and in
    /// deinit (deinit-removal pattern, see Kernova/Services/SystemSleepWatcher.swift).
    private var domainChangeObserver: (any NSObjectProtocol)?
    /// Notified on the main queue on every availability transition.
    ///
    /// Lets an owner mirror availability into observable UI state. Set on main;
    /// invoked on main.
    private var availabilityObserver: (@MainActor (ClipboardFileProviderAvailability) -> Void)?

    /// Current File Provider usability, for the UI.
    ///
    /// Read on main.
    public var availability: ClipboardFileProviderAvailability {
        dispatchPrecondition(condition: .onQueue(.main))
        return availabilityStorage
    }

    /// Registers an observer notified on the main queue whenever `availability`
    /// changes, and immediately delivers the current value.
    ///
    /// The owner mirrors this into observable UI state; the domain-change
    /// observer keeps it live, so a user flipping the System-Settings toggle is
    /// reflected without a restart.
    public func setAvailabilityObserver(
        _ observer: @escaping @MainActor (ClipboardFileProviderAvailability) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        availabilityObserver = observer
        MainActor.assumeIsolated { observer(availabilityStorage) }
    }

    /// Updates the cached availability and notifies the observer on a transition.
    ///
    /// Centralizes the storage write + observer notification + transition log so
    /// every path (registration probe, domain-change notification, usage-trigger,
    /// policy disable) keeps the UI mirror in sync. Runs on main.
    private func setAvailability(_ availability: ClipboardFileProviderAvailability) {
        guard availabilityStorage != availability else { return }
        availabilityStorage = availability
        logger.notice(
            "File Provider availability: \(String(describing: availability), privacy: .public)")
        MainActor.assumeIsolated { availabilityObserver?(availability) }
    }

    /// Creates a domain host for one direction, pulling bytes through
    /// `pullProvider` when the extension reads a placeholder, and vending the
    /// relay through `relayTransport` (Mach listener for the guest, broker for the
    /// host).
    public init(
        config: ClipboardFileProviderConfig,
        pullProvider: ClipboardFileProviderPullProvider,
        relayTransport: ClipboardFileProviderRelayTransport,
        notificationCenter: NotificationCenter = .default,
        fetchDomains: @escaping @Sendable () async throws -> [NSFileProviderDomain] = {
            try await NSFileProviderManager.domains()
        }
    ) {
        self.config = config
        self.logger = KernovaLogger(subsystem: config.loggerSubsystem, category: "FileProviderHost")
        self.container = ClipboardFileProviderContainer(config: config)
        self.pullProvider = pullProvider
        self.relayTransport = relayTransport
        self.relayService = ClipboardFileProviderRelayService(
            pullProvider: pullProvider, loggerSubsystem: config.loggerSubsystem)
        self.domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(config.domainIdentifier),
            displayName: config.domainDisplayName)
        self.notificationCenter = notificationCenter
        self.fetchDomains = fetchDomains
        super.init()
    }

    deinit {
        if let domainChangeObserver {
            notificationCenter.removeObserver(domainChangeObserver)
        }
    }

    // MARK: - Enablement (clipboard policy)

    /// Applies a clipboard-sharing policy update.
    ///
    /// Stands the domain + listener up on enable, tears the domain down on disable.
    public func setEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in self?.applyEnabledOnMain(enabled) }
    }

    private func applyEnabledOnMain(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            // Vend the relay through the injected transport. Deferred to enable so a
            // team-prefixed Mach listener / broker connection never starts in a
            // context that didn't enable clipboard sharing (notably the CI test
            // host). The transport self-guards idempotency and re-vends after an
            // invalidation, so this runs on every enable — no outer latch, which
            // would defeat the transport's documented "re-register on next enable"
            // recovery (#424).
            relayTransport.startServing(relayService)
            registerDomain()
            startObservingDomainChanges()
        } else {
            stopObservingDomainChanges()
            setAvailability(.inactive)
            // Stop routing to the served relay so a stray fetch while disabled fails
            // cleanly (host: serverUnreachable; guest: refused connection) instead of
            // reaching a relay whose offer was just cleared. The listener itself
            // persists — the host multiplexes GUI-summon on it.
            relayTransport.stopServing()
            // Keep the domain registered across a policy off→on cycle: re-adding a
            // domain re-creates it in the consent-gated OFF state, which would wipe
            // the user's System-Settings enablement on every restart. Just clear
            // the offer's items so nothing lingers.
            clearOfferOnMain()
            logger.notice("File Provider disabled by clipboard policy")
        }
    }

    // RATIONALE: `publishSingleFile` is synchronous and decides
    // File-Provider-vs-sync-fallback purely from the cached `availabilityStorage`;
    // it never re-probes (it can't await an async `signalEnumerator`). A prior
    // version kept that cache honest with a 3s repeating poll timer for the whole
    // enabled lifetime. That's replaced by event/usage-driven refreshes instead of
    // indefinite polling: `NSFileProviderDomainDidChange` (below) is the primary
    // detector for a mid-session System-Settings disable — the system posts it on
    // a `userEnabled` flip. `publishSingleFile`'s usage-triggered refresh and the
    // `signalEnumerator` error feedback (see `signalEnumerator()`) are backstops
    // that bound staleness to at most one publish/offer cycle if a notification is
    // ever missed, so a disabled domain is caught by the next paste or offer even
    // without the notification firing.
    private func startObservingDomainChanges() {
        guard domainChangeObserver == nil else { return }
        domainChangeObserver = notificationCenter.addObserver(
            forName: .fileProviderDomainDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.logger.debug("NSFileProviderDomainDidChange received — re-probing availability")
            self.refreshAvailability()
        }
    }

    private func stopObservingDomainChanges() {
        if let domainChangeObserver {
            notificationCenter.removeObserver(domainChangeObserver)
            self.domainChangeObserver = nil
        }
    }

    /// Registers (or idempotently re-registers) the clipboard domain, then
    /// resolves its root URL and probes the user-enablement toggle.
    ///
    /// `add` is idempotent for an existing identifier — it updates the domain and
    /// **preserves the user's enablement**, so a restart never resets the toggle.
    /// Only a genuinely orphaned replication directory makes `add` fail with
    /// `NSFileWriteFileExistsError`; that one case clears + retries once.
    private func registerDomain() {
        addDomain(retryOnExists: true)
    }

    private func addDomain(retryOnExists: Bool) {
        NSFileProviderManager.add(domain) { [weak self] error in
            let nsError = error as NSError?
            let staleReplicationDir =
                nsError?.domain == NSCocoaErrorDomain
                && nsError?.code == NSFileWriteFileExistsError
            let failure = error?.localizedDescription
            DispatchQueue.main.async {
                guard let self else { return }
                if staleReplicationDir, retryOnExists {
                    self.logger.notice(
                        "File Provider replication dir is orphaned; removing domains then retrying add")
                    self.removeAllDomains { _ in
                        DispatchQueue.main.async { self.addDomain(retryOnExists: false) }
                    }
                    return
                }
                if let failure {
                    self.logger.error(
                        "Failed to add File Provider domain: \(failure, privacy: .public)")
                    self.domainRegistered = false
                    self.setAvailability(.unavailable)
                    return
                }
                self.domainRegistered = true
                self.logger.notice(
                    "File Provider domain registered: \(self.domain.identifier.rawValue, privacy: .public)"
                )
                self.resolveRootURL()
                self.refreshAvailability()
            }
        }
    }

    /// Caches the user-visible root URL so an offer can construct `root/filename`
    /// for the pasteboard without a per-item round-trip.
    private func resolveRootURL() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { [weak self] url, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let url {
                    self.rootURL = url
                    self.logger.notice("Clipboard domain visible at: \(url.path, privacy: .public)")
                } else if let error {
                    self.logger.error(
                        "getUserVisibleURL failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Re-checks whether the user has enabled the domain by reading the live
    /// `userEnabled` flag off the system's copy of the domain.
    ///
    /// `NSFileProviderDomain.userEnabled` reflects the macOS System Settings →
    /// Login Items & Extensions → File Providers toggle directly (it goes `false`
    /// the moment the user turns the extension off), which is the authoritative
    /// signal. A `signalEnumerator` probe is unreliable for this: its completion
    /// reports only that the *signal was delivered*, so it returns success even
    /// when the domain is disabled — the `-2011` surfaces later, on an actual
    /// content fetch, too late to gate `publishSingleFile`. The locally-held
    /// `domain` carries a stale flag, so the live copy is fetched via `domains()`.
    ///
    /// Called on registration, on an `NSFileProviderDomainDidChange` notification,
    /// on every `publishSingleFile` usage (self-corrects the cache at the point of
    /// consumption), and on `signalEnumerator` error feedback — so flipping the
    /// toggle in System Settings takes effect without restarting the owner, with
    /// no indefinite polling. Logs every transition for diagnosis.
    private func refreshAvailability() {
        let identifier = domain.identifier
        Task { [weak self, fetchDomains] in
            let availability: ClipboardFileProviderAvailability
            do {
                let domains = try await fetchDomains()
                availability = Self.availability(
                    forDomainMatching: identifier, in: domains, error: nil)
            } catch {
                availability = Self.availability(
                    forDomainMatching: identifier, in: [], error: error)
            }
            DispatchQueue.main.async {
                guard let self, self.enabled else { return }
                self.setAvailability(availability)
            }
        }
    }

    /// Maps the system's domain registry to availability: a matching domain with
    /// `userEnabled == true` is `.ready`, a matching domain with `userEnabled ==
    /// false` is `.needsEnabling` (the System-Settings toggle is off), and a
    /// lookup error or a missing domain is `.unavailable`.
    ///
    /// `internal` (not `private`) so `KernovaKitTests` can lock the mapping.
    static func availability(
        forDomainMatching identifier: NSFileProviderDomainIdentifier,
        in domains: [NSFileProviderDomain],
        error: Error?
    ) -> ClipboardFileProviderAvailability {
        guard error == nil else { return .unavailable }
        guard let domain = domains.first(where: { $0.identifier == identifier }) else {
            return .unavailable
        }
        return availability(userEnabled: domain.userEnabled)
    }

    /// Maps a domain's `userEnabled` flag to availability: `true` is `.ready`,
    /// `false` is `.needsEnabling` (the user's System-Settings toggle is off).
    ///
    /// Split out so `KernovaKitTests` can lock the toggle mapping without a live
    /// `NSFileProviderDomain` (whose `userEnabled` is read-only).
    static func availability(userEnabled: Bool) -> ClipboardFileProviderAvailability {
        userEnabled ? .ready : .needsEnabling
    }

    // MARK: - ClipboardFileProviderPublishing

    /// Publishes a single file rep as the current offer's placeholder and returns
    /// its domain URL, or `nil` to fall back to the synchronous provider path.
    public func publishSingleFile(
        generation: UInt64, repIndex: Int, filename: String, byteCount: UInt64, uti: String
    ) -> URL? {
        dispatchPrecondition(condition: .onQueue(.main))
        // Only advertise a placeholder we can actually materialize: a disabled or
        // not-yet-ready domain would leave a paste that never completes, so fall
        // back to the synchronous provider path in those cases.
        guard enabled, domainRegistered, let rootURL else {
            logger.debug(
                "FP publish skipped (enabled=\(self.enabled, privacy: .public), registered=\(self.domainRegistered, privacy: .public), root=\(self.rootURL != nil, privacy: .public)) — using sync path"
            )
            return nil
        }
        // Self-corrects the cache at the point of consumption — a backstop if a
        // mid-session disable was missed by the domain-change observer.
        refreshAvailability()
        guard availabilityStorage == .ready else {
            // The domain is registered but the user hasn't enabled it in System
            // Settings (or the probe hasn't confirmed yet) — fall back so the paste
            // isn't a placeholder that never downloads. The UI prompts.
            logger.debug(
                "FP publish skipped — domain not user-enabled (availability=\(String(describing: self.availabilityStorage), privacy: .public)) — using sync path"
            )
            return nil
        }
        let item = ClipboardFileProviderManifest.Item(
            generation: generation, repIndex: repIndex, filename: filename,
            byteCount: byteCount, uti: uti)
        let manifest = ClipboardFileProviderManifest(generation: generation, items: [item])
        do {
            try container.writeManifest(manifest)
        } catch {
            logger.error(
                "Failed to write File Provider manifest: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        signalEnumerator()
        // Force the dataless placeholder dirent onto disk by making the system
        // enumerate the root. `signalEnumerator` alone only refreshes the index /
        // working set; the on-disk file for a never-browsed child is written only
        // when the root container is actually read (a `readdir`). Without this the
        // pasteboard URL points at a path that doesn't exist, so a paste fails with
        // ENOENT before the kernel's dataless trap can call `fetchContents`.
        forceRootEnumeration(root: rootURL)
        let url = rootURL.appendingPathComponent(filename)
        logger.info(
            "FP published item (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public)) at \(url.path, privacy: .public)"
        )
        return url
    }

    /// Reads the domain root directory off-main to trigger a root-container
    /// enumeration, which writes the offered item's dataless placeholder to disk.
    ///
    /// Off-main because the `readdir` blocks on the extension's enumeration
    /// round-trip; the offer→paste gap (the user switches and pastes) is far
    /// longer than the listing, so the placeholder exists by paste time.
    private func forceRootEnumeration(root: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [logger] in
            do {
                // `.skipsHiddenFiles` so the diagnostic count reflects user-visible
                // entries, not bookkeeping dirents (`.Trash`, `.DS_Store`).
                let entries = try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                logger.debug(
                    "Root listing returned \(entries.count, privacy: .public) entr(ies)")
            } catch {
                logger.error(
                    "Root enumeration readdir failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Clears the current offer's items on supersession/teardown.
    public func clearOffer() {
        // Runs synchronously on the main queue — all callers (handleOffer,
        // handleRelease, teardown) are already there. This is load-bearing: in
        // handleOffer the supersession clear is immediately followed by a
        // synchronous publishSingleFile, so an async clear would be reordered to
        // run AFTER the publish and overwrite the just-written item manifest back
        // to empty (the extension then enumerates 0 items and no placeholder is
        // created). The async branch is a defensive fallback only.
        if Thread.isMainThread {
            clearOfferOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in self?.clearOfferOnMain() }
        }
    }

    private func clearOfferOnMain() {
        // Only touch the manifest if the domain ever published — avoids creating
        // the container in a context where the File Provider is unused.
        guard domainRegistered else { return }
        do {
            try container.writeManifest(.empty)
        } catch {
            logger.debug(
                "Failed to clear File Provider manifest: \(error.localizedDescription, privacy: .public)")
        }
        signalEnumerator()
    }

    /// Signals both the working set (always tracked — the reliable channel to get
    /// the offer declared without a Finder window open) and the root container
    /// (so an open Finder window refreshes too).
    ///
    /// A non-nil completion error (e.g. `-2011` when the domain was disabled
    /// mid-offer) re-probes availability, so a missed
    /// `NSFileProviderDomainDidChange` notification is still caught within one
    /// offer cycle. The completion handler's queue isn't documented, so the
    /// re-probe hops to main explicitly rather than assuming it's already there.
    private func signalEnumerator() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .workingSet) { [weak self, logger] error in
            guard let error else { return }
            logger.warning(
                "signalEnumerator(workingSet) failed: \(error.localizedDescription, privacy: .public)"
            )
            DispatchQueue.main.async { self?.refreshAvailability() }
        }
        manager.signalEnumerator(for: .rootContainer) { [weak self, logger] error in
            guard let error else { return }
            logger.warning(
                "signalEnumerator(rootContainer) failed: \(error.localizedDescription, privacy: .public)"
            )
            DispatchQueue.main.async { self?.refreshAvailability() }
        }
    }

    // MARK: - Teardown helpers

    private func removeAllDomains(_ completion: @escaping @Sendable (Error?) -> Void) {
        NSFileProviderManager.removeAllDomains { [logger] error in
            if let error {
                logger.error(
                    "Failed to remove File Provider domains: \(error.localizedDescription, privacy: .public)"
                )
            }
            completion(error)
        }
    }

    /// Removes this app's File Provider domains, blocking until done — for the
    /// `--remove-clipboard-domain` teardown flag so host-side iteration leaves no
    /// lingering Finder location behind.
    public static func removeAllDomainsBlocking() {
        let semaphore = DispatchSemaphore(value: 0)
        NSFileProviderManager.removeAllDomains { error in
            if let error {
                print("Failed to remove File Provider domains: \(error.localizedDescription)")
            } else {
                print("Removed all Kernova File Provider domains")
            }
            semaphore.signal()
        }
        semaphore.wait()
    }
}

// MARK: - Relay service

/// The XPC-exported relay object.
///
/// Pulls a file rep through the clipboard owner and replies with the staged-file
/// path, never the bytes.
public final class ClipboardFileProviderRelayService: NSObject, ClipboardFileProviderRelay {
    private let logger: KernovaLogger
    private let pullProvider: ClipboardFileProviderPullProvider

    /// Creates the relay service, logging under `loggerSubsystem`.
    public init(pullProvider: ClipboardFileProviderPullProvider, loggerSubsystem: String) {
        self.logger = KernovaLogger(subsystem: loggerSubsystem, category: "FileProviderRelay")
        self.pullProvider = pullProvider
        super.init()
    }

    /// Pulls `(generation, repIndex)` through the owner and replies with the
    /// staged path, or an `NSFileProviderError` on failure.
    public func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        logger.debug(
            "Relay fetchFile (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))")
        // Blocks the XPC queue while the owner pulls over vsock — safe, since the
        // File Provider read path has no 60s deadline and the extension's
        // fetchContents is itself blocked on this reply.
        switch pullProvider.fetchStagedFile(generation: generation, repIndex: repIndex) {
        case .success(let path):
            logger.debug("Relay staged \(path, privacy: .public)")
            reply(path, nil)
        case .failure(let error):
            logger.error("Relay fetchFile failed: \(String(describing: error), privacy: .public)")
            reply(nil, Self.nsError(for: error))
        }
    }

    private static func nsError(for error: ClipboardFileProviderPullError) -> NSError {
        let code: NSFileProviderError.Code
        switch error {
        case .noCurrentOffer: code = .noSuchItem
        case .pullFailed: code = .serverUnreachable
        }
        return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)
    }
}
