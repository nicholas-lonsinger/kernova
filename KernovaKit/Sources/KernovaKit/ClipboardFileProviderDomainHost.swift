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
    /// off (`-2011`); large-file paste falls back to the deadline-prone path.
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
    /// Raw value of `NSFileProviderError.Code.domainDisabled` (user toggle off).
    ///
    /// Compared by raw value so a newer SDK symbol isn't required.
    private static let domainDisabledCode = -2011

    /// How often availability is re-checked while enabled, so the user flipping
    /// the System-Settings toggle takes effect without restarting the owner.
    private static let availabilityPollInterval: TimeInterval = 3

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

    // MARK: Main-queue state

    private var relayServingStarted = false
    private var enabled = false
    private var domainRegistered = false
    /// User-visible domain root, resolved after registration; `nil` until then
    /// (the File Provider path is unused while it's `nil`).
    private var rootURL: URL?
    private var availabilityStorage: ClipboardFileProviderAvailability = .inactive
    /// Re-checks `availabilityStorage` while enabled so a live toggle change is
    /// reflected without a restart.
    private var availabilityPollTimer: DispatchSourceTimer?

    /// Current File Provider usability, for the UI.
    ///
    /// Read on main.
    public var availability: ClipboardFileProviderAvailability {
        dispatchPrecondition(condition: .onQueue(.main))
        return availabilityStorage
    }

    /// Creates a domain host for one direction, pulling bytes through
    /// `pullProvider` when the extension reads a placeholder, and vending the
    /// relay through `relayTransport` (Mach listener for the guest, broker for the
    /// host).
    public init(
        config: ClipboardFileProviderConfig,
        pullProvider: ClipboardFileProviderPullProvider,
        relayTransport: ClipboardFileProviderRelayTransport
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
        super.init()
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
            startRelayServingIfNeeded()
            registerDomain()
            startAvailabilityPolling()
        } else {
            stopAvailabilityPolling()
            availabilityStorage = .inactive
            // Keep the domain registered across a policy off→on cycle: re-adding a
            // domain re-creates it in the consent-gated OFF state, which would wipe
            // the user's System-Settings enablement on every restart. Just clear
            // the offer's items so nothing lingers.
            clearOfferOnMain()
            logger.notice("File Provider disabled by clipboard policy")
        }
    }

    /// Polls availability for the whole enabled lifetime, including while `.ready`.
    ///
    // RATIONALE: this is deliberately a continuous poll, not just a wait for the
    // user to flip the toggle ON. `publishSingleFile` is synchronous and decides
    // File-Provider-vs-sync-fallback purely from the cached `availabilityStorage`;
    // it never re-probes (it can't await an async `signalEnumerator`). So the poll
    // is the *only* thing that refreshes the cache during a session — keeping it
    // running while `.ready` is what lets a user *disabling* the File-Providers
    // toggle mid-session be detected, so the next paste falls back to the sync path
    // instead of publishing a placeholder into a now-disabled domain. (Backing the
    // poll off to a longer interval once `.ready` is a fair future optimization;
    // stopping it entirely is not — it would regress the mid-session disable case.)
    private func startAvailabilityPolling() {
        guard availabilityPollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + Self.availabilityPollInterval,
            repeating: Self.availabilityPollInterval)
        timer.setEventHandler { [weak self] in self?.refreshAvailability() }
        timer.resume()
        availabilityPollTimer = timer
    }

    private func stopAvailabilityPolling() {
        availabilityPollTimer?.cancel()
        availabilityPollTimer = nil
    }

    /// Lazily begins vending the relay through the injected transport.
    ///
    /// Deferred to first enable so a team-prefixed Mach listener / broker
    /// registration never starts in a context that didn't enable clipboard
    /// sharing (notably the CI test host).
    private func startRelayServingIfNeeded() {
        guard !relayServingStarted else { return }
        relayServingStarted = true
        relayTransport.startServing(relayService)
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
                    self.availabilityStorage = .unavailable
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

    /// Re-checks whether the user has enabled the extension by issuing a no-op
    /// `signalEnumerator`: `-2011` means the per-extension File-Providers toggle
    /// is off; success means enabled; any other error means an install/launch
    /// problem.
    ///
    /// Called on registration and on the availability poll timer, so flipping the
    /// toggle in System Settings takes effect within `availabilityPollInterval`
    /// without restarting the owner. Logs every transition for diagnosis.
    private func refreshAvailability() {
        guard let manager = NSFileProviderManager(for: domain) else {
            availabilityStorage = .unavailable
            return
        }
        manager.signalEnumerator(for: .rootContainer) { [weak self] error in
            let availability = Self.availability(from: error)
            DispatchQueue.main.async {
                guard let self, self.enabled else { return }
                let previous = self.availabilityStorage
                self.availabilityStorage = availability
                if availability != previous {
                    self.logger.notice(
                        "File Provider availability: \(String(describing: availability), privacy: .public)"
                    )
                }
            }
        }
    }

    /// Maps a `signalEnumerator` completion error to availability: no error =
    /// enabled (`.ready`), `-2011` = the user toggle is off (`.needsEnabling`),
    /// anything else = an install/launch problem (`.unavailable`).
    ///
    /// `internal` (not `private`) so `KernovaKitTests` can lock the hard-coded
    /// `-2011` mapping against SDK drift.
    static func availability(from error: Error?) -> ClipboardFileProviderAvailability {
        guard let error = error as NSError? else { return .ready }
        if error.domain == NSFileProviderErrorDomain, error.code == Self.domainDisabledCode {
            return .needsEnabling
        }
        return .unavailable
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
    private func signalEnumerator() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .workingSet) { _ in }
        manager.signalEnumerator(for: .rootContainer) { _ in }
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
