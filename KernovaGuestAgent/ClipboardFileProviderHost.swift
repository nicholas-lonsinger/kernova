import FileProvider
import Foundation
import KernovaKit

// Guest-side File Provider host (issue #376).
//
// Owns the agent side of the File Provider transport:
//  1. The XPC relay the sandboxed extension calls on `fetchContents` — the
//     extension can't open vsock, so the agent (which does) pulls for it.
//  2. Registration of the clipboard File Provider domain so the system
//     instantiates the extension and surfaces the domain in Finder.
//  3. The offer manifest + `signalEnumerator` that declare the current inbound
//     file rep to the system as a dataless placeholder.
//
// Gated on host clipboard policy: the domain + listener stand up only once
// clipboard sharing is enabled, so the team-prefixed Mach listener never starts
// in a context that didn't enable clipboard (e.g. the CI test host).

// MARK: - Collaboration with the clipboard agent

/// Implemented by the clipboard agent so the relay can pull a file rep.
///
/// Called off-main on the relay's XPC queue when the extension's `fetchContents`
/// asks for the bytes.
protocol ClipboardFileProviderPullProvider: AnyObject, Sendable {
    /// Pulls `(generation, repIndex)` over vsock, stages it into the shared
    /// container, and returns the staged file path (or why it failed).
    func fetchStagedFile(
        generation: UInt64, repIndex: Int
    ) -> Result<String, ClipboardFileProviderPullError>
}

/// Why a relay pull failed, mapped to an `NSFileProviderError` by the relay.
enum ClipboardFileProviderPullError: Error {
    /// `(generation, repIndex)` isn't the current offer, or there's no live
    /// connection — a stale-placeholder read.
    case noCurrentOffer
    /// The vsock pull aborted, timed out, or the host went away mid-transfer.
    case pullFailed
}

/// Implemented by the host so the agent can surface a file rep as a placeholder.
///
/// Lets the clipboard agent publish a single inbound file rep as a dataless
/// placeholder and get its pasteboard URL. Called only on the main queue.
protocol GuestFileProviderPublishing: AnyObject, Sendable {
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

/// What the agent knows about the File Provider's usability, for the status item.
enum GuestFileProviderAvailability: Equatable, Sendable {
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

/// Hosts the agent's File Provider XPC relay, registers the clipboard domain,
/// and publishes the current offer's single file item.
///
/// `@unchecked Sendable`: registration/manifest/availability state is touched
/// only on the main queue; `pullProvider` is an immutable `let` the XPC listener
/// delegate reads off-main.
final class ClipboardFileProviderHost: NSObject, NSXPCListenerDelegate, GuestFileProviderPublishing,
    @unchecked Sendable
{
    private static let logger = KernovaLogger(
        subsystem: "app.kernova.agent", category: "FileProviderHost")

    /// Stable, hard-coded domain identifier (no `/` or `:`, which the framework
    /// reserves for path separators / domain qualifiers).
    private static let domainIdentifier = NSFileProviderDomainIdentifier("kernova-clipboard")
    private static let domainDisplayName = "Kernova Clipboard"

    /// Raw value of `NSFileProviderError.Code.domainDisabled` (user toggle off).
    ///
    /// Compared by raw value so a newer SDK symbol isn't required.
    private static let domainDisabledCode = -2011

    /// How often availability is re-checked while enabled, so the user flipping
    /// the System-Settings toggle takes effect without restarting the agent.
    private static let availabilityPollInterval: TimeInterval = 3

    private let pullProvider: ClipboardFileProviderPullProvider
    private let domain: NSFileProviderDomain

    // MARK: Main-queue state

    private var listener: NSXPCListener?
    private var enabled = false
    private var domainRegistered = false
    /// User-visible domain root, resolved after registration; `nil` until then
    /// (the File Provider path is unused while it's `nil`).
    private var rootURL: URL?
    private var availabilityStorage: GuestFileProviderAvailability = .inactive
    /// Re-checks `availabilityStorage` while enabled so a live toggle change is
    /// reflected without a restart.
    private var availabilityPollTimer: DispatchSourceTimer?

    /// Current File Provider usability, for the status item.
    ///
    /// Read on main.
    var availability: GuestFileProviderAvailability {
        dispatchPrecondition(condition: .onQueue(.main))
        return availabilityStorage
    }

    init(pullProvider: ClipboardFileProviderPullProvider) {
        self.pullProvider = pullProvider
        self.domain = NSFileProviderDomain(
            identifier: Self.domainIdentifier, displayName: Self.domainDisplayName)
        super.init()
    }

    // MARK: - Enablement (host clipboard policy)

    /// Applies a host clipboard-sharing policy update.
    ///
    /// Stands the domain + listener up on enable, tears the domain down on disable.
    func setEnabled(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in self?.applyEnabledOnMain(enabled) }
    }

    private func applyEnabledOnMain(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        if enabled {
            startListenerIfNeeded()
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
            Self.logger.notice("File Provider disabled by host policy")
        }
    }

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

    /// Lazily vends the XPC relay.
    ///
    /// Deferred to first enable so the team-prefixed Mach listener never starts in
    /// a context that didn't enable clipboard sharing (notably the CI test host,
    /// where the service isn't launchd-vended).
    private func startListenerIfNeeded() {
        guard listener == nil else { return }
        let listener = NSXPCListener(machServiceName: ClipboardFileProviderRelayConfig.machServiceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
        Self.logger.notice(
            "File Provider XPC listener started (\(ClipboardFileProviderRelayConfig.machServiceName, privacy: .public))"
        )
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
                    Self.logger.notice(
                        "File Provider replication dir is orphaned; removing domains then retrying add")
                    Self.removeAllDomains { _ in
                        DispatchQueue.main.async { self.addDomain(retryOnExists: false) }
                    }
                    return
                }
                if let failure {
                    Self.logger.error(
                        "Failed to add File Provider domain: \(failure, privacy: .public)")
                    self.domainRegistered = false
                    self.availabilityStorage = .unavailable
                    return
                }
                self.domainRegistered = true
                Self.logger.notice(
                    "File Provider domain registered: \(Self.domainIdentifier.rawValue, privacy: .public)"
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
                    Self.logger.notice("Clipboard domain visible at: \(url.path, privacy: .public)")
                } else if let error {
                    Self.logger.error(
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
    /// without restarting the agent. Logs every transition for diagnosis.
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
                    Self.logger.notice(
                        "File Provider availability: \(String(describing: availability), privacy: .public)"
                    )
                }
            }
        }
    }

    private static func availability(from error: Error?) -> GuestFileProviderAvailability {
        guard let error = error as NSError? else { return .ready }
        if error.domain == NSFileProviderErrorDomain, error.code == Self.domainDisabledCode {
            return .needsEnabling
        }
        return .unavailable
    }

    // MARK: - GuestFileProviderPublishing

    func publishSingleFile(
        generation: UInt64, repIndex: Int, filename: String, byteCount: UInt64, uti: String
    ) -> URL? {
        dispatchPrecondition(condition: .onQueue(.main))
        // Only advertise a placeholder we can actually materialize: a disabled or
        // not-yet-ready domain would leave a paste that never completes, so fall
        // back to the synchronous provider path in those cases.
        guard enabled, domainRegistered, let rootURL else {
            Self.logger.debug(
                "FP publish skipped (enabled=\(self.enabled, privacy: .public), registered=\(self.domainRegistered, privacy: .public), root=\(self.rootURL != nil, privacy: .public)) — using sync path"
            )
            return nil
        }
        guard availabilityStorage == .ready else {
            // The domain is registered but the user hasn't enabled it in System
            // Settings (or the probe hasn't confirmed yet) — fall back so the paste
            // isn't a placeholder that never downloads. The status item prompts.
            Self.logger.notice(
                "FP publish skipped — domain not user-enabled (availability=\(String(describing: self.availabilityStorage), privacy: .public)) — using sync path"
            )
            return nil
        }
        let item = ClipboardFileProviderManifest.Item(
            generation: generation, repIndex: repIndex, filename: filename,
            byteCount: byteCount, uti: uti)
        let manifest = ClipboardFileProviderManifest(generation: generation, items: [item])
        do {
            try ClipboardFileProviderContainer.writeManifest(manifest)
        } catch {
            Self.logger.error(
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
        Self.logger.notice(
            "FP published item (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public)) at \(url.path, privacy: .public)"
        )
        return url
    }

    /// Reads the domain root directory off-main to trigger a root-container
    /// enumeration, which writes the offered item's dataless placeholder to disk.
    ///
    /// Off-main because the `readdir` blocks on the extension's enumeration
    /// round-trip; the offer→paste gap (the user switches to the guest and pastes)
    /// is far longer than the listing, so the placeholder exists by paste time.
    private func forceRootEnumeration(root: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let entries = try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil)
                Self.logger.notice(
                    "Forced root enumeration — \(entries.count, privacy: .public) entr(ies) on disk")
            } catch {
                Self.logger.error(
                    "Root enumeration readdir failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func clearOffer() {
        DispatchQueue.main.async { [weak self] in self?.clearOfferOnMain() }
    }

    private func clearOfferOnMain() {
        // Only touch the manifest if the domain ever published — avoids creating
        // the container in a context where the File Provider is unused.
        guard domainRegistered else { return }
        do {
            try ClipboardFileProviderContainer.writeManifest(.empty)
        } catch {
            Self.logger.debug(
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

    // MARK: - NSXPCListenerDelegate

    func listener(
        _ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ClipboardFileProviderRelay.self)
        newConnection.exportedObject = ClipboardFileProviderRelayService(pullProvider: pullProvider)
        newConnection.resume()
        Self.logger.notice("Accepted File Provider XPC connection")
        return true
    }

    // MARK: - Teardown helpers

    private static func removeAllDomains(_ completion: @escaping @Sendable (Error?) -> Void) {
        NSFileProviderManager.removeAllDomains { error in
            if let error {
                Self.logger.error(
                    "Failed to remove File Provider domains: \(error.localizedDescription, privacy: .public)"
                )
            }
            completion(error)
        }
    }

    /// Removes this app's File Provider domains, blocking until done — for the
    /// `--remove-clipboard-domain` teardown flag so host-side iteration leaves no
    /// lingering Finder location behind.
    static func removeAllDomainsBlocking() {
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
/// Pulls a file rep through the clipboard agent and replies with the staged-file
/// path, never the bytes.
final class ClipboardFileProviderRelayService: NSObject, ClipboardFileProviderRelay {
    private static let logger = KernovaLogger(
        subsystem: "app.kernova.agent", category: "FileProviderRelay")

    private let pullProvider: ClipboardFileProviderPullProvider

    init(pullProvider: ClipboardFileProviderPullProvider) {
        self.pullProvider = pullProvider
        super.init()
    }

    func fetchFile(
        generation: UInt64, repIndex: Int,
        reply: @escaping @Sendable (String?, NSError?) -> Void
    ) {
        Self.logger.notice(
            "Relay fetchFile (gen=\(generation, privacy: .public), rep=\(repIndex, privacy: .public))")
        // Blocks the XPC queue while the agent pulls over vsock — safe, since the
        // File Provider read path has no 60s deadline and the extension's
        // fetchContents is itself blocked on this reply.
        switch pullProvider.fetchStagedFile(generation: generation, repIndex: repIndex) {
        case .success(let path):
            Self.logger.notice("Relay staged \(path, privacy: .public)")
            reply(path, nil)
        case .failure(let error):
            Self.logger.error("Relay fetchFile failed: \(String(describing: error), privacy: .public)")
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
