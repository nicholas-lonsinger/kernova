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
    ///
    /// `onProgress` is fed the receiver's cumulative `(bytesTransferred,
    /// totalBytes)` per chunk accepted off the wire, so the relay can push
    /// coalesced progress back to the extension's `fetchContents` `Progress`
    /// (#426). It fires off-main on the transfer's receive lane and must be
    /// cheap. Since #615 it reports *arrived* bytes, which can lead the staging
    /// writes by up to one credit window — fine for a progress bar, but it is
    /// not a durability signal.
    func fetchStagedFile(
        generation: UInt64, repIndex: Int,
        onProgress: @escaping @Sendable (_ bytesTransferred: UInt64, _ totalBytes: UInt64) -> Void
    ) -> Result<String, FileProviderPullError>

    /// Aborts an in-flight `fetchStagedFile` for `(generation, repIndex)` (#464):
    /// stops the vsock transfer and wakes the blocked pull. Best-effort and
    /// idempotent — a cancel for an unknown or already-finished transfer is a
    /// no-op.
    func cancelStagedPull(generation: UInt64, repIndex: Int)

    /// Pulls one child file `(generation, repIndex, childSeq)` at `relativePath`
    /// within a directory rep (folder D1b), stages it into the shared container,
    /// and returns the staged path (or why it failed). Same off-main, no-deadline
    /// contract as `fetchStagedFile`.
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

/// A directory representation to publish as a placeholder **tree** (folder D1b).
///
/// Salt-less: the domain host stamps its own `sessionSalt` (#541) onto the
/// resulting `FileProviderManifest.FolderRep`. The consumer builds this from a
/// received tree listing (see `ClipboardDirectoryTree.makeFolderRep`, whose
/// `nodes` this carries).
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
/// Lets the clipboard owner publish an offer's file reps as dataless
/// placeholders and get their pasteboard URLs. Called only on the main queue.
public protocol FileProviderPublishing: AnyObject, Sendable {
    /// Current File Provider usability, read on the main queue (like every method
    /// here). Lets a paste-time caller skip the more expensive routing work (e.g.
    /// a folder tree's listing fetch) when the domain isn't `.ready`, rather than
    /// doing it only for `publishItems` to fall back to `nil`.
    var availability: FileProviderAvailability { get }

    /// Publishes `items` as the current offer and returns each item's `file://`
    /// pasteboard URL keyed by rep index, or `nil` when the File Provider isn't
    /// usable (sharing off, domain not registered, or the user toggle is off)
    /// so the caller falls back to the synchronous provider path.
    ///
    /// `waitForPlaceholder` selects when the placeholder dirents must exist:
    /// `true` blocks on a root enumeration before returning — the paste-time
    /// caller hands the URLs straight to a consumer that resolves them
    /// immediately — while `false` forces the enumeration asynchronously, for
    /// an offer-time caller whose offer→paste gap covers the listing.
    ///
    /// `folders` publishes directory reps as placeholder *trees* (folder D1b)
    /// alongside the flat `items`; the returned map keys both by rep index. The
    /// paste-time barrier verifies only the root-level dirents (flat files +
    /// folder roots) — a folder's descendants enumerate lazily as the consumer
    /// descends.
    func publishItems(
        generation: UInt64, items: [FileProviderPublishItem],
        folders: [FileProviderPublishFolder], waitForPlaceholder: Bool
    ) -> [Int: URL]?

    /// Cheap warm-up ahead of a possible paste-time publish: pre-connects the
    /// servicing control connection so `publishItems` isn't also paying
    /// doorbell/extension-launch latency inside the paste.
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
/// are immutable `let`s the XPC listener delegate reads off-main; the two
/// exceptions (`domainChangeObserver`, `clearReconciliationInFlight`) are
/// guarded by their own locks — see each property's doc.
public final class FileProviderDomainHost: NSObject, FileProviderPublishing,
    @unchecked Sendable
{
    private let config: FileProviderConfig
    private let logger: KernovaLogger
    private let container: FileProviderContainer
    /// Salts this host instance's item identifiers so a new owner session's
    /// offers can never collide with a previous session's (#541).
    ///
    /// The offer `generation` restarts at 1 with each session while placeholder
    /// dirents survive teardown on disk; an unsalted identifier collision makes
    /// fileproviderd treat the new offer as an in-place rename of the stale —
    /// possibly materialized — placeholder with `shouldFetch:false`, so a paste
    /// serves the previous offer's bytes. See `FileProviderItemIdentifier`.
    private let sessionSalt = UInt64.random(in: .min ... .max)
    private let pullProvider: FileProviderPullProvider
    private let domain: NSFileProviderDomain
    /// Connects to the extension and exports the relay so the extension can call
    /// it back at `fetchContents` (the servicing connector, #460).
    ///
    /// The domain host owns the relay *service*; the transport owns the XPC
    /// connection to the extension.
    private let relayTransport: FileProviderRelayTransport
    private let relayService: FileProviderRelayService
    /// The published offer's user-visible URLs, shared with `relayService` so an
    /// in-flight pull can name the file it is materializing for Finder's copy
    /// dialog (#634).
    ///
    /// Written here (on main, from `publishItems`/`clearOfferOnMain`) and read
    /// off-main by the relay; the type is lock-guarded for exactly that.
    private let offerURLIndex: FileProviderOfferURLIndex
    private let notificationCenter: NotificationCenter
    private let fetchDomains: @Sendable () async throws -> [NSFileProviderDomain]
    private let addDomainToSystem: @Sendable (NSFileProviderDomain, @escaping @Sendable (Error?) -> Void) -> Void
    /// The reconciliation barrier, injected for tests.
    ///
    /// Production is `NSFileProviderManager.waitForStabilization`: completes
    /// once the system is caught up with both the file system's and the
    /// provider's changes up to the time of the call (per its header doc) —
    /// i.e. once manifest-reported creations/deletions have been applied to
    /// the on-disk replica.
    private let waitForStabilization: @Sendable (_ completion: @escaping @Sendable (Error?) -> Void) -> Void
    /// Maps a user-visible URL to its provider-assigned item identifier,
    /// injected for tests.
    ///
    /// Production is `NSFileProviderManager.getIdentifierForUserVisibleFile`;
    /// completes `nil` when the dirent is absent or not yet assigned.
    private let resolveItemIdentifier:
        @Sendable (_ url: URL, _ completion: @escaping @Sendable (String?) -> Void) -> Void
    /// How many times a *throwing* enable-time registry read is retried before
    /// the cycle latches `.unavailable` for good (#598).
    ///
    /// Injected for tests. On an agent's first launch right after install the
    /// just-installed extension isn't discoverable yet, so
    /// `NSFileProviderManager.domains()` throws ("The application cannot be used
    /// right now.") until the system finishes registering it. The read is
    /// non-destructive — the same `domains()` call `refreshAvailability` already
    /// repeats freely — so retrying it (never an `add`) is safe; `limit × delay`
    /// bounds the window (~60 s) to post-install extension discovery.
    private let registrationReadRetryLimit: Int
    /// Delay between enable-time registry-read retries (see
    /// `registrationReadRetryLimit`).
    ///
    /// Injected for tests (0 chains retries immediately).
    private let registrationReadRetryDelay: TimeInterval
    /// Guards `domainChangeObserver`, which — unlike the rest of the state
    /// below — is also read/removed from `deinit`. `deinit` runs on whatever
    /// thread drops the last strong reference, not necessarily main, so that
    /// access can't rely on the "Main-queue state" convention.
    private let domainChangeObserverLock = NSLock()

    // MARK: Main-queue state

    private var enabled = false
    /// Whether the authoritative `domains()` read (or a successful `add`) has
    /// confirmed our domain is present in the system registry.
    ///
    /// Derived from that read / add outcome — never from a *throwing* availability
    /// probe, which leaves a genuinely-registered domain marked registered so it
    /// stays publishable (see `handleRegistrationRead`/`addDomain`).
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
    /// was superseded (or the host was disabled) — so its stale completion must
    /// not mutate `domainRegistered`/availability (#428).
    ///
    /// Without this, a `setEnabled(true)`→`setEnabled(false)`→`setEnabled(true)`
    /// churn faster than one `NSFileProviderManager.add` round-trip lets the first
    /// cycle's late completion land after a second cycle already succeeded,
    /// clobbering state out of order.
    private var registrationEpoch: UInt64 = 0
    /// Throwing enable-time registry reads retried so far this cycle (#598),
    /// reset to 0 on each enable and bounded by `registrationReadRetryLimit`.
    private var registrationReadAttempts = 0
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
    /// invoked on main. Single-slot; see `setAvailabilityObserver`.
    private var availabilityObserver: (@MainActor (FileProviderAvailability) -> Void)?

    /// Current File Provider usability, for the UI.
    ///
    /// Read on main.
    public var availability: FileProviderAvailability {
        dispatchPrecondition(condition: .onQueue(.main))
        return availabilityStorage
    }

    #if DEBUG
    /// Test-only view of `domainRegistered` (which gates `publishItems`), so a
    /// test can assert a *throwing* confirm read doesn't clear it — the wedge
    /// `refreshAvailability` must never cause (state-first registration, #2).
    var domainRegisteredForTesting: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return domainRegistered
    }
    #endif

    /// Registers an observer notified on the main queue whenever `availability`
    /// changes, and immediately delivers the current value.
    ///
    /// The owner mirrors this into observable UI state; the domain-change
    /// observer keeps it live, so a user flipping the System-Settings toggle is
    /// reflected without a restart.
    ///
    /// Single-observer by design: each host instance has exactly one owner, so a
    /// later call replaces the prior registration (standard setter semantics,
    /// the same shape as a Cocoa `delegate`). An owner driving several consumers
    /// fans them out inside its one closure — see the guest agent's
    /// `AgentAppDelegate`, which forwards to both the #429 re-publish path and
    /// the #581 status-item badge.
    ///
    /// `RATIONALE:` a multicast observer registry here would be speculative
    /// structure for a second registrant that doesn't exist — no instance
    /// registers twice today (the host side has one observer; the guest fans
    /// out at its single call site). The single-slot contract is documented
    /// here and at that call site instead of defended with new machinery. See
    /// #588.
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
    /// they never stand up a live anonymous-XPC connection. `waitForStabilization`
    /// and `resolveItemIdentifier` are the reconciliation seams (production:
    /// `NSFileProviderManager.waitForStabilization` /
    /// `getIdentifierForUserVisibleFile`); tests inject recorders, since
    /// fileproviderd's reconciliation itself is not unit-testable.
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
        // Built as a local first: `relayService` is initialized before
        // `super.init()`, so it can't be handed `self.offerURLIndex` — both get
        // the same local instance instead.
        let offerURLIndex = FileProviderOfferURLIndex()
        self.offerURLIndex = offerURLIndex
        self.relayService = FileProviderRelayService(
            pullProvider: pullProvider, loggerSubsystem: config.loggerSubsystem,
            offerURLIndex: offerURLIndex)
        self.domain = config.makeDomain()
        self.notificationCenter = notificationCenter
        self.fetchDomains = fetchDomains
        self.addDomainToSystem = addDomainToSystem
        self.registrationReadRetryLimit = registrationReadRetryLimit
        self.registrationReadRetryDelay = registrationReadRetryDelay
        // The domain is rebuilt from `config` inside the closure — the stored
        // `self.domain` is main-queue state a `@Sendable` closure can't capture
        // (same shape as the connector's per-attempt `config.makeDomain()`).
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
            // Arm the connector with the relay service. Deferred to enable so no
            // servicing connection / doorbell observer is armed in a context that
            // didn't enable clipboard sharing (notably the CI test host). The
            // connector self-guards idempotency and reconnects after an
            // invalidation, so this runs on every enable — no outer latch, which
            // would defeat the connector's "re-arm on next enable" recovery.
            relayTransport.startServing(relayService)
            startObservingDomainChanges()
            // Fresh retry budget per enable cycle for the enable-time registry
            // read (#598); see `handleRegistrationReadFailure`.
            registrationReadAttempts = 0
            registerDomain()
        } else {
            stopObservingDomainChanges()
            setAvailability(.inactive)
            // No offer can be valid while disabled (the manifest is cleared
            // below), so the domain-root scope has no consumer until the next
            // enable's registration re-resolves the root and re-opens it.
            releaseRootURLScope()
            // Disarm the connector: drop the control connection and stop observing
            // the doorbell so a stray fetch while disabled fails cleanly
            // (serverUnreachable) instead of reaching a relay whose offer was just
            // cleared.
            relayTransport.stopServing()
            // Invalidate any registration cycle still outstanding from before this
            // disable (#428) — its eventual `addDomainToSystem` completion must not
            // mutate state for what is now a superseded epoch; see
            // `registrationEpoch`'s doc.
            registrationEpoch &+= 1
            // Keep the domain registered across a policy off→on cycle: re-adding a
            // domain re-creates it in the consent-gated OFF state, which would wipe
            // the user's System-Settings enablement on every restart. Just clear
            // the offer's items so nothing lingers.
            clearOfferOnMain()
            logger.notice("File Provider disabled by clipboard policy")
        }
    }

    // RATIONALE: `publishItems` is synchronous and decides
    // File-Provider-vs-sync-fallback purely from the cached `availabilityStorage`;
    // it never re-probes (it can't await an async `signalEnumerator`). A prior
    // version kept that cache honest with a 3s repeating poll timer for the whole
    // enabled lifetime. That's replaced by event/usage-driven refreshes instead of
    // indefinite polling: `NSFileProviderDomainDidChange` (below) is the primary
    // detector for a mid-session System-Settings disable — the system posts it on
    // a `userEnabled` flip. `publishItems`'s usage-triggered refresh is a
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

    /// Brings the clipboard domain to a deliberate, logged registration state
    /// from the authoritative system registry — never a blind re-add.
    ///
    /// A single `domains()` read decides the action: an already-present domain is
    /// *adopted* (no `add`, so a healthy registration and the user's toggle are
    /// never touched); a genuinely absent domain is *added* once; a read that
    /// *throws* — e.g. the version conflict when a stale older copy of the app is
    /// registered, where every `NSFileProviderManager` call fails — lands
    /// `.unavailable` honestly. This read also arms `NSFileProviderDomainDidChange`
    /// (Apple posts it only after the process's first `domains()` call), replacing
    /// the old throwaway priming read; a *throwing* read does not arm it, so the
    /// cycle recovers only through the bounded enable-time read retry (see
    /// `handleRegistrationReadFailure`) — and failing that, clears on a re-enable.
    ///
    /// Per Apple, re-adding an existing identifier would merely update it in place
    /// and preserve the read-only `userEnabled`, so adopting instead of re-adding
    /// loses nothing while keeping the action deliberate. (Our `domainDisplayName`
    /// is a static constant; a future change to it would need a deliberate re-add,
    /// since the adopt path skips `add`.) An `add` *failure* is not retried or
    /// healed (#567/#590): availability is reported from the registry, and only
    /// the orphaned-directory signature is logged (see `diagnoseOrphanIfNeeded`).
    ///
    /// This method decides `domainRegistered` and runs the post-registration steps
    /// on main; availability is always applied by `refreshAvailability()`, the
    /// single `enabled`+`refreshGeneration`-guarded reader.
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

    /// Applies the authoritative read's verdict: adopt a present domain, or add an
    /// absent one.
    ///
    /// Runs on main; a superseded cycle (epoch bumped by a disable or a newer
    /// `registerDomain`) or a disable in flight is a no-op.
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
    /// On an agent's first launch right after install the extension isn't
    /// discoverable yet and `domains()` throws until the system registers it
    /// (#598); a throwing read also never armed the change observer, so without a
    /// retry the cycle is terminal until a manual re-enable. So this keeps the
    /// honest immediate state (`domainRegistered = false`, `.unavailable` — the UI
    /// stays red through the window and the transition log dedupes), then, while
    /// the budget lasts, re-schedules `registerDomain()` after
    /// `registrationReadRetryDelay`. The retry re-runs only the non-destructive
    /// `domains()` read — never an `add`, which stays terminally un-healed
    /// (#567/#590) — and captures the current `registrationEpoch`, so a disable or
    /// a newer cycle silently cancels the scheduled attempt. On exhaustion
    /// `.unavailable` stands, clearing only on a re-enable — today's semantics,
    /// now reached after the bounded retry rather than on the first failure.
    ///
    /// Written directly (not via `refreshAvailability`): keeping the write
    /// synchronous inside this epoch/`enabled`-guarded handler avoids a phantom
    /// re-read disagreeing with `domainRegistered = false`.
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
        // `.warning`, not `.notice`: a failed read we are recovering from is
        // degraded-but-recoverable operation, which is what AGENTS.md's level
        // table assigns to `.warning` (`.notice` is for definitive lifecycle
        // events). Both persist, so the post-mortem trail is unaffected.
        logger.warning(
            "File Provider registry read failed at enable (attempt \(self.registrationReadAttempts, privacy: .public)/\(self.registrationReadRetryLimit, privacy: .public)): \(message, privacy: .public) — retrying the read (post-install extension discovery race, #598)"
        )
        // `epoch` is this cycle's — the guard above already proved it equals
        // `registrationEpoch`, so re-reading the property would say the same
        // thing less clearly. A disable or a newer cycle bumps it, which is what
        // makes the scheduled retry a silent no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + registrationReadRetryDelay) { [weak self] in
            guard let self, self.enabled, self.registrationEpoch == epoch else { return }
            self.registerDomain()
        }
    }

    /// Marks the domain registered and runs the one-time post-registration steps,
    /// then applies availability.
    ///
    /// Shared by the adopt and add-success paths.
    private func markRegistered(epoch: UInt64) {
        dispatchPrecondition(condition: .onQueue(.main))
        domainRegistered = true
        // Warm the servicing connection at registration (not only at publish) —
        // load-bearing for the reconnect doorbell: after an owner relaunch, a paste
        // of a still-on-disk placeholder (the domain stays registered across
        // restarts) rings the doorbell with no offer having been published yet, and
        // the connector only acts on the doorbell once a connect has been requested
        // (#460). Idempotent with the publish-time `ensureConnected`.
        relayTransport.ensureConnected()
        resolveRootURL(epoch: epoch)
        refreshAvailability()
    }

    /// Adds the domain when the authoritative read found it absent.
    ///
    /// Called on main so `self.domain` (non-`Sendable`) is only ever touched there;
    /// the completion hops back to main and no-ops for a superseded epoch or after a
    /// disable (#428).
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
                    // Report from the registry (the domain was absent and the add
                    // failed → `.unavailable`); the guarded reader also orders this
                    // against any notification-driven probe the armed HOP-1 read
                    // may have enabled.
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
    /// replication directory left by a prior install (#471).
    ///
    /// We deliberately do NOT auto-heal. A `remove(domain)`+re-add against an
    /// orphan the registry doesn't even list is unverified to clear the on-disk
    /// directory (its documented cleanup is manual), so firing it would risk
    /// churning without fixing anything — the same reasoning that removed the prior
    /// blind heal (#567/#590). Root-cause on recurrence.
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
    /// Epoch-guarded: a disable (or a newer registration cycle) landing between the
    /// async `getUserVisibleURL` call and its completion must not `adoptRootURL` —
    /// that would re-open a security scope *after* the disable's
    /// `releaseRootURLScope()`, leaking it until the next disable/deinit.
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

    /// Caches the root URL and opens its security scope, holding it for as long
    /// as the root stays current (released on disable, replacement, and deinit).
    ///
    /// The URL `getUserVisibleURL` returns is security-scoped (per its header
    /// doc) — the sandboxed host app's only access to the domain root under
    /// `~/Library/CloudStorage`, which no entitlement covers (#539). The scope is
    /// held open rather than wrapped around individual calls because TWO
    /// consumers need it live:
    /// - `forceRootEnumeration`'s readdir (denied Cocoa 257 otherwise), and
    /// - the pasteboard server's sandbox validation when the placeholder's
    ///   `public.file-url` lands on the host pasteboard: pboard mints the
    ///   *pasting* app's sandbox extension from OUR live access to the referenced
    ///   path, at whatever moment the promised data is provided (Universal
    ///   Clipboard's eager read makes that copy time, a paste makes it later).
    ///   Without the scope the entry is silently rejected ("Entry failed
    ///   validation" in pboard's log) and a Finder ⌘V just beeps.
    ///
    /// In the unsandboxed guest agent `startAccessingSecurityScopedResource`
    /// reports no scope was taken and all access works on ordinary permissions.
    private func adoptRootURL(_ url: URL) {
        releaseRootURLScope()
        rootURL = url
        rootURLScopeActive = url.startAccessingSecurityScopedResource()
    }

    /// Balances the scope opened by `adoptRootURL`, if one is active.
    ///
    /// Called on disable and on root replacement; also from `deinit`, where no
    /// concurrent access can exist (this is the last reference) so the
    /// main-queue-state convention on `rootURL`/`rootURLScopeActive` can't be
    /// violated by another thread.
    private func releaseRootURLScope() {
        if rootURLScopeActive, let rootURL {
            rootURL.stopAccessingSecurityScopedResource()
        }
        rootURLScopeActive = false
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
    /// content fetch, too late to gate `publishItems`. The locally-held
    /// `domain` carries a stale flag, so the live copy is fetched via `domains()`.
    ///
    /// Called on registration, on an `NSFileProviderDomainDidChange` notification,
    /// on every `publishItems` usage, and on `signalEnumerator` error
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

    /// Publishes the offer's file reps as the current placeholders and returns
    /// their domain URLs by rep index, or `nil` to fall back to the synchronous
    /// provider path.
    public func publishItems(
        generation: UInt64, items: [FileProviderPublishItem],
        folders: [FileProviderPublishFolder], waitForPlaceholder: Bool
    ) -> [Int: URL]? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !items.isEmpty || !folders.isEmpty else { return nil }
        // Only advertise placeholders we can actually materialize: a disabled or
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
        // a consumer can read the placeholder immediately after the URL lands on
        // the pasteboard, and with the pipe already up that read doesn't race the
        // doorbell handshake inside `fetchContents` and blow Finder's ~60s paste
        // deadline (clipboard-paste-finder-60s-deadline). The connection carries
        // NO bytes — the vsock pull stays fully lazy, running only when
        // `fetchContents` is actually invoked. The connector runs the connect on
        // its own queue, so this call doesn't block main. #460. Idempotent with
        // the offer-time `prepareForOffer` warm-up.
        relayTransport.ensureConnected()

        // Root-level placeholders (flat files + folder roots) share one flat
        // domain root, so names must be unique across BOTH — a multi-item copy
        // can legitimately carry two same-named entries from different folders.
        // Dedup them together in a stable order (flat items first, then folder
        // roots) so a flat file and a folder root never collide on a dirent.
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
            // Paste-time publish (#427 leading edge): the caller is about to hand
            // the URLs to a consumer that resolves them immediately, so wait on
            // `waitForStabilization` — the documented catch-up barrier ("wait
            // until [the system] is caught up with the provider's changes up to
            // the time of the call") — and then verify each returned item's
            // dirent resolves to ITS OWN manifest identifier via
            // `getIdentifierForUserVisibleFile`: identity, not just presence.
            // Bounded (`placeholderEnumerationWait` total): a hung fileproviderd
            // must not strand the caller's (main) thread past the paste deadline;
            // on timeout or an unverified dirent this degrades to the size-capped
            // sync path (`nil`) instead of advertising a URL that would fail the
            // paste with -43.
            // Root-level dirents only (flat files + folder roots); a folder's
            // descendants enumerate lazily as the consumer descends, so verifying
            // them here would be both unnecessary and (for a 100k-entry tree)
            // impossible within the barrier budget.
            var expected: [String: String] = Dictionary(
                uniqueKeysWithValues: manifestItems.map { ($0.filename, $0.itemIdentifier) })
            for folder in manifestFolders { expected[folder.filename] = folder.rootIdentifier }
            guard awaitPlaceholderReconciliation(rootURL: rootURL, expected: expected) else {
                return nil
            }
        } else {
            // Offer-time publish: the offer→paste gap (the user switches and
            // pastes) is far longer than the reconciliation, so run the readdir
            // off-main and let the paste-time consumers re-verify.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.enumerateRoot(root: rootURL)
            }
        }
        var urls: [Int: URL] = [:]
        for (item, filename) in zip(manifestItems, itemNames) {
            urls[item.repIndex] = rootURL.appendingPathComponent(filename)
        }
        for (folder, filename) in zip(manifestFolders, folderNames) {
            urls[folder.repIndex] = rootURL.appendingPathComponent(filename)
        }
        logger.info(
            "FP published \(items.count, privacy: .public) file(s) + \(folders.count, privacy: .public) folder(s) (gen=\(generation, privacy: .public))"
        )
        // Cache the URLs the relay's pulls will need to publish a Finder-visible
        // progress (#634) — these exact ones, so the two paths can't disagree
        // about a de-duplicated filename.
        offerURLIndex.update(generation: generation, urls: urls)
        return urls
    }

    /// Warms the paste path at offer time: pre-connects the servicing control
    /// connection so a paste-time `publishItems` doesn't also pay
    /// doorbell/extension-launch latency inside the paste.
    ///
    /// Deliberately publishes nothing — routing is decided at paste (#427
    /// leading edge) — and skips a `signalEnumerator` ping: the owner clears the
    /// superseded offer right before calling this, and that clear already
    /// signals the enumerator, spinning the extension up.
    public func prepareForOffer() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled, domainRegistered else { return }
        relayTransport.ensureConnected()
    }

    /// De-duplicates colliding filenames within one offer, in order: the second
    /// "report.pdf" becomes "report (2).pdf" — the same collision style
    /// `ClipboardFileStaging` mints for staged files.
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
    /// Generous against the normal sub-second stabilization (it covers a cold
    /// extension launch), yet comfortably inside Finder's ~60 s paste deadline
    /// with headroom left for the sync fallback the timeout degrades to.
    private static let placeholderEnumerationWait: TimeInterval = 30

    /// Pacing between reconciliation verification rounds.
    ///
    /// RATIONALE: the event-driven wait is `waitForStabilization` itself —
    /// this delay only paces the round where stabilization returns while the
    /// verification still fails (state landed mid-flight), so the loop can't
    /// spin hot. It is not a poll substitute for a missing signal.
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

    /// Pure decision for one verification round: compares the expected
    /// `filename → itemIdentifier` map against the listed dirent names and the
    /// identifiers those dirents resolved to.
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
    /// verified-correct, and refusing a valid paste over a leftover sibling
    /// would cost more than the cosmetic lag — that case proceeds with a
    /// `.warning`. The loop runs off-thread so the outer wait can bound even a
    /// wedged readdir.
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
        // +1 s over the inner deadline: the loop self-bounds every step; the
        // outer wait only catches the loop's own thread wedging (e.g. inside a
        // hung readdir).
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
    /// Sandbox access comes from the security scope held while the root is
    /// current (`adoptRootURL`, #539). A failed listing returns empty — the
    /// verdict then reads missing and the barrier keeps waiting.
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
    /// Blocks the calling thread on the extension's enumeration round-trip; see
    /// `publishItems` for who calls it where.
    private func enumerateRoot(root: URL) {
        // Sandbox access to the domain root comes from the security scope the
        // domain host holds open while the root is current (`adoptRootURL`,
        // #539) — publishItems' `enabled`+`rootURL` guard means it is always
        // active here.
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
        // Runs synchronously on the main queue — all callers (handleOffer,
        // handleRelease, teardown) are already there. This is load-bearing: in
        // handleOffer the supersession clear is immediately followed by a
        // synchronous publishItems, so an async clear would be reordered to
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
        // Unconditional, ahead of the `domainRegistered` guard below: the index
        // is in-memory only, so dropping it creates nothing, and a superseded
        // offer's URLs must stop resolving even on a path that skips the
        // manifest write.
        offerURLIndex.clear()
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

    /// Guards `clearReconciliationInFlight`, which — unlike the main-queue state
    /// above — is also cleared from the flush's background completion.
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
    /// superseded dirents on disk indefinitely (they accumulated across offers)
    /// — nothing forces fileproviderd to apply the deletions until something
    /// waits for stabilization. This runs the bounded wait on a background
    /// queue so superseded items disappear at copy time; the paste-time barrier
    /// remains the correctness backstop. Coalesced: a clear landing while a
    /// flush is already waiting is skipped — its deletions are picked up by the
    /// next clear or the next paste barrier, which is tolerable staleness in
    /// exchange for never stacking blocked threads under a copy burst.
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

    /// Removes this app's File Provider domains, blocking until done — backs the
    /// `--remove-clipboard-domain` teardown flag wired by both the host app
    /// (`AppDelegate.main()`) and the guest agent (`AgentAppDelegate.main()`), so
    /// dev/test iteration on either side leaves no lingering Finder location behind.
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
