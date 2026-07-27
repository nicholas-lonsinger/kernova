import FileProvider
import Foundation

// The container-app side of the clipboard File Provider transport,
// parameterized by a `FileProviderConfig` so the guest agent (host→guest paste)
// and the main app (guest→host "Copy to Mac") share one implementation.
//
// Host↔extension IPC uses the canonical `NSFileProviderServicing` anonymous-XPC
// pattern: the sandboxed extension can't open vsock, so the owning process
// exports the relay and pulls for it at `fetchContents`. The domain stands up
// only once clipboard sharing is enabled — never in a context that didn't.

// MARK: - Collaboration with the clipboard owner

/// Implemented by the clipboard owner so the relay can pull a file rep.
///
/// Called off-main on the relay's XPC queue when the extension's `fetchContents`
/// asks for the bytes.
public protocol FileProviderPullProvider: AnyObject, Sendable {
    /// Pulls `(generation, repIndex)` over vsock, stages it into the shared
    /// container, and returns the staged file path (or why it failed).
    ///
    /// `onProgress` fires off-main on the transfer's receive lane per chunk
    /// accepted off the wire and must be cheap. It reports *arrived* bytes,
    /// which can lead the staging writes by up to one credit window — fine for
    /// a progress bar, but it is not a durability signal.
    func fetchStagedFile(
        generation: UInt64, repIndex: Int,
        onProgress: @escaping @Sendable (_ bytesTransferred: UInt64, _ totalBytes: UInt64) -> Void
    ) -> Result<String, FileProviderPullError>

    /// Aborts an in-flight `fetchStagedFile` for `(generation, repIndex)`.
    ///
    /// Best-effort and idempotent — a cancel for an unknown or already-finished
    /// transfer is a no-op.
    func cancelStagedPull(generation: UInt64, repIndex: Int)

    /// Pulls one child file `(generation, repIndex, childSeq)` at `relativePath`
    /// within a directory rep, stages it into the shared container, and returns
    /// the staged path (or why it failed). Same off-main, no-deadline contract
    /// as `fetchStagedFile`.
    func fetchStagedChild(
        generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
        onProgress: @escaping @Sendable (_ bytesTransferred: UInt64, _ totalBytes: UInt64) -> Void
    ) -> Result<String, FileProviderPullError>

    /// Aborts an in-flight `fetchStagedChild` for `(generation, repIndex,
    /// childSeq)`. Best-effort and idempotent.
    func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32)
}

/// Why a relay pull failed, mapped to an `NSFileProviderError` by the relay.
public enum FileProviderPullError: Error {
    /// `(generation, repIndex)` isn't the current offer, or there's no live
    /// connection — a stale-placeholder read.
    case noCurrentOffer
    /// The vsock pull aborted, timed out, or the peer went away mid-transfer.
    case pullFailed
}

/// One file representation to publish as a dataless placeholder.
public struct FileProviderPublishItem: Equatable, Sendable {
    /// Index of the file representation within the offer.
    public var repIndex: Int
    /// Suggested filename — de-duplicated within the offer before it becomes
    /// the placeholder's name under the domain root.
    public var filename: String
    /// Total byte count, surfaced as the item's `documentSize`.
    public var byteCount: UInt64
    /// Content UTI, mapped to the item's `contentType`.
    public var uti: String

    /// Creates a publishable item from a file rep's identity and metadata.
    public init(repIndex: Int, filename: String, byteCount: UInt64, uti: String) {
        self.repIndex = repIndex
        self.filename = filename
        self.byteCount = byteCount
        self.uti = uti
    }
}

/// A directory representation to publish as a placeholder **tree**.
///
/// Salt-less: the domain host stamps its own `sessionSalt` onto the resulting
/// `FileProviderManifest.FolderRep`.
public struct FileProviderPublishFolder: Equatable, Sendable {
    /// Index of the directory representation within the offer.
    public var repIndex: Int
    /// Folder name — the root placeholder's name under the domain root.
    public var filename: String
    /// Folder/package content UTI (root `contentType`).
    public var uti: String
    /// Whether the root folder is an OS package.
    public var isPackage: Bool
    /// Stat-walk size estimate for the root's `documentSize`.
    public var byteCount: UInt64
    /// Root folder modification time (ms since epoch).
    public var mtimeMs: Int64
    /// Every descendant node (salt-independent).
    public var nodes: [FileProviderManifest.FolderRep.Node]

    /// Creates a publishable folder tree.
    public init(
        repIndex: Int, filename: String, uti: String, isPackage: Bool, byteCount: UInt64,
        mtimeMs: Int64, nodes: [FileProviderManifest.FolderRep.Node]
    ) {
        self.repIndex = repIndex
        self.filename = filename
        self.uti = uti
        self.isPackage = isPackage
        self.byteCount = byteCount
        self.mtimeMs = mtimeMs
        self.nodes = nodes
    }
}

/// Implemented by the host so the clipboard owner can surface file reps as
/// placeholders.
///
/// Every method and property here is called only on the main queue.
public protocol FileProviderPublishing: AnyObject, Sendable {
    /// Current File Provider usability, letting a paste-time caller skip the
    /// expensive routing work (e.g. a folder tree's listing fetch) when the
    /// domain isn't `.ready`.
    var availability: FileProviderAvailability { get }

    /// Publishes `items` and `folders` as the current offer and returns each
    /// rep's `file://` pasteboard URL keyed by rep index, or `nil` when the File
    /// Provider isn't usable and the caller must fall back to the synchronous
    /// provider path.
    ///
    /// `waitForPlaceholder` blocks until the root-level dirents are verified on
    /// disk, for a caller that resolves the URLs immediately; `false` enumerates
    /// asynchronously. `sourceName` names the machine the bytes come from.
    func publishItems(
        generation: UInt64, sourceName: String, items: [FileProviderPublishItem],
        folders: [FileProviderPublishFolder], waitForPlaceholder: Bool
    ) -> [Int: URL]?

    /// Pre-connects the servicing control connection so a paste-time
    /// `publishItems` isn't also paying doorbell/extension-launch latency
    /// inside the paste.
    func prepareForOffer()

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
    /// off (`userEnabled == false`).
    case needsEnabling
    /// The extension couldn't be found/launched or registration failed — an
    /// install/signing problem, not a user toggle.
    case unavailable
}

// MARK: - Host

/// Hosts the File Provider XPC relay, registers the clipboard domain, and
/// publishes the current offer's file reps — for one direction's config.
///
/// `@unchecked Sendable`: registration/manifest/availability state is touched
/// only on the main queue, the immutable `let`s are read off-main by the XPC
/// listener delegate, and the two exceptions (`domainChangeObserver`,
/// `clearReconciliationInFlight`) are guarded by their own locks.
public final class FileProviderDomainHost: NSObject, FileProviderPublishing,
    @unchecked Sendable
{
    private let config: FileProviderConfig
    private let logger: KernovaLogger
    private let container: FileProviderContainer
    /// Salts this host instance's item identifiers so a new owner session's
    /// offers can never collide with a previous session's.
    ///
    /// The offer `generation` restarts at 1 with each session while placeholder
    /// dirents survive teardown on disk; an unsalted identifier collision makes
    /// fileproviderd treat the new offer as an in-place rename of the stale —
    /// possibly materialized — placeholder with `shouldFetch:false`, so a paste
    /// serves the previous offer's bytes.
    private let sessionSalt = UInt64.random(in: .min ... .max)
    private let pullProvider: FileProviderPullProvider
    private let domain: NSFileProviderDomain
    /// Connects to the extension and exports the relay so the extension can call
    /// it back at `fetchContents`.
    private let relayTransport: FileProviderRelayTransport
    private let relayService: FileProviderRelayService
    private let notificationCenter: NotificationCenter
    private let fetchDomains: @Sendable () async throws -> [NSFileProviderDomain]
    private let addDomainToSystem: @Sendable (NSFileProviderDomain, @escaping @Sendable (Error?) -> Void) -> Void
    /// The reconciliation barrier, injected for tests.
    ///
    /// Production is `NSFileProviderManager.waitForStabilization`, which per its
    /// header doc completes once the system is caught up with both the file
    /// system's and the provider's changes up to the time of the call.
    private let waitForStabilization: @Sendable (_ completion: @escaping @Sendable (Error?) -> Void) -> Void
    /// Maps a user-visible URL to its provider-assigned item identifier,
    /// injected for tests.
    ///
    /// Production is `NSFileProviderManager.getIdentifierForUserVisibleFile`;
    /// completes `nil` when the dirent is absent or not yet assigned.
    private let resolveItemIdentifier:
        @Sendable (_ url: URL, _ completion: @escaping @Sendable (String?) -> Void) -> Void
    /// How many times a *throwing* enable-time registry read is retried before
    /// the cycle latches `.unavailable` for good.
    ///
    /// On an agent's first launch right after install the just-installed
    /// extension isn't discoverable yet, so `NSFileProviderManager.domains()`
    /// throws ("The application cannot be used right now.") until the system
    /// finishes registering it. Only that non-destructive read is retried —
    /// never an `add`; `limit × delay` bounds the window to ~60 s.
    private let registrationReadRetryLimit: Int
    /// Delay between enable-time registry-read retries (see
    /// `registrationReadRetryLimit`).
    ///
    /// Injected for tests (0 chains retries immediately).
    private let registrationReadRetryDelay: TimeInterval
    /// Guards `domainChangeObserver`, which is also read/removed from `deinit` —
    /// and `deinit` runs on whatever thread drops the last strong reference, so
    /// that access can't rely on the "Main-queue state" convention below.
    private let domainChangeObserverLock = NSLock()

    // MARK: Main-queue state

    private var enabled = false
    /// Whether the authoritative `domains()` read (or a successful `add`) has
    /// confirmed our domain is present in the system registry.
    ///
    /// Derived only from that read / add outcome — never from a *throwing*
    /// availability probe, which must leave a genuinely-registered domain marked
    /// registered so it stays publishable.
    private var domainRegistered = false
    /// User-visible domain root, resolved after registration; `nil` until then
    /// (the File Provider path is unused while it's `nil`).
    private var rootURL: URL?
    /// Whether the security scope of `rootURL` is currently open.
    ///
    /// See `adoptRootURL` for the scope's lifecycle.
    private var rootURLScopeActive = false
    /// Bumped on every `registerDomain()` call and on disable; a captured value
    /// stale by the time an `addDomainToSystem` completion lands means that cycle
    /// was superseded (or the host was disabled), so its completion must not
    /// mutate `domainRegistered`/availability.
    private var registrationEpoch: UInt64 = 0
    /// Throwing enable-time registry reads retried so far this cycle, reset to 0
    /// on each enable and bounded by `registrationReadRetryLimit`.
    private var registrationReadAttempts = 0
    private var availabilityStorage: FileProviderAvailability = .inactive
    /// Token for the `NSFileProviderDomainDidChange` observer, the primary
    /// availability signal while enabled.
    ///
    /// Removed on disable and in deinit. Guarded by `domainChangeObserverLock`,
    /// not the main queue.
    private var domainChangeObserver: (any NSObjectProtocol)?
    /// Discriminates overlapping `refreshAvailability()` probes so a stale
    /// completion can't clobber a fresher one applied out of order.
    private var refreshGeneration: UInt64 = 0
    /// Notified on the main queue on every availability transition; single-slot,
    /// see `setAvailabilityObserver`.
    private var availabilityObserver: (@MainActor (FileProviderAvailability) -> Void)?
    /// Aggregates this side's paste pulls into the clipboard progress readout.
    ///
    /// Injected by the owner rather than created here, because the same tracker
    /// also measures the flows that never touch a File Provider manifest and one
    /// readout can only come from one tracker. `nil` means no readout. Read on
    /// main.
    private var progressTracker: ClipboardProgressTracker?

    /// Current File Provider usability, for the UI, read on main.
    public var availability: FileProviderAvailability {
        dispatchPrecondition(condition: .onQueue(.main))
        return availabilityStorage
    }

    #if DEBUG
    /// Test-only view of `domainRegistered` (which gates `publishItems`), so a
    /// test can assert a *throwing* confirm read doesn't clear it.
    var domainRegisteredForTesting: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return domainRegistered
    }

    #endif

    /// Registers an observer notified on the main queue whenever `availability`
    /// changes, and immediately delivers the current value.
    ///
    /// Single-slot: a later call replaces the prior registration, so an owner
    /// driving several consumers must fan them out inside its one closure.
    /// RATIONALE: a multicast registry would be structure for a second
    /// registrant that doesn't exist — no instance registers twice today. See
    /// #588 for the alternative and why it stayed unbuilt (verified 2026-07-27).
    public func setAvailabilityObserver(
        _ observer: @escaping @MainActor (FileProviderAvailability) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        availabilityObserver = observer
        MainActor.assumeIsolated { observer(availabilityStorage) }
    }

    /// Points this host's paste pulls at the owner's progress tracker, or `nil`
    /// to render no readout.
    ///
    /// The relay captures the tracker at each pull's *entry*, so re-pointing
    /// mid-paste leaves an in-flight pull reporting to the tracker it started
    /// under — which is what keeps a superseded VM's paste rendering on its own
    /// session instead of vanishing when another VM publishes.
    public func setProgressTracker(_ tracker: ClipboardProgressTracker?) {
        dispatchPrecondition(condition: .onQueue(.main))
        progressTracker = tracker
        relayService.progressTracker = tracker
    }

    /// Updates the cached availability and notifies the observer on a
    /// transition, on main.
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
    /// Production callers take every default. Tests inject a no-op
    /// `relayTransport` so they never stand up a live anonymous-XPC connection,
    /// plus recorders for the `waitForStabilization`/`resolveItemIdentifier`
    /// seams, since fileproviderd's reconciliation is not unit-testable.
    public init(
        config: FileProviderConfig,
        pullProvider: FileProviderPullProvider,
        relayTransport: FileProviderRelayTransport? = nil,
        notificationCenter: NotificationCenter = .default,
        fetchDomains: @escaping @Sendable () async throws -> [NSFileProviderDomain] = {
            try await NSFileProviderManager.domains()
        },
        addDomainToSystem:
            @escaping @Sendable (
                NSFileProviderDomain, @escaping @Sendable (Error?) -> Void
            ) -> Void = { domain, completion in
                NSFileProviderManager.add(domain, completionHandler: completion)
            },
        waitForStabilization: (@Sendable (_ completion: @escaping @Sendable (Error?) -> Void) -> Void)? =
            nil,
        resolveItemIdentifier:
            (@Sendable (_ url: URL, _ completion: @escaping @Sendable (String?) -> Void) -> Void)? =
            nil,
        registrationReadRetryLimit: Int = 12,
        registrationReadRetryDelay: TimeInterval = 5
    ) {
        self.config = config
        self.logger = KernovaLogger(subsystem: config.loggerSubsystem, category: "FileProviderHost")
        self.container = FileProviderContainer(config: config)
        self.pullProvider = pullProvider
        self.relayTransport =
            relayTransport ?? FileProviderServicingConnector(config: config)
        self.relayService = FileProviderRelayService(
            pullProvider: pullProvider, loggerSubsystem: config.loggerSubsystem)
        self.domain = config.makeDomain()
        self.notificationCenter = notificationCenter
        self.fetchDomains = fetchDomains
        self.addDomainToSystem = addDomainToSystem
        self.registrationReadRetryLimit = registrationReadRetryLimit
        self.registrationReadRetryDelay = registrationReadRetryDelay
        // The domain is rebuilt from `config` inside the closure — the stored
        // `self.domain` is main-queue state a `@Sendable` closure can't capture.
        self.waitForStabilization =
            waitForStabilization
            ?? { completion in
                guard let manager = NSFileProviderManager(for: config.makeDomain()) else {
                    completion(CocoaError(.fileNoSuchFile))
                    return
                }
                manager.waitForStabilization(completionHandler: completion)
            }
        self.resolveItemIdentifier =
            resolveItemIdentifier
            ?? { url, completion in
                NSFileProviderManager.getIdentifierForUserVisibleFile(at: url) {
                    identifier, _, _ in
                    completion(identifier?.rawValue)
                }
            }
        super.init()
    }

    deinit {
        stopObservingDomainChanges()
        releaseRootURLScope()
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
            // Arming is deferred to enable so no servicing connection / doorbell
            // observer exists in a context that didn't enable clipboard sharing
            // (notably the CI test host). Runs on every enable — the connector
            // self-guards idempotency, and an outer latch would defeat its
            // "re-arm on next enable" recovery after an invalidation.
            relayTransport.startServing(relayService)
            startObservingDomainChanges()
            registrationReadAttempts = 0
            registerDomain()
        } else {
            stopObservingDomainChanges()
            setAvailability(.inactive)
            releaseRootURLScope()
            // Drop the control connection and stop observing the doorbell so a
            // stray fetch while disabled fails cleanly (serverUnreachable)
            // instead of reaching a relay whose offer was just cleared.
            relayTransport.stopServing()
            registrationEpoch &+= 1
            // Keep the domain registered across a policy off→on cycle: re-adding
            // a domain re-creates it in the consent-gated OFF state, which would
            // wipe the user's System-Settings enablement on every restart.
            clearOfferOnMain()
            logger.notice("File Provider disabled by clipboard policy")
        }
    }

    /// Observes `NSFileProviderDomainDidChange`, the primary detector for a
    /// mid-session System-Settings disable — the system posts it on a
    /// `userEnabled` flip.
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

    /// Brings the clipboard domain to a deliberate, logged registration state
    /// from the authoritative system registry — never a blind re-add.
    ///
    /// A single `domains()` read decides the action: a present domain is
    /// *adopted* (no `add`, so a healthy registration and the user's toggle are
    /// never touched), an absent one is *added* once, a *throwing* read lands
    /// `.unavailable`. That read also arms `NSFileProviderDomainDidChange` —
    /// Apple posts it only after the process's first `domains()` call.
    private func registerDomain() {
        dispatchPrecondition(condition: .onQueue(.main))
        registrationEpoch &+= 1
        let epoch = registrationEpoch
        // Capture only the value-typed identifier off-main — `NSFileProviderDomain`
        // is not `Sendable`; `self.domain` is touched only on the main queue.
        let identifier = domain.identifier
        Task { [weak self, fetchDomains] in
            do {
                let domains = try await fetchDomains()
                let present = domains.contains { $0.identifier == identifier }
                DispatchQueue.main.async { self?.handleRegistrationRead(epoch: epoch, present: present) }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    self?.handleRegistrationReadFailure(epoch: epoch, message: message)
                }
            }
        }
    }

    /// Applies the authoritative read's verdict: adopt a present domain, or add
    /// an absent one.
    ///
    /// Runs on main; a superseded epoch or a disable in flight is a no-op.
    private func handleRegistrationRead(epoch: UInt64, present: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled, registrationEpoch == epoch else { return }
        if present {
            logger.notice(
                "Adopted existing File Provider domain: \(self.domain.identifier.rawValue, privacy: .public) (no add)"
            )
            markRegistered(epoch: epoch)
        } else {
            logger.notice(
                "File Provider domain absent — adding: \(self.domain.identifier.rawValue, privacy: .public)"
            )
            addDomain(epoch: epoch)
        }
    }

    /// The registry read itself failed — the domain's state is unknown, so report
    /// `.unavailable` and retry the read, bounded, before giving up.
    ///
    /// A throwing read never armed the change observer, so without a retry the
    /// cycle would be terminal until a manual re-enable. The retry re-runs only
    /// the non-destructive `domains()` read — never an `add` — and captures the
    /// current `registrationEpoch`, so a disable or a newer cycle silently
    /// cancels it. On exhaustion `.unavailable` stands until a re-enable.
    private func handleRegistrationReadFailure(epoch: UInt64, message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled, registrationEpoch == epoch else { return }
        domainRegistered = false
        setAvailability(.unavailable)
        guard registrationReadAttempts < registrationReadRetryLimit else {
            logger.error(
                "File Provider registry read failed at enable: \(message, privacy: .public) — unknown/broken File Provider state, reporting unavailable (no add) after \(self.registrationReadAttempts, privacy: .public) retries"
            )
            return
        }
        registrationReadAttempts += 1
        logger.warning(
            "File Provider registry read failed at enable (attempt \(self.registrationReadAttempts, privacy: .public)/\(self.registrationReadRetryLimit, privacy: .public)): \(message, privacy: .public) — retrying the read (post-install extension discovery race, #598)"
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + registrationReadRetryDelay) { [weak self] in
            guard let self, self.enabled, self.registrationEpoch == epoch else { return }
            self.registerDomain()
        }
    }

    /// Marks the domain registered and runs the one-time post-registration steps,
    /// then applies availability.
    private func markRegistered(epoch: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        domainRegistered = true
        // Warming at registration (not only at publish) is load-bearing for the
        // reconnect doorbell: after an owner relaunch, a paste of a still-on-disk
        // placeholder rings the doorbell with no offer published yet, and the
        // connector only acts on the doorbell once a connect has been requested.
        relayTransport.ensureConnected()
        resolveRootURL(epoch: epoch)
        refreshAvailability()
    }

    /// Adds the domain when the authoritative read found it absent.
    ///
    /// Called on main so `self.domain` (non-`Sendable`) is only ever touched
    /// there; the completion hops back to main and no-ops for a superseded epoch
    /// or after a disable.
    private func addDomain(epoch: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        addDomainToSystem(domain) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.registrationEpoch == epoch else { return }
                if let error {
                    self.logger.error(
                        "Failed to add File Provider domain: \(error.localizedDescription, privacy: .public)"
                    )
                    self.domainRegistered = false
                    self.diagnoseOrphanIfNeeded(error: error)
                    self.refreshAvailability()
                    return
                }
                self.logger.notice(
                    "File Provider domain registered: \(self.domain.identifier.rawValue, privacy: .public)"
                )
                self.markRegistered(epoch: epoch)
            }
        }
    }

    /// Logs a diagnostic breadcrumb — no heal — when an `add` fails with
    /// `NSFileWriteFileExistsError` yet the domain is genuinely absent: the
    /// signature of an orphaned `~/Library/CloudStorage/<App>-<Domain>/`
    /// replication directory left by a prior install.
    ///
    /// Do not auto-heal: a `remove(domain)`+re-add against an orphan the registry
    /// doesn't even list is unverified to clear the on-disk directory (its
    /// documented cleanup is manual). Root-cause on recurrence.
    private func diagnoseOrphanIfNeeded(error: Error) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Self.isFileExistsError(error) else { return }
        let identifier = domain.identifier
        Task { [fetchDomains, logger] in
            guard let domains = try? await fetchDomains(),
                !domains.contains(where: { $0.identifier == identifier })
            else { return }
            logger.warning(
                "File Provider add failed NSFileWriteFileExistsError and domain \(identifier.rawValue, privacy: .public) is absent — likely orphaned replication directory; not auto-healing (unverified, would risk churn per #567); root-cause on recurrence"
            )
        }
    }

    /// Whether `error` is (or wraps, at any depth) `NSFileWriteFileExistsError`
    /// (Cocoa 516) — the full `NSUnderlyingErrorKey` chain is walked since File
    /// Provider's error-wrapping depth isn't contractual.
    ///
    /// `internal` (not `private`) so `KernovaKitTests` can lock the chain walk.
    static func isFileExistsError(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileWriteFileExistsError {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    /// Caches the user-visible root URL so an offer can construct `root/filename`
    /// for the pasteboard without a per-item round-trip.
    ///
    /// Epoch-guarded: a disable landing between the async `getUserVisibleURL`
    /// call and its completion must not `adoptRootURL`, which would re-open a
    /// security scope *after* `releaseRootURLScope()` and leak it until the next
    /// disable/deinit.
    private func resolveRootURL(epoch: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.getUserVisibleURL(for: .rootContainer) { [weak self] url, error in
            DispatchQueue.main.async {
                guard let self, self.enabled, self.registrationEpoch == epoch else { return }
                if let url {
                    self.adoptRootURL(url)
                    self.logger.notice("Clipboard domain visible at: \(url.path, privacy: .public)")
                } else if let error {
                    self.logger.error(
                        "getUserVisibleURL failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Caches the root URL and opens its security scope, held while the root
    /// stays current (released on disable, replacement, and deinit).
    ///
    /// `getUserVisibleURL` returns a security-scoped URL per its header doc —
    /// the sandboxed app's only access to `~/Library/CloudStorage`, without
    /// which the root readdir is denied Cocoa 257. It must stay open, not wrap
    /// individual calls: pboard mints the *pasting* app's sandbox extension from
    /// our live access whenever the promised data is provided, and silently
    /// rejects the entry otherwise ("Entry failed validation").
    private func adoptRootURL(_ url: URL) {
        releaseRootURLScope()
        rootURL = url
        rootURLScopeActive = url.startAccessingSecurityScopedResource()
    }

    /// Balances the scope opened by `adoptRootURL`, if one is active.
    ///
    /// Called on disable and on root replacement; also from `deinit`, where no
    /// concurrent access can exist so the main-queue-state convention on
    /// `rootURL`/`rootURLScopeActive` can't be violated by another thread.
    private func releaseRootURLScope() {
        if rootURLScopeActive, let rootURL {
            rootURL.stopAccessingSecurityScopedResource()
        }
        rootURLScopeActive = false
    }

    /// Re-checks whether the user has enabled the domain by reading the live
    /// `userEnabled` flag off the system's copy of the domain.
    ///
    /// `NSFileProviderDomain.userEnabled` is the authoritative signal; the
    /// locally-held `domain` carries a stale flag, so the live copy comes from
    /// `domains()`. Do not probe with `signalEnumerator` instead — its completion
    /// reports only that the *signal was delivered*, so it succeeds even when the
    /// domain is disabled and the `-2011` surfaces later, on an actual content
    /// fetch, too late to gate `publishItems`.
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

    /// Maps the system's domain registry to availability, a lookup error or a
    /// missing domain both being `.unavailable`.
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

    /// Maps a domain's `userEnabled` flag to availability.
    ///
    /// Split out so `KernovaKitTests` can lock the toggle mapping without a live
    /// `NSFileProviderDomain` (whose `userEnabled` is read-only).
    static func availability(userEnabled: Bool) -> FileProviderAvailability {
        userEnabled ? .ready : .needsEnabling
    }

    // MARK: - FileProviderPublishing

    /// Publishes the offer's file reps as the current placeholders and returns
    /// their domain URLs by rep index, or `nil` to fall back to the synchronous
    /// provider path.
    public func publishItems(
        generation: UInt64, sourceName: String, items: [FileProviderPublishItem],
        folders: [FileProviderPublishFolder], waitForPlaceholder: Bool
    ) -> [Int: URL]? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !items.isEmpty || !folders.isEmpty else { return nil }
        // Only advertise placeholders we can actually materialize: a disabled or
        // not-yet-ready domain would leave a paste that never completes.
        guard enabled, domainRegistered, let rootURL else {
            logger.debug(
                "FP publish skipped (enabled=\(self.enabled, privacy: .public), registered=\(self.domainRegistered, privacy: .public), root=\(self.rootURL != nil, privacy: .public)) — using sync path"
            )
            return nil
        }
        // Async re-probe so a *later* publish self-corrects if a mid-session
        // disable was missed by the domain-change observer; the `.ready` guard
        // below still reads whatever was cached before this refresh started.
        refreshAvailability()
        guard availabilityStorage == .ready else {
            logger.debug(
                "FP publish skipped — domain not user-enabled (availability=\(String(describing: self.availabilityStorage), privacy: .public)) — using sync path"
            )
            return nil
        }
        // Warming the control connection here is not an optimization: a consumer
        // can read the placeholder the moment the URL lands on the pasteboard,
        // and with the pipe already up that read doesn't race the doorbell
        // handshake inside `fetchContents` and blow Finder's ~60s paste deadline.
        // The connection carries no bytes — the vsock pull stays fully lazy.
        relayTransport.ensureConnected()

        // Root-level placeholders (flat files + folder roots) share one flat
        // domain root, so names must be unique across BOTH — a multi-item copy
        // can legitimately carry two same-named entries from different folders.
        let rootNames = Self.deduplicatedFilenames(items.map(\.filename) + folders.map(\.filename))
        let itemNames = Array(rootNames.prefix(items.count))
        let folderNames = Array(rootNames.suffix(folders.count))
        let manifestItems = zip(items, itemNames).map { item, filename in
            FileProviderManifest.Item(
                sessionSalt: sessionSalt, generation: generation, repIndex: item.repIndex,
                filename: filename, byteCount: item.byteCount, uti: item.uti)
        }
        let manifestFolders = zip(folders, folderNames).map { folder, filename in
            FileProviderManifest.FolderRep(
                sessionSalt: sessionSalt, generation: generation, repIndex: folder.repIndex,
                filename: filename, uti: folder.uti, isPackage: folder.isPackage,
                byteCount: folder.byteCount, mtimeMs: folder.mtimeMs, nodes: folder.nodes)
        }
        let manifest = FileProviderManifest(
            generation: generation, items: manifestItems, folders: manifestFolders)
        do {
            try container.writeManifest(manifest)
        } catch {
            logger.error(
                "Failed to write File Provider manifest: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        // Denominators for the paste readout, adopted from the same manifest the
        // enumerator serves so the two can never describe different sets of files.
        progressTracker?.offerPublished(manifest, peerName: sourceName)
        signalEnumerator()
        // `signalEnumerator`'s completion means only that the signal was
        // delivered — NOT that the manifest change has been applied to the
        // on-disk replica. Observed live: a root readdir can still serve the
        // pre-signal listing (a paste hit Finder error -43 because the fresh
        // dirent hadn't landed), and a same-named dirent from the superseded
        // offer can satisfy a bare existence check while reconciliation is
        // mid-swap. The paste-time branch below is therefore a real
        // reconciliation barrier, not a courtesy readdir.
        if waitForPlaceholder {
            // Verify each dirent resolves to ITS OWN manifest identifier —
            // identity, not just presence — bounded by
            // `placeholderEnumerationWait` so a hung fileproviderd can't strand
            // the caller's (main) thread past the paste deadline. Root-level
            // dirents only; a folder's descendants enumerate lazily as the
            // consumer descends, and a 100k-entry tree could not be verified
            // inside the barrier budget anyway.
            var expected: [String: String] = Dictionary(
                uniqueKeysWithValues: manifestItems.map { ($0.filename, $0.itemIdentifier) })
            for folder in manifestFolders { expected[folder.filename] = folder.rootIdentifier }
            guard awaitPlaceholderReconciliation(rootURL: rootURL, expected: expected) else {
                return nil
            }
        } else {
            // Offer-time publish: the offer→paste gap is far longer than the
            // reconciliation, so run the readdir off-main and let the paste-time
            // consumers re-verify.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.enumerateRoot(root: rootURL)
            }
        }
        // Derive the pasteboard promise URLs through `visibleFileURL` so they
        // name the identical on-disk file the enumerator serves; re-deriving
        // `rootURL + filename` here could drift over a de-duplicated filename.
        var urls: [Int: URL] = [:]
        for item in manifestItems {
            urls[item.repIndex] = Self.visibleFileURL(
                rootURL: rootURL, manifest: manifest, generation: generation,
                repIndex: item.repIndex, childSeq: nil)
        }
        for folder in manifestFolders {
            urls[folder.repIndex] = Self.visibleFileURL(
                rootURL: rootURL, manifest: manifest, generation: generation,
                repIndex: folder.repIndex, childSeq: 0)
        }
        logger.info(
            "FP published \(items.count, privacy: .public) file(s) + \(folders.count, privacy: .public) folder(s) (gen=\(generation, privacy: .public))"
        )
        return urls
    }

    /// Warms the paste path at offer time: pre-connects the servicing control
    /// connection so a paste-time `publishItems` doesn't also pay
    /// doorbell/extension-launch latency inside the paste.
    ///
    /// Publishes nothing — routing is decided at paste — and skips a
    /// `signalEnumerator` ping, since the owner's supersession clear right before
    /// this already signalled the enumerator and spun the extension up.
    public func prepareForOffer() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled, domainRegistered else { return }
        relayTransport.ensureConnected()
    }

    /// The user-visible URL of one published placeholder.
    ///
    /// Resolves against the *current* manifest, so a superseded generation
    /// resolves `nil` rather than a stale offer's URL. The manifest's filenames
    /// are the on-disk dirent names.
    ///
    /// `internal` (not `private`) so `KernovaKitTests` can lock the lookup.
    static func visibleFileURL(
        rootURL: URL, manifest: FileProviderManifest, generation: UInt64, repIndex: Int,
        childSeq: UInt32?
    ) -> URL? {
        guard manifest.generation == generation else { return nil }
        guard let childSeq else {
            guard let item = manifest.items.first(where: { $0.repIndex == repIndex }) else {
                return nil
            }
            return rootURL.appendingPathComponent(item.filename)
        }
        guard let folder = manifest.folders.first(where: { $0.repIndex == repIndex }) else {
            return nil
        }
        let folderRoot = rootURL.appendingPathComponent(folder.filename)
        guard childSeq != 0 else { return folderRoot }
        guard let node = folder.nodes.first(where: { $0.childSeq == childSeq }) else { return nil }
        return folderRoot.appendingPathComponent(node.relativePath)
    }

    /// De-duplicates colliding filenames within one offer, in order, in the same
    /// collision style `ClipboardFileStaging` mints for staged files.
    ///
    /// `internal` (not `private`) so `KernovaKitTests` can lock the scheme.
    static func deduplicatedFilenames(_ filenames: [String]) -> [String] {
        var used = Set<String>()
        return filenames.map { name in
            if used.insert(name).inserted { return name }
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var counter = 2
            while true {
                let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                if used.insert(candidate).inserted { return candidate }
                counter += 1
            }
        }
    }

    /// Upper bound on the paste-time reconciliation barrier (and the async
    /// clear flush).
    ///
    /// Covers a cold extension launch, yet stays inside Finder's ~60 s paste
    /// deadline with headroom for the sync fallback the timeout degrades to.
    private static let placeholderEnumerationWait: TimeInterval = 30

    /// Pacing between reconciliation verification rounds.
    ///
    /// The event-driven wait is `waitForStabilization` itself; this only paces
    /// the round where stabilization returns while the verification still fails,
    /// so the loop can't spin hot.
    private static let reconciliationRecheckDelay: TimeInterval = 0.2

    /// Outcome of one replica verification round.
    ///
    /// `internal` (not `private`) so `KernovaKitTests` can lock the decision.
    enum ReplicaVerdict: Equatable {
        /// Every expected dirent resolves to its own identifier and nothing
        /// else remains under the root.
        case verified
        /// Every expected dirent verified, but stale sibling dirents remain.
        case staleExtras(Set<String>)
        /// At least one expected dirent is missing or resolves to a different
        /// item (e.g. a same-named dirent from the superseded offer).
        case missingOrMismatched
    }

    /// Pure decision for one verification round.
    static func replicaVerdict(
        expected: [String: String], listedNames: Set<String>,
        resolvedIdentifiers: [String: String]
    ) -> ReplicaVerdict {
        for (filename, identifier) in expected {
            guard listedNames.contains(filename), resolvedIdentifiers[filename] == identifier
            else { return .missingOrMismatched }
        }
        let extras = listedNames.subtracting(expected.keys)
        return extras.isEmpty ? .verified : .staleExtras(extras)
    }

    /// Blocks the calling thread until every published placeholder is verified
    /// on disk, or the bounded barrier gives up.
    ///
    /// Returns `false` when any EXPECTED dirent stays missing or mismatched at
    /// the deadline — the caller then falls back to the sync path. Stale extras
    /// alone do not fail the paste: the returned URLs are already
    /// verified-correct, so that case proceeds with a `.warning`. The loop runs
    /// off-thread so the outer wait can bound even a wedged readdir.
    private func awaitPlaceholderReconciliation(
        rootURL: URL, expected: [String: String]
    ) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let verdict = ResultBox(false)
        let deadline = DispatchTime.now() + Self.placeholderEnumerationWait
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            verdict.value =
                self?.reconcileUntilVerified(rootURL: rootURL, expected: expected, deadline: deadline)
                ?? false
            semaphore.signal()
        }
        // +1 s over the inner deadline: the loop self-bounds every step, so the
        // outer wait only catches the loop's own thread wedging.
        guard semaphore.wait(timeout: deadline + 1) == .success else {
            logger.warning(
                "FP publish barrier thread stalled past its deadline — using sync path")
            return false
        }
        return verdict.value
    }

    /// The barrier loop: stabilize → verify → pace → repeat until the deadline.
    ///
    /// Runs on a background thread; every step is bounded by the remaining
    /// budget.
    private func reconcileUntilVerified(
        rootURL: URL, expected: [String: String], deadline: DispatchTime
    ) -> Bool {
        while true {
            _ = boundedStabilizationWait(deadline: deadline)
            let listed = listRootNames(rootURL: rootURL)
            let resolved = resolveIdentifiersBounded(
                rootURL: rootURL, filenames: Array(expected.keys), deadline: deadline)
            let verdict = Self.replicaVerdict(
                expected: expected, listedNames: listed, resolvedIdentifiers: resolved)
            if verdict == .verified {
                logger.info(
                    "FP publish barrier verified \(expected.count, privacy: .public) placeholder(s)")
                return true
            }
            if DispatchTime.now() >= deadline {
                if case .staleExtras(let extras) = verdict {
                    logger.warning(
                        "FP publish verified every expected placeholder, but \(extras.count, privacy: .public) stale sibling(s) remain after the barrier — proceeding"
                    )
                    return true
                }
                logger.warning(
                    "FP publish barrier could not verify the placeholders before the deadline — using sync path"
                )
                return false
            }
            Thread.sleep(forTimeInterval: Self.reconciliationRecheckDelay)
        }
    }

    /// One bounded `waitForStabilization` round; `false` on timeout or error
    /// (the verification pass decides what that means).
    private func boundedStabilizationWait(deadline: DispatchTime) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        let failure = ResultBox<Error?>(nil)
        waitForStabilization { error in
            failure.value = error
            semaphore.signal()
        }
        guard semaphore.wait(timeout: deadline) == .success else {
            logger.warning("waitForStabilization did not complete before the barrier deadline")
            return false
        }
        if let error = failure.value {
            logger.warning(
                "waitForStabilization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
        return true
    }

    /// User-visible dirent names under the domain root (hidden files skipped).
    ///
    /// Sandbox access comes from the security scope `adoptRootURL` holds. A
    /// failed listing returns empty — the verdict then reads missing and the
    /// barrier keeps waiting.
    private func listRootNames(rootURL: URL) -> Set<String> {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Set(entries.map(\.lastPathComponent))
    }

    /// Resolves each filename's provider-assigned item identifier, bounded by
    /// the remaining budget; unresolved names are absent from the result.
    private func resolveIdentifiersBounded(
        rootURL: URL, filenames: [String], deadline: DispatchTime
    ) -> [String: String] {
        let box = ResultBox<[String: String]>([:])
        let group = DispatchGroup()
        for filename in filenames {
            group.enter()
            resolveItemIdentifier(rootURL.appendingPathComponent(filename)) { identifier in
                if let identifier { box.withLock { $0[filename] = identifier } }
                group.leave()
            }
        }
        guard group.wait(timeout: deadline) == .success else {
            logger.warning("Identifier resolution did not complete before the barrier deadline")
            return box.value
        }
        return box.value
    }

    /// Minimal lock-guarded slot for a value produced on another thread.
    private final class ResultBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value

        init(_ initial: Value) { stored = initial }

        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }

        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.withLock { body(&stored) }
        }
    }

    /// Reads the domain root directory to trigger a root-container enumeration,
    /// which writes the offered items' dataless placeholders to disk.
    ///
    /// Blocks the calling thread on the extension's enumeration round-trip.
    private func enumerateRoot(root: URL) {
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

    /// Clears the current offer's items on supersession/teardown.
    public func clearOffer() {
        // Must run synchronously when already on main: a supersession clear is
        // immediately followed by a synchronous `publishItems`, so an async clear
        // would be reordered to run AFTER the publish and overwrite the
        // just-written manifest back to empty, leaving no placeholder at all.
        if Thread.isMainThread {
            clearOfferOnMain()
        } else {
            DispatchQueue.main.async { [weak self] in self?.clearOfferOnMain() }
        }
    }

    private func clearOfferOnMain() {
        // Ahead of the `domainRegistered` guard: a superseded offer must stop
        // driving the paste readout even in a context that never registered.
        progressTracker?.offerCleared()
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
        scheduleClearReconciliation()
    }

    /// Guards `clearReconciliationInFlight`, which is also cleared from the
    /// flush's background completion.
    private let clearReconciliationLock = NSLock()
    /// Whether a clear-path stabilization flush is currently running, so a
    /// burst of supersessions (e.g. passthrough copies every poll tick) queues
    /// at most one flush instead of stacking a blocked thread per copy.
    private var clearReconciliationInFlight = false

    #if DEBUG
    /// Test-only view of the flush latch, so the coalescing test can await the
    /// background completion clearing it before driving the next clear.
    var clearReconciliationInFlightForTesting: Bool {
        clearReconciliationLock.withLock { clearReconciliationInFlight }
    }
    #endif

    /// Drives reconciliation of a cleared offer without blocking main.
    ///
    /// Observed live: the empty-manifest write + `signalEnumerator` alone left
    /// superseded dirents on disk indefinitely — nothing forces fileproviderd to
    /// apply the deletions until something waits for stabilization. Coalesced: a
    /// clear landing while a flush is already waiting is skipped, its deletions
    /// picked up by the next clear or the next paste barrier.
    private func scheduleClearReconciliation() {
        let alreadyRunning: Bool = clearReconciliationLock.withLock {
            if clearReconciliationInFlight { return true }
            clearReconciliationInFlight = true
            return false
        }
        if alreadyRunning {
            logger.debug("File Provider clear reconciliation already in flight — skipping")
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self, logger, waitForStabilization] in
            let semaphore = DispatchSemaphore(value: 0)
            let failure = ResultBox<Error?>(nil)
            waitForStabilization { error in
                failure.value = error
                semaphore.signal()
            }
            let outcome = semaphore.wait(timeout: .now() + Self.placeholderEnumerationWait)
            self?.clearReconciliationLock.withLock {
                self?.clearReconciliationInFlight = false
            }
            guard outcome == .success else {
                logger.warning("File Provider clear reconciliation timed out")
                return
            }
            if let error = failure.value {
                logger.warning(
                    "File Provider clear reconciliation failed: \(error.localizedDescription, privacy: .public)"
                )
            } else {
                logger.notice("File Provider clear reconciled — superseded placeholders flushed")
            }
        }
    }

    /// Signals both the working set (always tracked — the reliable channel to get
    /// the offer declared without a Finder window open) and the root container
    /// (so an open Finder window refreshes too).
    ///
    /// A non-nil completion error re-probes availability, catching failure modes
    /// such as the domain having been removed outright — not a mid-offer disable,
    /// which this channel cannot surface. The completion handler's queue isn't
    /// documented, so the re-probe hops to main explicitly.
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

    /// Removes this app's File Provider domains, blocking until done — backs the
    /// `--remove-clipboard-domain` teardown flag on both the host app and the
    /// guest agent.
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
