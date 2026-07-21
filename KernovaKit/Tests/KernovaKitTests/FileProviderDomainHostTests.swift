import FileProvider
import Foundation
import Testing
import KernovaTestSupport

@testable import KernovaKit

@Suite("FileProviderDomainHost availability mapping")
struct FileProviderDomainHostAvailabilityTests {
    @Test("userEnabled == true maps to .ready")
    func userEnabledIsReady() {
        #expect(FileProviderDomainHost.availability(userEnabled: true) == .ready)
    }

    @Test("userEnabled == false maps to .needsEnabling (the System-Settings toggle is off)")
    func userDisabledIsNeedsEnabling() {
        // Locks the authoritative mapping: a registered-but-disabled domain must
        // route paste to the size-capped sync fallback, not publish a placeholder
        // the disabled extension can never materialize.
        #expect(FileProviderDomainHost.availability(userEnabled: false) == .needsEnabling)
    }

    @Test("a lookup error maps to .unavailable")
    func lookupErrorIsUnavailable() {
        let error = NSError(domain: NSFileProviderErrorDomain, code: -1004)
        #expect(
            FileProviderDomainHost.availability(
                forDomainMatching: NSFileProviderDomainIdentifier("any"), in: [], error: error)
                == .unavailable)
    }

    @Test("a missing domain maps to .unavailable")
    func missingDomainIsUnavailable() {
        let other = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier("other"), displayName: "Other")
        #expect(
            FileProviderDomainHost.availability(
                forDomainMatching: NSFileProviderDomainIdentifier("wanted"), in: [other], error: nil)
                == .unavailable)
    }

    @Test("a matching domain delegates to its userEnabled flag")
    func matchingDomainDelegatesToUserEnabled() {
        // `userEnabled` is read-only, so we can't force a value on a constructed
        // domain — assert the lookup finds the match and routes through the
        // userEnabled mapping (proving identity matching + delegation), rather
        // than pinning a specific default.
        let identifier = NSFileProviderDomainIdentifier("matched")
        let domain = NSFileProviderDomain(identifier: identifier, displayName: "Matched")
        #expect(
            FileProviderDomainHost.availability(
                forDomainMatching: identifier, in: [domain], error: nil)
                == FileProviderDomainHost.availability(userEnabled: domain.userEnabled))
    }

    // MARK: - Orphan-diagnostic error gate (the deferred-heal breadcrumb)

    @Test("isFileExistsError detects a top-level NSFileWriteFileExistsError")
    func fileExistsErrorTopLevel() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        #expect(FileProviderDomainHost.isFileExistsError(error))
    }

    @Test("isFileExistsError walks the NSUnderlyingErrorKey chain")
    func fileExistsErrorNested() {
        let underlying = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError)
        let middle = NSError(
            domain: "Intermediate", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
        let wrapper = NSError(
            domain: NSFileProviderErrorDomain, code: -2001,
            userInfo: [NSUnderlyingErrorKey: middle])
        #expect(FileProviderDomainHost.isFileExistsError(wrapper))
    }

    @Test("isFileExistsError is false for an unrelated error")
    func fileExistsErrorUnrelated() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)
        #expect(!FileProviderDomainHost.isFileExistsError(error))
    }
}

// MARK: - Enablement / notification wiring

/// Exercises the state-first registration cycle and the availability wiring.
///
/// `setEnabled(true)` installs the `NSFileProviderDomainDidChange` observer, then
/// runs `registerDomain()`, whose one authoritative `domains()` read (the injected
/// `fetchDomains`) both arms the notification and decides the action: an
/// already-present domain is *adopted* (no `add`); a genuinely absent domain is
/// *added once*; a read that *throws* lands `.unavailable`. Availability is applied
/// by `refreshAvailability()`, which re-reads `fetchDomains` — so `domainSource
/// .callCount` reflects the state read plus any confirm/refresh reads, and tests
/// use gates on the observed availability rather than pinning exact read counts.
///
/// `addDomainToSystem` is injected via `FakeAddDomain` (which, on success, appends
/// the added domain into its linked `FakeDomainSource` so the confirm read sees
/// it). Tests that seed a *present* domain never invoke `add` at all, so they don't
/// depend on the real, non-stubbable `NSFileProviderManager.add`. Every fake domain
/// identifier is a fresh UUID so parallel tests can't collide.
@Suite("FileProviderDomainHost enablement & availability wiring")
@MainActor
struct FileProviderDomainHostEnablementTests {
    // MARK: - Fakes

    /// Stands in for `NSFileProviderManager.domains()`.
    ///
    /// Returns the current `setResult` value, or — while a scripted
    /// `enqueueResults` queue is non-empty — the next queued result, so a test can
    /// drive the HOP-1 read and the confirm read independently. `append` models
    /// `domains()` listing a domain after a successful `add`. `gate` fires on every
    /// read so a test can await a specific call count without polling.
    private final class FakeDomainSource: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[NSFileProviderDomain], Error> = .success([])
        private var queue: [Result<[NSFileProviderDomain], Error>] = []
        private var callCountStorage = 0
        /// Parks the first `fetch` on a continuation until `releaseHeldRead()`,
        /// when armed.
        ///
        /// The first `fetch` also signals `readStartedGate`, so the
        /// retry-cancellation test can deterministically disable the host while
        /// the enable-time read is still outstanding. Off by default, so every
        /// other test is unchanged.
        private var holdFirstReadArmed = false
        private var heldReadContinuation: CheckedContinuation<Void, Never>?
        /// Set when `releaseHeldRead()` runs before the held read has stored its
        /// continuation, so the read resumes immediately instead of parking
        /// forever (the release would otherwise find `nil` and no-op, stranding
        /// the read and leaking its continuation).
        private var heldReadReleased = false
        let gate = AsyncGate()
        let readStartedGate = AsyncGate()

        var callCount: Int { lock.withLock { callCountStorage } }

        func setResult(_ result: Result<[NSFileProviderDomain], Error>) {
            lock.withLock { self.result = result }
        }

        func armHoldFirstRead() { lock.withLock { holdFirstReadArmed = true } }

        func releaseHeldRead() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                heldReadReleased = true
                let captured = heldReadContinuation
                heldReadContinuation = nil
                return captured
            }
            continuation?.resume()
        }

        /// Scripts the next reads in order; once exhausted, `fetch` falls back to
        /// the current `setResult` value.
        func enqueueResults(_ results: [Result<[NSFileProviderDomain], Error>]) {
            lock.withLock { queue = results }
        }

        /// Appends a domain to the current success value (models a post-`add`
        /// `domains()` listing).
        ///
        /// A no-op ordering-wise: callers append under the lock before the add
        /// completion runs, so the confirm read can't miss it.
        func append(_ domain: NSFileProviderDomain) {
            lock.withLock {
                switch result {
                case .success(let domains): result = .success(domains + [domain])
                case .failure: result = .success([domain])
                }
            }
        }

        func fetch() async throws -> [NSFileProviderDomain] {
            let (outcome, shouldHold) = lock.withLock {
                () -> (Result<[NSFileProviderDomain], Error>, Bool) in
                callCountStorage += 1
                let hold = holdFirstReadArmed && callCountStorage == 1
                if hold { holdFirstReadArmed = false }
                let next = queue.isEmpty ? result : queue.removeFirst()
                return (next, hold)
            }
            gate.notify()
            if shouldHold {
                readStartedGate.notify()
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    // Resume inline when the release already happened: storing the
                    // continuation for a release that has come and gone would park
                    // this read forever.
                    let alreadyReleased = lock.withLock { () -> Bool in
                        guard !heldReadReleased else { return true }
                        heldReadContinuation = continuation
                        return false
                    }
                    if alreadyReleased { continuation.resume() }
                }
            }
            return try outcome.get()
        }
    }

    /// Records every value `setAvailabilityObserver` delivers, thread-safely.
    ///
    /// A test's `AsyncGate` predicates read `values` off-main (the gate's
    /// continuation can resume on any cooperative-pool thread), so this must not
    /// go through the host's own `availability`/`setAvailabilityObserver` — both
    /// assert `dispatchPrecondition(.onQueue(.main))`, which a predicate invoked
    /// off-main would trip.
    private final class AvailabilityCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var valuesStorage: [FileProviderAvailability] = []
        let gate = AsyncGate()

        func record(_ value: FileProviderAvailability) {
            lock.withLock { valuesStorage.append(value) }
            gate.notify()
        }

        var values: [FileProviderAvailability] { lock.withLock { valuesStorage } }
    }

    /// Never asked to pull a file in these tests (none call `publishItems`
    /// on a usable domain), so a fixed failure reply is fine.
    private final class NeverCalledPullProvider: FileProviderPullProvider,
        @unchecked Sendable
    {
        func fetchStagedFile(
            generation: UInt64, repIndex: Int,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            .failure(.noCurrentOffer)
        }

        func cancelStagedPull(generation: UInt64, repIndex: Int) {
            Issue.record("cancelStagedPull should never be called in these availability-wiring tests")
        }

        func fetchStagedChild(
            generation: UInt64, repIndex: Int, childSeq: UInt32, relativePath: String,
            onProgress: @escaping @Sendable (UInt64, UInt64) -> Void
        ) -> Result<String, FileProviderPullError> {
            .failure(.noCurrentOffer)
        }

        func cancelStagedChildPull(generation: UInt64, repIndex: Int, childSeq: UInt32) {
            Issue.record(
                "cancelStagedChildPull should never be called in these availability-wiring tests")
        }
    }

    /// No-op transport — these tests exercise availability wiring, not the relay
    /// servicing path, so `startServing`/`stopServing`/`ensureConnected` need no
    /// real anonymous-XPC connection.
    private final class NoOpRelayTransport: FileProviderRelayTransport,
        @unchecked Sendable
    {
        func startServing(_ service: FileProviderRelay) {}
        func stopServing() {}
        func ensureConnected() {}
    }

    /// Counts `ensureConnected()` calls (notifying `gate` on each) so a test can
    /// assert the registration-time servicing warm-up fires exactly on the
    /// register (adopt or add-success) paths and never on failure.
    private final class RecordingRelayTransport: FileProviderRelayTransport,
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var ensureConnectedCountStorage = 0
        let gate = AsyncGate()

        var ensureConnectedCount: Int { lock.withLock { ensureConnectedCountStorage } }

        func startServing(_ service: FileProviderRelay) {}
        func stopServing() {}
        func ensureConnected() {
            lock.withLock { ensureConnectedCountStorage += 1 }
            gate.notify()
        }
    }

    private struct FakeFetchError: Error {}

    /// Stands in for `NSFileProviderManager.add(domain:completionHandler:)`.
    ///
    /// Fails the first `failCount` calls (with `makeError`), then succeeds. On a
    /// successful add it appends the domain into `appendingTo` — synchronously,
    /// under that source's lock, before the completion runs — so the confirm read
    /// deterministically sees the just-added domain. In `hold` mode it captures the
    /// (success-path) completion instead of firing it, so a test can disable the
    /// host mid-registration and then `releaseHeld()` a now-stale completion; the
    /// release runs on a private serial queue so `drainToMain()` can await the
    /// stale completion's main-hop deterministically.
    private final class FakeAddDomain: @unchecked Sendable {
        private let lock = NSLock()
        private let failCount: Int
        private let linkedSource: FakeDomainSource?
        private let hold: Bool
        private let makeError: @Sendable (Int) -> Error
        private var callCountStorage = 0
        private var heldCompletion: (@Sendable (Error?) -> Void)?
        private let releaseQueue = DispatchQueue(label: "app.kernova.test.fakeadd.release")
        let addCalledGate = AsyncGate()

        init(
            failCount: Int,
            appendingTo linkedSource: FakeDomainSource? = nil,
            hold: Bool = false,
            makeError: @escaping @Sendable (Int) -> Error = {
                NSError(domain: "FakeAddDomain", code: $0)
            }
        ) {
            self.failCount = failCount
            self.linkedSource = linkedSource
            self.hold = hold
            self.makeError = makeError
        }

        var callCount: Int { lock.withLock { callCountStorage } }

        func add(_ domain: NSFileProviderDomain, completion: @escaping @Sendable (Error?) -> Void) {
            let thisCall = lock.withLock {
                callCountStorage += 1
                return callCountStorage
            }
            let error: Error? = thisCall <= failCount ? makeError(thisCall) : nil
            if error == nil { linkedSource?.append(domain) }
            if hold {
                // Hold mode is used only for the success path; the completion is
                // fired with `nil` on `releaseHeld()`.
                lock.withLock { heldCompletion = completion }
                addCalledGate.notify()
                return
            }
            DispatchQueue.global().async { completion(error) }
        }

        func releaseHeld() {
            let held = lock.withLock { () -> (@Sendable (Error?) -> Void)? in
                let captured = heldCompletion
                heldCompletion = nil
                return captured
            }
            if let held { releaseQueue.async { held(nil) } }
        }

        /// Resumes after any block enqueued on `releaseQueue` before this call has
        /// run *and* its resulting main-queue hop has drained — so a test knows a
        /// released stale completion has been fully processed.
        func drainToMain() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                releaseQueue.async { DispatchQueue.main.async { continuation.resume() } }
            }
        }
    }

    // MARK: - Helpers

    private func makeHost(
        domainIdentifier: String, domainSource: FakeDomainSource,
        notificationCenter: NotificationCenter,
        addDomain: FakeAddDomain? = nil,
        relayTransport: FileProviderRelayTransport? = nil,
        waitForStabilization: (@Sendable (@escaping @Sendable (Error?) -> Void) -> Void)? = nil,
        registrationReadRetryLimit: Int = 12,
        registrationReadRetryDelay: TimeInterval = 5
    ) -> FileProviderDomainHost {
        let config = FileProviderConfig(
            appGroupIdentifier: "8MT4P4GZL2.app.kernova.test",
            serviceName: NSFileProviderServiceName("app.kernova.clipboard.test.relay"),
            reconnectNotificationName: "app.kernova.clipboard.test.reconnect",
            domainIdentifier: domainIdentifier,
            domainDisplayName: "Kernova Clipboard (Test)",
            containerDirectoryName: "FileProviderTest",
            loggerSubsystem: "app.kernova.test",
            extensionLoggerSubsystem: "app.kernova.test.fileprovider",
            ownerCodeSigningRequirement: nil,
            extensionCodeSigningRequirement: nil)
        // The stabilization seam defaults to an immediate no-op success so
        // tests that don't observe the flush never wait on the real
        // fileproviderd barrier.
        let stabilization = waitForStabilization ?? { completion in completion(nil) }
        if let addDomain {
            return FileProviderDomainHost(
                config: config,
                pullProvider: NeverCalledPullProvider(),
                relayTransport: relayTransport ?? NoOpRelayTransport(),
                notificationCenter: notificationCenter,
                fetchDomains: { try await domainSource.fetch() },
                addDomainToSystem: { domain, completion in addDomain.add(domain, completion: completion) },
                waitForStabilization: stabilization,
                registrationReadRetryLimit: registrationReadRetryLimit,
                registrationReadRetryDelay: registrationReadRetryDelay)
        }
        return FileProviderDomainHost(
            config: config,
            pullProvider: NeverCalledPullProvider(),
            relayTransport: relayTransport ?? NoOpRelayTransport(),
            notificationCenter: notificationCenter,
            fetchDomains: { try await domainSource.fetch() },
            waitForStabilization: stabilization,
            registrationReadRetryLimit: registrationReadRetryLimit,
            registrationReadRetryDelay: registrationReadRetryDelay)
    }

    private func matchingDomain(_ identifier: String) -> NSFileProviderDomain {
        NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(identifier), displayName: "Test")
    }

    /// Suspends until every block enqueued on the main queue before this call has
    /// run — used right after `setEnabled` (itself dispatched to main) so
    /// `applyEnabledOnMain` has deterministically finished before a test proceeds.
    private func awaitMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Core state-first behavior

    @Test("an already-present domain is adopted (never re-added) and reported from its userEnabled flag")
    func presentDomainAdoptedWithoutAdding() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        let matching = matchingDomain(identifierString)
        domainSource.setResult(.success([matching]))
        let collector = AvailabilityCollector()
        let transport = RecordingRelayTransport()
        // failCount 100: if `add` were ever (wrongly) called, it would fail — but a
        // present domain must be adopted, so it must never be called at all.
        let addDomain = FakeAddDomain(failCount: 100)
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: NotificationCenter(), addDomain: addDomain, relayTransport: transport)
        host.setAvailabilityObserver { collector.record($0) }
        #expect(collector.values == [.inactive])

        host.setEnabled(true)

        // Adopt → availability delegates to the (read-only, false) userEnabled flag.
        try await collector.gate.wait {
            collector.values.contains(FileProviderDomainHost.availability(userEnabled: matching.userEnabled))
        }
        #expect(collector.values.contains(.needsEnabling))
        #expect(addDomain.callCount == 0, "a present domain must be adopted, never re-added")
        try await transport.gate.wait { transport.ensureConnectedCount == 1 }
    }

    @Test("re-enabling an already-present domain never re-adds it")
    func repeatEnablePresentNeverReAdds() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        domainSource.setResult(.success([matchingDomain(identifierString)]))
        let collector = AvailabilityCollector()
        let addDomain = FakeAddDomain(failCount: 100)
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: NotificationCenter(), addDomain: addDomain)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)
        try await collector.gate.wait { collector.values.contains(.needsEnabling) }
        host.setEnabled(false)
        await awaitMainQueueTurn()
        host.setEnabled(true)
        try await collector.gate.wait {
            collector.values.filter { $0 == .needsEnabling }.count >= 2
        }

        #expect(
            addDomain.callCount == 0,
            "an already-present domain must never be re-added across enables")
    }

    @Test("a present domain with a different identifier is not adopted — ours is treated as absent and added")
    func nonMatchingDomainTreatedAsAbsent() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        // A domain is present, but NOT ours — identity matching must treat ours as
        // absent and add it (rather than adopt a stranger's domain).
        domainSource.setResult(
            .success([matchingDomain("other-\(UUID().uuidString)")]))
        let collector = AvailabilityCollector()
        let addDomain = FakeAddDomain(failCount: 0, appendingTo: domainSource)
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: NotificationCenter(), addDomain: addDomain)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        try await collector.gate.wait { collector.values.contains(.needsEnabling) }
        #expect(
            addDomain.callCount == 1,
            "our domain must be added, not confused with the other-identifier domain")
    }

    @Test("an absent domain is added once, then confirmed and reported .needsEnabling")
    func absentDomainAddedThenConfirmed() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()  // empty → absent at the HOP-1 read
        let collector = AvailabilityCollector()
        let transport = RecordingRelayTransport()
        let addDomain = FakeAddDomain(failCount: 0, appendingTo: domainSource)
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: NotificationCenter(), addDomain: addDomain, relayTransport: transport)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        try await collector.gate.wait { collector.values.contains(.needsEnabling) }
        #expect(addDomain.callCount == 1)
        try await transport.gate.wait { transport.ensureConnectedCount == 1 }
    }

    @Test("a failed registry read reports .unavailable and never blindly adds")
    func readFailureReportsUnavailableWithoutAdding() async throws {
        let domainSource = FakeDomainSource()
        domainSource.setResult(.failure(FakeFetchError()))
        let collector = AvailabilityCollector()
        let addDomain = FakeAddDomain(failCount: 0, appendingTo: domainSource)
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: NotificationCenter(), addDomain: addDomain)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        try await collector.gate.wait(timeout: .seconds(20)) { collector.values.contains(.unavailable) }
        #expect(
            addDomain.callCount == 0,
            "a failed registry read means the state is unknown — it must not blindly add")
    }

    @Test("add succeeds but the confirm read throws — the domain stays registered and availability recovers")
    func addSucceedsButConfirmThrowsStaysRegistered() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        // HOP-1 read absent (→ add), then the confirm read throws.
        domainSource.enqueueResults([.success([]), .failure(FakeFetchError())])
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        // Success add, but do NOT append — the confirm read throws instead.
        let addDomain = FakeAddDomain(failCount: 0)
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: center, addDomain: addDomain)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        // add success → domainRegistered = true → confirm read throws → .unavailable.
        try await collector.gate.wait(timeout: .seconds(20)) { collector.values.contains(.unavailable) }
        #expect(
            host.domainRegisteredForTesting,
            "a throwing confirm read must not clear domainRegistered (would wedge publish)")

        // Recovery: the registry becomes readable; a domain-change notification
        // re-probes and reports the true state.
        domainSource.setResult(.success([matchingDomain(identifierString)]))
        center.post(name: .fileProviderDomainDidChange, object: nil)
        try await collector.gate.wait(timeout: .seconds(20)) { collector.values.contains(.needsEnabling) }
    }

    // MARK: - Servicing warm-up + failure handling

    @Test("registration success warms the servicing connection")
    func registrationSuccessWarmsServicingConnection() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        let transport = RecordingRelayTransport()
        let host = makeHost(
            domainIdentifier: identifierString,
            domainSource: domainSource,
            notificationCenter: NotificationCenter(),
            addDomain: FakeAddDomain(failCount: 0, appendingTo: domainSource),
            relayTransport: transport)

        host.setEnabled(true)

        try await transport.gate.wait { transport.ensureConnectedCount == 1 }
    }

    @Test("a failed registration doesn't warm the servicing connection, and is not retried")
    func failedRegistrationDoesNotWarmServicingConnection() async throws {
        let domainSource = FakeDomainSource()  // stays empty → absent
        let collector = AvailabilityCollector()
        let transport = RecordingRelayTransport()
        // Fails and never appends → the domain remains absent.
        let addDomain = FakeAddDomain(failCount: 1)
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)", domainSource: domainSource,
            notificationCenter: NotificationCenter(),
            addDomain: addDomain,
            relayTransport: transport)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        try await collector.gate.wait(timeout: .seconds(20)) {
            collector.values.contains(.unavailable)
        }
        #expect(
            transport.ensureConnectedCount == 0,
            "a failed registration must not request a connect")

        // Standing in for a real paste: finds the domain unregistered and falls
        // back (returns nil) — must not trigger any re-registration.
        let published = host.publishItems(
            generation: 1,
            items: [
                FileProviderPublishItem(
                    repIndex: 0, filename: "test.txt", byteCount: 10, uti: "public.data")
            ],
            folders: [],
            waitForPlaceholder: true)
        #expect(published == nil)

        #expect(
            addDomain.callCount == 1,
            "a failed registration must not be re-added by a subsequent paste")
    }

    // MARK: - Notification wiring / churn

    @Test("enabling performs the authoritative domains() read that arms the change notification")
    func enablePerformsAuthoritativeRead() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        // Present → adopt, so the real NSFileProviderManager.add is never touched;
        // the point is only that the read happens at enable.
        domainSource.setResult(.success([matchingDomain(identifierString)]))
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: NotificationCenter())

        host.setEnabled(true)

        try await domainSource.gate.wait(timeout: .seconds(20)) { domainSource.callCount >= 1 }
    }

    @Test("posting the domain-change notification while enabled re-probes via fetchDomains and applies the result")
    func notificationTriggersRefetchWhileEnabled() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        // Present before enable → HOP-1 adopts (no add), landing .needsEnabling.
        domainSource.setResult(.success([matchingDomain(identifierString)]))
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource, notificationCenter: center)
        host.setAvailabilityObserver { collector.record($0) }
        #expect(collector.values == [.inactive])

        host.setEnabled(true)
        try await collector.gate.wait { collector.values.contains(.needsEnabling) }

        // Change what the next probe reports, then trigger a re-probe via the
        // notification — proves it drives a fresh `fetchDomains` each time.
        domainSource.setResult(.failure(FakeFetchError()))
        let callsBeforeSecondProbe = domainSource.callCount
        center.post(name: .fileProviderDomainDidChange, object: nil)
        try await collector.gate.wait { domainSource.callCount > callsBeforeSecondProbe }

        // `.needsEnabling` → `.unavailable` is a real transition, so an
        // `.unavailable` strictly after the `.needsEnabling` entry is this second,
        // error-driven probe.
        let needsEnablingIndex = try #require(collector.values.firstIndex(of: .needsEnabling))
        try await collector.gate.wait {
            collector.values[(needsEnablingIndex + 1)...].contains(.unavailable)
        }
    }

    @Test("posting the domain-change notification while never enabled has no effect")
    func notificationIgnoredWhileNeverEnabled() {
        let domainSource = FakeDomainSource()
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: center)
        host.setAvailabilityObserver { collector.record($0) }
        #expect(collector.values == [.inactive])

        center.post(name: .fileProviderDomainDidChange, object: nil)

        // `setEnabled` was never called, so no observer is registered on `center`
        // and `registerDomain()` never ran — nothing to deliver, nothing to read.
        #expect(collector.values == [.inactive])
        #expect(domainSource.callCount == 0)
        #expect(host.availability == .inactive)
    }

    @Test("disabling mid-registration leaves availability .inactive — a stale add completion is a no-op")
    func disableMidRegistrationLandsInactive() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()  // empty → absent → triggers add
        let collector = AvailabilityCollector()
        let transport = RecordingRelayTransport()
        // Hold the (success) add completion so we can disable while it's in flight.
        let addDomain = FakeAddDomain(failCount: 0, hold: true)
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: NotificationCenter(), addDomain: addDomain, relayTransport: transport)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)
        // Wait until the add is in flight (held) — we're mid-registration.
        try await addDomain.addCalledGate.wait(timeout: .seconds(20)) { addDomain.callCount >= 1 }

        // Disable while the add is still outstanding.
        host.setEnabled(false)
        await awaitMainQueueTurn()
        #expect(host.availability == .inactive)
        let valuesAfterDisable = collector.values

        // Release the now-stale add completion and wait for its main-hop to drain.
        addDomain.releaseHeld()
        await addDomain.drainToMain()

        #expect(host.availability == .inactive)
        #expect(
            collector.values == valuesAfterDisable,
            "a stale add completion after disable must not write availability")
        #expect(
            transport.ensureConnectedCount == 0,
            "a superseded registration must not warm the servicing connection")
    }

    @Test("disabling stops observing the domain-change notification; a later post is a no-op")
    func disablingStopsObservingDomainChanges() async throws {
        let domainSource = FakeDomainSource()
        // A failing read makes the enable land on `.unavailable` deterministically.
        domainSource.setResult(.failure(FakeFetchError()))
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: center)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)
        await awaitMainQueueTurn()

        // Let the (failing) registration land before disabling.
        try await collector.gate.wait(timeout: .seconds(20)) {
            collector.values.contains(.unavailable)
        }

        host.setEnabled(false)
        await awaitMainQueueTurn()
        #expect(host.availability == .inactive)

        let valuesBeforePost = collector.values
        let callsBeforePost = domainSource.callCount
        center.post(name: .fileProviderDomainDidChange, object: nil)

        // `setEnabled(false)` ran `stopObservingDomainChanges()`, so the observer is
        // gone before this post — nothing to deliver to, hence a synchronous assert.
        #expect(collector.values == valuesBeforePost)
        #expect(domainSource.callCount == callsBeforePost)
    }

    // MARK: - Enable-time registry-read retry (#598)

    @Test("a throwing enable-time read is retried, and a later success registers the domain")
    func readFailureRetriesThenSucceeds() async throws {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        // Two throwing reads, then an absent read that triggers the add; the add
        // appends the domain, so the post-registration confirm read sees it.
        domainSource.enqueueResults([
            .failure(FakeFetchError()), .failure(FakeFetchError()), .success([]),
        ])
        let collector = AvailabilityCollector()
        let addDomain = FakeAddDomain(failCount: 0, appendingTo: domainSource)
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: NotificationCenter(), addDomain: addDomain,
            registrationReadRetryLimit: 5, registrationReadRetryDelay: 0)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        try await collector.gate.wait { collector.values.contains(.needsEnabling) }
        #expect(host.domainRegisteredForTesting)
        #expect(addDomain.callCount == 1)
        // 3 registration reads (2 throwing + 1 absent→add) + 1 post-registration
        // confirm read from `refreshAvailability`.
        #expect(domainSource.callCount == 4)
    }

    @Test("a persistently throwing read retries up to the limit, then stops at .unavailable")
    func readFailureRetriesThenExhausts() async throws {
        let domainSource = FakeDomainSource()
        domainSource.setResult(.failure(FakeFetchError()))
        let collector = AvailabilityCollector()
        let addDomain = FakeAddDomain(failCount: 0)  // never reached — reads throw
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: NotificationCenter(),
            addDomain: addDomain, registrationReadRetryLimit: 2, registrationReadRetryDelay: 0)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        // limit 2 → 1 initial read + 2 retries = 3 reads, then exhaustion.
        try await domainSource.gate.wait { domainSource.callCount >= 3 }
        // Let the exhausting read's handler run, then confirm the chain stopped.
        await awaitMainQueueTurn()
        #expect(domainSource.callCount == 3, "the retry chain must stop at the limit")
        #expect(host.availability == .unavailable)
        #expect(addDomain.callCount == 0, "a read failure must never add the domain")
    }

    @Test("disabling while the enable-time read is outstanding cancels the retry cycle")
    func disableDuringReadWindowCancelsRetry() async throws {
        let domainSource = FakeDomainSource()
        // The read would fail; but the disable lands first, so its epoch guard
        // makes the completion a no-op — nothing schedules a retry.
        domainSource.setResult(.failure(FakeFetchError()))
        domainSource.armHoldFirstRead()
        let collector = AvailabilityCollector()
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: NotificationCenter(),
            addDomain: FakeAddDomain(failCount: 0), registrationReadRetryDelay: 0)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)
        // Read #1 is now parked mid-flight — we're inside the enable-time read.
        try await domainSource.readStartedGate.wait { domainSource.callCount == 1 }

        host.setEnabled(false)
        await awaitMainQueueTurn()

        // Release the held read: its completion is now for a superseded epoch, so
        // it neither writes availability nor schedules a retry.
        domainSource.releaseHeldRead()
        await awaitMainQueueTurn()
        await awaitMainQueueTurn()

        #expect(domainSource.callCount == 1, "a stale cycle must perform no further read")
        #expect(host.availability == .inactive)
        #expect(!host.domainRegisteredForTesting)
    }

    @Test("re-enabling after an exhausted retry cycle starts a fresh budget")
    func reEnableAfterExhaustionRetriesAgain() async throws {
        let domainSource = FakeDomainSource()
        domainSource.setResult(.failure(FakeFetchError()))
        let collector = AvailabilityCollector()
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: NotificationCenter(),
            addDomain: FakeAddDomain(failCount: 0), registrationReadRetryLimit: 2,
            registrationReadRetryDelay: 0)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)
        // First cycle exhausts at 3 reads (1 initial + 2 retries).
        try await domainSource.gate.wait { domainSource.callCount >= 3 }
        await awaitMainQueueTurn()
        #expect(domainSource.callCount == 3)

        host.setEnabled(false)
        await awaitMainQueueTurn()

        host.setEnabled(true)
        // A re-enable resets the budget, so the cycle retries again: 3 more reads.
        try await domainSource.gate.wait { domainSource.callCount >= 6 }
        await awaitMainQueueTurn()
        #expect(domainSource.callCount == 6, "each enable gets a fresh retry budget")
        #expect(host.availability == .unavailable)
    }

    // MARK: - Clear-path reconciliation flush

    /// Builds a host registered via the adopt path with the stabilization
    /// recorder injected, ready for `clearOffer` to schedule flushes.
    private func makeRegisteredHost(
        recorder: StabilizationRecorder
    ) async throws -> FileProviderDomainHost {
        let identifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        domainSource.setResult(.success([matchingDomain(identifierString)]))
        let collector = AvailabilityCollector()
        let host = makeHost(
            domainIdentifier: identifierString, domainSource: domainSource,
            notificationCenter: NotificationCenter(),
            waitForStabilization: recorder.seam)
        host.setAvailabilityObserver { collector.record($0) }
        host.setEnabled(true)
        try await collector.gate.wait { collector.values.contains(.needsEnabling) }
        return host
    }

    @Test("clearing a registered offer schedules one stabilization flush")
    func clearSchedulesFlush() async throws {
        let recorder = StabilizationRecorder()
        let host = try await makeRegisteredHost(recorder: recorder)

        host.clearOffer()
        try await recorder.gate.wait { recorder.callCount == 1 }
        recorder.completeAll()
    }

    @Test("a clear while a flush is still waiting coalesces instead of stacking a second wait")
    func clearCoalescesInFlightFlush() async throws {
        let recorder = StabilizationRecorder()
        let host = try await makeRegisteredHost(recorder: recorder)

        // First clear parks a flush (the recorder holds its completion).
        host.clearOffer()
        try await recorder.gate.wait { recorder.callCount == 1 }

        // A second clear during the in-flight flush must not start another.
        host.clearOffer()
        #expect(recorder.callCount == 1)

        // Once the flush completes, the next clear schedules a fresh one.
        recorder.completeAll()
        // RATIONALE: the in-flight flag clears on the flush's background thread
        // after the completion fires, with no external signal to await — a
        // sanctioned no-signal poll (docs/TESTING.md) on the DEBUG seam.
        try await waitUntil { !host.clearReconciliationInFlightForTesting }
        host.clearOffer()
        try await recorder.gate.wait { recorder.callCount == 2 }
        recorder.completeAll()
    }
}

@Suite("FileProviderDomainHost filename de-duplication")
struct FileProviderDomainHostFilenameTests {
    @Test("unique names pass through unchanged")
    func uniqueNamesUnchanged() {
        #expect(
            FileProviderDomainHost.deduplicatedFilenames(["a.pdf", "b.pdf"]) == ["a.pdf", "b.pdf"])
    }

    @Test("a colliding name gets a ' (2)' suffix before the extension")
    func collisionSuffixesBeforeExtension() {
        #expect(
            FileProviderDomainHost.deduplicatedFilenames(["report.pdf", "report.pdf"])
                == ["report.pdf", "report (2).pdf"])
    }

    @Test("three-way collisions count up, and a compound extension splits at the last dot")
    func multiCollisionAndCompoundExtension() {
        #expect(
            FileProviderDomainHost.deduplicatedFilenames([
                "archive.tar.gz", "archive.tar.gz", "archive.tar.gz",
            ]) == ["archive.tar.gz", "archive.tar (2).gz", "archive.tar (3).gz"])
    }

    @Test("an extensionless name suffixes at the end")
    func extensionlessCollision() {
        #expect(
            FileProviderDomainHost.deduplicatedFilenames(["Makefile", "Makefile"])
                == ["Makefile", "Makefile (2)"])
    }

    @Test("a de-duplicated name that itself collides with a later original keeps all names unique")
    func generatedNameCollidesWithOriginal() {
        #expect(
            FileProviderDomainHost.deduplicatedFilenames(["a.txt", "a.txt", "a (2).txt"])
                == ["a.txt", "a (2).txt", "a (2) (2).txt"])
    }
}

@Suite("FileProviderDomainHost replica verdict")
struct FileProviderDomainHostReplicaVerdictTests {
    @Test("all expected dirents present with matching identifiers and no extras → verified")
    func allPresentMatching() {
        #expect(
            FileProviderDomainHost.replicaVerdict(
                expected: ["a.pdf": "clipfile.1.5.0", "b.pdf": "clipfile.1.5.1"],
                listedNames: ["a.pdf", "b.pdf"],
                resolvedIdentifiers: ["a.pdf": "clipfile.1.5.0", "b.pdf": "clipfile.1.5.1"])
                == .verified)
    }

    @Test("a missing dirent → missingOrMismatched")
    func missingDirent() {
        #expect(
            FileProviderDomainHost.replicaVerdict(
                expected: ["a.pdf": "clipfile.1.5.0"],
                listedNames: [],
                resolvedIdentifiers: [:])
                == .missingOrMismatched)
    }

    @Test(
        "a same-named dirent resolving to the superseded offer's identifier → missingOrMismatched (the -43 case)"
    )
    func sameNameStaleIdentifier() {
        // The dirent EXISTS by name — a bare existence check passes — but it is
        // still the previous generation's item mid-swap.
        #expect(
            FileProviderDomainHost.replicaVerdict(
                expected: ["ChatGPT.dmg": "clipfile.1.6.0"],
                listedNames: ["ChatGPT.dmg"],
                resolvedIdentifiers: ["ChatGPT.dmg": "clipfile.1.5.0"])
                == .missingOrMismatched)
    }

    @Test("an unresolvable identifier for a listed dirent → missingOrMismatched")
    func unresolvedIdentifier() {
        #expect(
            FileProviderDomainHost.replicaVerdict(
                expected: ["a.pdf": "clipfile.1.5.0"],
                listedNames: ["a.pdf"],
                resolvedIdentifiers: [:])
                == .missingOrMismatched)
    }

    @Test("expected verified but a stale sibling remains → staleExtras with its name")
    func staleSibling() {
        #expect(
            FileProviderDomainHost.replicaVerdict(
                expected: ["b.pdf": "clipfile.1.6.0"],
                listedNames: ["b.pdf", "old.pdf"],
                resolvedIdentifiers: ["b.pdf": "clipfile.1.6.0"])
                == .staleExtras(["old.pdf"]))
    }
}

/// Records `waitForStabilization` invocations and lets a test choose when (or
/// whether) each completes.
final class StabilizationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var callCountStorage = 0
    private var pendingStorage: [@Sendable (Error?) -> Void] = []
    let gate = AsyncGate()

    /// The injectable seam: records the call and parks the completion.
    var seam: @Sendable (@escaping @Sendable (Error?) -> Void) -> Void {
        { [self] completion in
            lock.withLock {
                callCountStorage += 1
                pendingStorage.append(completion)
            }
            gate.notify()
        }
    }

    var callCount: Int { lock.withLock { callCountStorage } }

    /// Completes every parked wait with `error`.
    func completeAll(error: Error? = nil) {
        let pending = lock.withLock {
            let parked = pendingStorage
            pendingStorage = []
            return parked
        }
        for completion in pending { completion(error) }
    }
}
