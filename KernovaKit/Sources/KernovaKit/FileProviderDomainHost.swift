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

/// Implemented by the host so the clipboard owner can surface file reps as
/// placeholders.
///
/// Lets the clipboard owner publish an offer's file reps as dataless
/// placeholders and get their pasteboard URLs. Called only on the main queue.
public protocol FileProviderPublishing: AnyObject, Sendable {
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
    func publishItems(
        generation: UInt64, items: [FileProviderPublishItem], waitForPlaceholder: Bool
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
/// are immutable `let`s the XPC listener delegate reads off-main.
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
    private let notificationCenter: NotificationCenter
    private let fetchDomains: @Sendable () async throws -> [NSFileProviderDomain]
    private let addDomainToSystem: @Sendable (NSFileProviderDomain, @escaping @Sendable (Error?) -> Void) -> Void
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
    /// they never stand up a live anonymous-XPC connection.
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
        self.domain = config.makeDomain()
        self.notificationCenter = notificationCenter
        self.fetchDomains = fetchDomains
        self.addDomainToSystem = addDomainToSystem
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
    /// the old throwaway priming read; a *throwing* read does not arm it, so that
    /// (unrecoverable-in-process) state clears only on a re-enable.
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
    /// `.unavailable` without adding.
    ///
    /// Written directly (not via `refreshAvailability`): this is the cycle's first
    /// read, so no probe is in flight to race, and a re-read would just throw again
    /// — keeping the write synchronous inside this epoch/`enabled`-guarded handler
    /// avoids a phantom re-read disagreeing with `domainRegistered = false`.
    private func handleRegistrationReadFailure(epoch: UInt64, message: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard enabled, registrationEpoch == epoch else { return }
        logger.error(
            "File Provider registry read failed at enable: \(message, privacy: .public) — unknown/broken File Provider state, reporting unavailable (no add)"
        )
        domainRegistered = false
        setAvailability(.unavailable)
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
        generation: UInt64, items: [FileProviderPublishItem], waitForPlaceholder: Bool
    ) -> [Int: URL]? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !items.isEmpty else { return nil }
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

        // Placeholders share one flat domain root, so names must be unique
        // within the offer — a multi-item copy can legitimately carry two
        // same-named files from different folders.
        let filenames = Self.deduplicatedFilenames(items.map(\.filename))
        let manifestItems = zip(items, filenames).map { item, filename in
            FileProviderManifest.Item(
                sessionSalt: sessionSalt, generation: generation, repIndex: item.repIndex,
                filename: filename, byteCount: item.byteCount, uti: item.uti)
        }
        let manifest = FileProviderManifest(generation: generation, items: manifestItems)
        do {
            try container.writeManifest(manifest)
        } catch {
            logger.error(
                "Failed to write File Provider manifest: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        signalEnumerator()
        // Force the dataless placeholder dirents onto disk by making the system
        // enumerate the root. `signalEnumerator` alone only refreshes the index /
        // working set; the on-disk file for a never-browsed child is written only
        // when the root container is actually read (a `readdir`). Without this the
        // pasteboard URL points at a path that doesn't exist, so a paste fails with
        // ENOENT before the kernel's dataless trap can call `fetchContents`.
        if waitForPlaceholder {
            // Paste-time publish (#427 leading edge): the caller is about to hand
            // the URLs to a consumer that resolves them immediately, so wait for
            // the enumeration round-trip here — normally metadata-only,
            // millisecond-scale work. The wait is BOUNDED: a hung fileproviderd
            // must not strand the caller's (main) thread past the paste deadline,
            // so a timeout degrades to the size-capped sync path (`nil`) instead
            // of blocking indefinitely — the enumeration itself never calls back
            // into this process (the extension reads the manifest from the shared
            // container), so the bound is purely defensive. Then verify the
            // dirents actually landed: a `nil` return on a missing dirent also
            // degrades to the sync path instead of advertising a URL that would
            // ENOENT.
            guard enumerateRootBounded(root: rootURL) else {
                logger.warning(
                    "FP publish timed out waiting for the root enumeration — using sync path")
                return nil
            }
            let missing = filenames.filter {
                !FileManager.default.fileExists(atPath: rootURL.appendingPathComponent($0).path)
            }
            guard missing.isEmpty else {
                logger.warning(
                    "FP publish enumerated but \(missing.count, privacy: .public) placeholder(s) missing — using sync path"
                )
                return nil
            }
        } else {
            // Offer-time publish: the offer→paste gap (the user switches and
            // pastes) is far longer than the listing, so run the readdir off-main.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.enumerateRoot(root: rootURL)
            }
        }
        var urls: [Int: URL] = [:]
        for (item, filename) in zip(items, filenames) {
            urls[item.repIndex] = rootURL.appendingPathComponent(filename)
        }
        logger.info(
            "FP published \(items.count, privacy: .public) item(s) (gen=\(generation, privacy: .public))"
        )
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

    /// Upper bound on the paste-time wait for the root enumeration.
    ///
    /// Generous against the normal millisecond-scale round-trip (it covers a
    /// cold extension launch), yet comfortably inside Finder's ~60 s paste
    /// deadline with headroom left for the sync fallback the timeout degrades
    /// to.
    private static let placeholderEnumerationWait: TimeInterval = 15

    /// Runs `enumerateRoot` off-queue and waits up to
    /// `placeholderEnumerationWait` for it to finish.
    ///
    /// Returns `false` on timeout; the readdir then completes (or hangs)
    /// harmlessly on its background thread and is not retried.
    private func enumerateRootBounded(root: URL) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.enumerateRoot(root: root)
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + Self.placeholderEnumerationWait) == .success
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
