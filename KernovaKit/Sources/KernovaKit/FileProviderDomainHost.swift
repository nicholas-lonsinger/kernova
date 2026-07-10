import FileProvider
import Foundation

// Shared clipboard File Provider domain host (issues #376 guest / #424 host).
//
// Owns the container-app side of the File Provider transport, parameterized by
// a `FileProviderConfig` so the guest agent (host→guest paste) and the
// main app (guest→host "Copy to Mac") share one implementation:
//  1. The XPC relay the sandboxed extension calls on `fetchContents` — the
//     extension can't open vsock, so the owning process (which does) pulls for
//     it.
//  2. Registration of the clipboard File Provider domain so the system
//     instantiates the extension and surfaces the domain in Finder.
//  3. The offer manifest + `signalEnumerator` that declare the current file rep
//     to the system as a dataless placeholder.
//
// Gated on clipboard policy: the domain stands up only once clipboard sharing is
// enabled, so nothing registers a domain in a context that didn't enable
// clipboard (e.g. the CI test host).
//
// Host↔extension IPC uses the canonical `NSFileProviderServicing` anonymous-XPC
// pattern (#460): the domain host injects a `FileProviderServicingConnector`
// that exports the relay to the extension so the extension can call it back at
// `fetchContents`. Both directions share this one connector — the only
// differences come from `FileProviderConfig`. The
// registration/manifest/availability machinery below is direction-agnostic and
// shared as-is.

// MARK: - Collaboration with the clipboard owner

/// Implemented by the clipboard owner so the relay can pull a file rep.
///
/// Called off-main on the relay's XPC queue when the extension's `fetchContents`
/// asks for the bytes.
public protocol FileProviderPullProvider: AnyObject, Sendable {
    /// Pulls `(generation, repIndex)` over vsock, stages it into the shared
    /// container, and returns the staged file path (or why it failed).
    func fetchStagedFile(
        generation: UInt64, repIndex: Int
    ) -> Result<String, FileProviderPullError>

    /// Aborts an in-flight `fetchStagedFile` for `(generation, repIndex)` (#464):
    /// stops the vsock transfer and wakes the blocked pull. Best-effort and
    /// idempotent — a cancel for an unknown or already-finished transfer is a
    /// no-op.
    func cancelStagedPull(generation: UInt64, repIndex: Int)
}

/// Why a relay pull failed, mapped to an `NSFileProviderError` by the relay.
public enum FileProviderPullError: Error {
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
public protocol FileProviderPublishing: AnyObject, Sendable {
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
public enum FileProviderAvailability: Equatable, Sendable {
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
public final class FileProviderDomainHost: NSObject, FileProviderPublishing,
    @unchecked Sendable
{
    private let config: FileProviderConfig
    private let logger: KernovaLogger
    private let container: FileProviderContainer
    private let pullProvider: FileProviderPullProvider
    private let domain: NSFileProviderDomain
    /// Connects to the extension and exports the relay so the extension can call
    /// it back at `fetchContents` (the servicing connector, #460).
    ///
    /// The domain host owns the relay *service*; the transport owns the XPC
    /// connection to the extension.
    private let relayTransport: FileProviderRelayTransport
    private let relayService: FileProviderRelayService
    private let notificationCenter: NotificationCenter
    private let fetchDomains: @Sendable () async throws -> [NSFileProviderDomain]
    /// Guards `domainChangeObserver`, which — unlike the rest of the state
    /// below — is also read/removed from `deinit`. `deinit` runs on whatever
    /// thread drops the last strong reference, not necessarily main, so that
    /// access can't rely on the "Main-queue state" convention.
    private let domainChangeObserverLock = NSLock()

    // MARK: Main-queue state

    private var enabled = false
    private var domainRegistered = false
    /// Set once `primeDomainChangeNotifications()` has fired. The underlying
    /// `NSFileProviderDomainDidChange` notification only needs the process's
    /// first-ever `domains()` call to go live, so repeat enables (e.g. a policy
    /// off→on toggle, or a VM stop/start cycling `HostClipboardFileProvider`'s
    /// `activeServiceCount`) skip the redundant IPC round-trip.
    private var domainChangeNotificationsPrimed = false
    /// User-visible domain root, resolved after registration; `nil` until then
    /// (the File Provider path is unused while it's `nil`).
    private var rootURL: URL?
    private var availabilityStorage: FileProviderAvailability = .inactive
    /// Token for the `NSFileProviderDomainDidChange` observer.
    ///
    /// The primary availability signal while enabled. Removed on disable and in
    /// deinit (deinit-removal pattern, see Kernova/Services/SystemSleepWatcher.swift).
    /// Guarded by `domainChangeObserverLock`, not the main queue — see that
    /// property's doc.
    private var domainChangeObserver: (any NSObjectProtocol)?
    /// Discriminates overlapping `refreshAvailability()` probes so a stale
    /// completion can't clobber a fresher one applied out of order.
    private var refreshGeneration: UInt64 = 0
    /// Notified on the main queue on every availability transition.
    ///
    /// Lets an owner mirror availability into observable UI state. Set on main;
    /// invoked on main.
    private var availabilityObserver: (@MainActor (FileProviderAvailability) -> Void)?

    /// Current File Provider usability, for the UI.
    ///
    /// Read on main.
    public var availability: FileProviderAvailability {
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
        _ observer: @escaping @MainActor (FileProviderAvailability) -> Void
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
    private func setAvailability(_ availability: FileProviderAvailability) {
        guard availabilityStorage != availability else { return }
        availabilityStorage = availability
        logger.notice(
            "File Provider availability: \(String(describing: availability), privacy: .public)")
        MainActor.assumeIsolated { availabilityObserver?(availability) }
    }

    /// Creates a domain host for one direction, pulling bytes through
    /// `pullProvider` when the extension reads a placeholder, and exporting the
    /// relay through `relayTransport`.
    ///
    /// `relayTransport` defaults to a `FileProviderServicingConnector`
    /// built from `config` — production callers omit it; tests inject a no-op so
    /// they never stand up a live anonymous-XPC connection.
    public init(
        config: FileProviderConfig,
        pullProvider: FileProviderPullProvider,
        relayTransport: FileProviderRelayTransport? = nil,
        notificationCenter: NotificationCenter = .default,
        fetchDomains: @escaping @Sendable () async throws -> [NSFileProviderDomain] = {
            try await NSFileProviderManager.domains()
        }
    ) {
        self.config = config
        self.logger = KernovaLogger(subsystem: config.loggerSubsystem, category: "FileProviderHost")
        self.container = FileProviderContainer(config: config)
        self.pullProvider = pullProvider
        self.relayTransport =
            relayTransport ?? FileProviderServicingConnector(config: config)
        self.relayService = FileProviderRelayService(
            pullProvider: pullProvider, loggerSubsystem: config.loggerSubsystem)
        self.domain = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(config.domainIdentifier),
            displayName: config.domainDisplayName)
        self.notificationCenter = notificationCenter
        self.fetchDomains = fetchDomains
        super.init()
    }

    deinit {
        stopObservingDomainChanges()
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
            // Arm the connector with the relay service. Deferred to enable so no
            // servicing connection / doorbell observer is armed in a context that
            // didn't enable clipboard sharing (notably the CI test host). The
            // connector self-guards idempotency and reconnects after an
            // invalidation, so this runs on every enable — no outer latch, which
            // would defeat the connector's "re-arm on next enable" recovery.
            relayTransport.startServing(relayService)
            startObservingDomainChanges()
            primeDomainChangeNotifications()
            registerDomain()
        } else {
            stopObservingDomainChanges()
            setAvailability(.inactive)
            // Disarm the connector: drop the control connection and stop observing
            // the doorbell so a stray fetch while disabled fails cleanly
            // (serverUnreachable) instead of reaching a relay whose offer was just
            // cleared.
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
    // a `userEnabled` flip. `publishSingleFile`'s usage-triggered refresh is a
    // backstop that bounds staleness to at most one publish cycle if a
    // notification is ever missed, so a disabled domain is caught by the next
    // paste even without the notification firing. `signalEnumerator` error
    // feedback (see `signalEnumerator()`) is a narrower backstop — per that
    // method's doc, it does not reliably surface a mid-offer disable, only other
    // failure modes (e.g. the domain having been removed outright).
    private func startObservingDomainChanges() {
        domainChangeObserverLock.withLock {
            guard domainChangeObserver == nil else { return }
            domainChangeObserver = notificationCenter.addObserver(
                forName: .fileProviderDomainDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.logger.debug(
                    "NSFileProviderDomainDidChange received — re-probing availability")
                self.refreshAvailability()
            }
        }
    }

    private func stopObservingDomainChanges() {
        domainChangeObserverLock.withLock {
            if let domainChangeObserver {
                notificationCenter.removeObserver(domainChangeObserver)
                self.domainChangeObserver = nil
            }
        }
    }

    /// Registers (or idempotently re-registers) the clipboard domain, then
    /// resolves its root URL and probes the user-enablement toggle.
    ///
    /// `add` is idempotent for an existing identifier — it updates the domain and
    /// **preserves the user's enablement**, so a normal restart never resets the
    /// toggle. Any `add` *failure*, by contrast, means the domain is registered but
    /// unusable — an orphaned replication directory (`NSFileWriteFileExistsError`),
    /// or a dead-end domain wedged after the extension is rebuilt/re-signed
    /// (`NSFileProviderError` `-2001`) — and `addDomain` self-heals by clearing our
    /// domains and re-adding once. That clear re-creates the domain in the OFF
    /// state, so a heal does reset enablement; the trade is acceptable because the
    /// pre-heal domain was already unusable.
    private func registerDomain() {
        addDomain(retryOnExists: true)
    }

    private func addDomain(retryOnExists: Bool) {
        NSFileProviderManager.add(domain) { [weak self] error in
            let failure = error?.localizedDescription
            DispatchQueue.main.async {
                guard let self else { return }
                // A failed add almost always means a domain with our identifier is
                // already registered but unusable, and NSFileProviderManager can't
                // reconcile it in place. Two ways it happens: an orphaned
                // replication dir (NSCocoaErrorDomain / NSFileWriteFileExistsError),
                // or — after the extension is rebuilt/re-signed and the old backing
                // extension is torn down — a domain wedged in a dead-end state, which
                // surfaces as NSFileProviderError -2001 "The application cannot be
                // used right now." Both self-heal by clearing our domains and adding
                // once more from a clean slate; the `retryOnExists` guard bounds it to
                // a single retry so a genuinely unrecoverable failure still surfaces.
                if failure != nil, retryOnExists {
                    self.logger.notice(
                        "add(domain:) failed (\(failure ?? "", privacy: .public)); removing stale domains and retrying")
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
    /// for the pasteboard without a per-item round-trip, and warms the servicing
    /// connection now that the root URL is known.
    ///
    /// Connecting at registration (not only at publish) is load-bearing for the
    /// reconnect doorbell: the connector can only act on the doorbell once it has
    /// the root URL, and after an owner relaunch a paste of a still-on-disk
    /// placeholder (the domain stays registered across restarts) rings the doorbell
    /// with no offer having been published yet — without this the connector would
    /// have no root URL to reconnect through and the read would hang to the
    /// extension's timeout (#460). Idempotent with the publish-time
    /// `ensureConnected`; the connector runs the connect off its own queue.
    private func resolveRootURL() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { [weak self] url, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let url {
                    self.rootURL = url
                    self.logger.notice("Clipboard domain visible at: \(url.path, privacy: .public)")
                    if self.enabled {
                        self.relayTransport.ensureConnected(rootURL: url)
                    }
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
    /// on every `publishSingleFile` usage, and on `signalEnumerator` error
    /// feedback — so flipping the toggle in System Settings takes effect without
    /// restarting the owner, with no indefinite polling. Each call is async, so
    /// it only ever lands on a *later* read of `availabilityStorage`, never the
    /// one in progress when it was triggered; `refreshGeneration` stops a stale
    /// completion from clobbering a fresher one applied out of order. A no-op
    /// while disabled. Logs every transition for diagnosis.
    private func refreshAvailability() {
        guard enabled else { return }
        let identifier = domain.identifier
        refreshGeneration &+= 1
        let generation = refreshGeneration
        Task { [weak self, fetchDomains] in
            let availability: FileProviderAvailability
            do {
                let domains = try await fetchDomains()
                availability = Self.availability(
                    forDomainMatching: identifier, in: domains, error: nil)
            } catch {
                availability = Self.availability(
                    forDomainMatching: identifier, in: [], error: error)
            }
            DispatchQueue.main.async {
                guard let self, self.enabled, generation == self.refreshGeneration else { return }
                self.setAvailability(availability)
            }
        }
    }

    /// Fires one throwaway `domains()` read so `NSFileProviderDomainDidChange`
    /// starts posting. Per Apple's header comment on that notification, it only
    /// goes live after the process's first `NSFileProviderManager.domains()`
    /// call completes; `refreshAvailability()`'s first call is gated on
    /// `addDomain` succeeding, which is async and can fail, leaving a window at
    /// enable where a System-Settings toggle flip wouldn't be observed. This
    /// primes delivery immediately and independent of registration outcome. The
    /// result is intentionally discarded — availability stays driven solely by
    /// `addDomain`'s outcome and subsequent notification-triggered refreshes.
    ///
    /// Only needs to run once per process (the notification, once armed, stays
    /// armed) — `domainChangeNotificationsPrimed` skips the IPC round-trip on
    /// every subsequent enable.
    private func primeDomainChangeNotifications() {
        guard !domainChangeNotificationsPrimed else { return }
        domainChangeNotificationsPrimed = true
        Task { [weak self, fetchDomains] in
            do {
                _ = try await fetchDomains()
            } catch {
                self?.logger.warning(
                    "Priming domains() read failed: \(error.localizedDescription, privacy: .public)"
                )
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
    ) -> FileProviderAvailability {
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
    static func availability(userEnabled: Bool) -> FileProviderAvailability {
        userEnabled ? .ready : .needsEnabling
    }

    // MARK: - FileProviderPublishing

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
        // Kicks off an async re-probe so a *later* publish self-corrects if a
        // mid-session disable was missed by the domain-change observer — this
        // call is synchronous, so the `.ready` guard right below still reads
        // whatever was cached before this refresh started.
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
        // Warm the servicing control connection PROACTIVELY (not an optimization):
        // useractivityd/sharingd fire `fetchContents` on copy, before any paste
        // (clipboard-universal-clipboard-eager-read). With the pipe already up, that
        // eager read doesn't race the doorbell handshake inside `fetchContents` and
        // blow Finder's ~60s deadline (clipboard-paste-finder-60s-deadline). The
        // connection carries NO bytes — the vsock pull stays fully lazy, running only
        // when `fetchContents` is actually invoked. The connector runs the connect on
        // its own queue, so this call doesn't block main. #460.
        relayTransport.ensureConnected(rootURL: rootURL)

        let item = FileProviderManifest.Item(
            generation: generation, repIndex: repIndex, filename: filename,
            byteCount: byteCount, uti: uti)
        let manifest = FileProviderManifest(generation: generation, items: [item])
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
    /// A non-nil completion error re-probes availability as a defensive
    /// backstop — but not for a mid-offer disable specifically: per the note on
    /// `refreshAvailability`, a `signalEnumerator` completion reports only that
    /// the signal was delivered, so it won't surface `-2011` for that case
    /// either. This instead catches other failure modes (e.g. the domain having
    /// been removed outright) within one offer cycle. The completion handler's
    /// queue isn't documented, so the re-probe hops to main explicitly rather
    /// than assuming it's already there.
    private func signalEnumerator() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        let handleCompletion: @Sendable (String, Error?) -> Void = { [weak self, logger] target, error in
            guard let error else { return }
            logger.warning(
                "signalEnumerator(\(target, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)"
            )
            DispatchQueue.main.async { self?.refreshAvailability() }
        }
        manager.signalEnumerator(for: .workingSet) { handleCompletion("workingSet", $0) }
        manager.signalEnumerator(for: .rootContainer) { handleCompletion("rootContainer", $0) }
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
public final class FileProviderRelayService: NSObject, FileProviderRelay {
    private let logger: KernovaLogger
    private let pullProvider: FileProviderPullProvider
    /// Runs each `fetchFile` pull, and each `cancelFetch` signal, off the XPC
    /// delivery queue.
    ///
    /// `NSXPCConnection` delivers every incoming exported-object call — including
    /// `cancelFetch` — on one private *serial* queue per connection (WWDC 2012
    /// session 241), so blocking that queue for the whole vsock pull (as `fetchFile`
    /// used to) would starve any `cancelFetch` for the very fetch it's trying to
    /// abort — and `cancelFetch` itself can block on a stalled peer's vsock write,
    /// so it needs the same treatment. Dispatching here frees the delivery queue
    /// immediately; `.concurrent` also lets independent multi-file pulls actually
    /// run in parallel, which the receiver/coordinator already support.
    private let pullQueue = DispatchQueue(
        label: "app.kernova.fileprovider.relay.pull", attributes: .concurrent)

    /// Creates the relay service, logging under `loggerSubsystem`.
    public init(pullProvider: FileProviderPullProvider, loggerSubsystem: String) {
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
        // Off the XPC delivery queue: the File Provider read path has no 60s
        // deadline so a long block is safe, but it must not be *this* queue — see
        // `pullQueue`'s doc for why.
        pullQueue.async { [pullProvider, logger] in
            switch pullProvider.fetchStagedFile(generation: generation, repIndex: repIndex) {
            case .success(let path):
                logger.debug("Relay staged \(path, privacy: .public)")
                reply(path, nil)
            case .failure(let error):
                logger.error(
                    "Relay fetchFile failed: \(String(describing: error), privacy: .public)")
                reply(nil, Self.nsError(for: error))
            }
        }
    }

    /// Relays a best-effort cancel to the owner's pull provider.
    ///
    /// Dispatched onto `pullQueue`, the same as `fetchFile`, rather than run
    /// directly on the connection's serial delivery queue: `cancelStagedPull`
    /// bottoms out in a vsock write (`ClipboardStreamReceiver.cancel(transferID:)`
    /// sending a `ClipboardStreamAbort`) that can block for real time against a
    /// stalled peer, and this delivery queue is shared with every other
    /// `fetchFile`/`cancelFetch` on the connection — blocking it here would
    /// reintroduce exactly the starvation problem moving `fetchFile` off the
    /// queue was meant to solve.
    public func cancelFetch(generation: UInt64, repIndex: Int) {
        logger.debug(
            "Relay cancelFetch (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))"
        )
        pullQueue.async { [pullProvider] in
            pullProvider.cancelStagedPull(generation: generation, repIndex: repIndex)
        }
    }

    private static func nsError(for error: FileProviderPullError) -> NSError {
        let code: NSFileProviderError.Code
        switch error {
        case .noCurrentOffer: code = .noSuchItem
        case .pullFailed: code = .serverUnreachable
        }
        return NSError(domain: NSFileProviderErrorDomain, code: code.rawValue)
    }
}
