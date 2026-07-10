import FileProvider
import Foundation
import Testing

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
}

// MARK: - Enablement / notification wiring

/// Exercises the `NSFileProviderDomainDidChange`-observer wiring added to replace
/// the old poll timer: `setEnabled(true)` arms the observer, a post on the
/// injected `notificationCenter` re-probes availability through the injected
/// `fetchDomains`, and a post while never enabled is a no-op.
///
/// `setEnabled(true)` also fires a throwaway, discarded `fetchDomains` read via
/// `primeDomainChangeNotifications()` (issue #448) to arm the real
/// `NSFileProviderDomainDidChange` notification immediately rather than waiting
/// on registration to succeed — so `domainSource.callCount` is no longer
/// guaranteed zero right after enable. That read is gated to fire at most once
/// per host instance (the notification, once armed, stays armed), so a single
/// enable in a fresh test host contributes exactly one extra call. Tests below
/// that care about call count use relative deltas, gate on a specific count, or
/// (for the one-enable-per-test common case) pin the exact expected count.
///
/// `setEnabled(true)` also runs `registerDomain()` → `addDomain(retryOnExists:)`,
/// which calls the injectable `addDomainToSystem` seam (#428) — `makeHost` omits
/// it by default, so most tests below exercise the *real*, non-stubbable
/// `NSFileProviderManager.add(domain)`. In this test process (a bare `swift test`
/// executable, not an app bundle with a registered File Provider extension) that
/// call reliably fails, which is exactly what `registrationFailureReportsUnavailable`
/// below exercises. `pasteRetriesTransientRegistrationFailure` instead injects a
/// `FakeAddDomain` to deterministically exercise the usage-triggered re-registration
/// self-heal that `publishSingleFile` kicks off when it finds the domain
/// unregistered. Every fake domain identifier is a fresh UUID so the (failing)
/// registration attempts from different tests can never collide.
@Suite("FileProviderDomainHost enablement & availability wiring")
@MainActor
struct FileProviderDomainHostEnablementTests {
    // MARK: - Fakes

    /// Stands in for `NSFileProviderManager.domains()`, returning (or throwing)
    /// whatever a test last configured and counting invocations so a test can
    /// tell a probe actually ran. `gate` fires on every `fetch()` call so a test
    /// can wait for a specific call count without polling.
    private final class FakeDomainSource: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[NSFileProviderDomain], Error> = .success([])
        private var callCountStorage = 0
        let gate = AsyncGate()

        var callCount: Int { lock.withLock { callCountStorage } }

        func setResult(_ result: Result<[NSFileProviderDomain], Error>) {
            lock.withLock { self.result = result }
        }

        func fetch() async throws -> [NSFileProviderDomain] {
            let outcome = lock.withLock { () -> Result<[NSFileProviderDomain], Error> in
                callCountStorage += 1
                return result
            }
            gate.notify()
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

    /// Never asked to pull a file in these tests (none call `publishSingleFile`),
    /// so a fixed failure reply is fine.
    private final class NeverCalledPullProvider: FileProviderPullProvider,
        @unchecked Sendable
    {
        func fetchStagedFile(
            generation: UInt64, repIndex: Int
        ) -> Result<String, FileProviderPullError> {
            .failure(.noCurrentOffer)
        }

        func cancelStagedPull(generation: UInt64, repIndex: Int) {
            Issue.record("cancelStagedPull should never be called in these availability-wiring tests")
        }
    }

    /// No-op transport — these tests exercise availability wiring, not the relay
    /// servicing path, so `startServing`/`stopServing`/`ensureConnected` need no
    /// real anonymous-XPC connection (mirrors the servicing-relay tests, which
    /// exercise `FileProviderRelayService` without a live connection).
    private final class NoOpRelayTransport: FileProviderRelayTransport,
        @unchecked Sendable
    {
        func startServing(_ service: FileProviderRelay) {}
        func stopServing() {}
        func ensureConnected(rootURL: URL) {}
    }

    private struct FakeFetchError: Error {}

    /// Stands in for `NSFileProviderManager.add(domain:completionHandler:)` (#428).
    ///
    /// Fails the first `failCount` calls (`NSError` with a nonsense domain/code —
    /// `addDomain` only inspects `localizedDescription` for logging, never the
    /// domain/code), then succeeds. Dispatches the completion asynchronously off a
    /// global queue to mirror the real API's async delivery, so a test can't rely
    /// on completion having already run by the time the call returns.
    private final class FakeAddDomain: @unchecked Sendable {
        private let lock = NSLock()
        private let failCount: Int
        private var callCountStorage = 0

        init(failCount: Int) {
            self.failCount = failCount
        }

        var callCount: Int { lock.withLock { callCountStorage } }

        func add(_ domain: NSFileProviderDomain, completion: @escaping @Sendable (Error?) -> Void) {
            let thisCall = lock.withLock {
                callCountStorage += 1
                return callCountStorage
            }
            let error: Error? = thisCall <= failCount ? NSError(domain: "FakeAddDomain", code: thisCall) : nil
            DispatchQueue.global().async { completion(error) }
        }
    }

    // MARK: - Helpers

    private func makeHost(
        domainIdentifier: String, domainSource: FakeDomainSource,
        notificationCenter: NotificationCenter,
        addDomain: FakeAddDomain? = nil
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
        if let addDomain {
            return FileProviderDomainHost(
                config: config,
                pullProvider: NeverCalledPullProvider(),
                relayTransport: NoOpRelayTransport(),
                notificationCenter: notificationCenter,
                fetchDomains: { try await domainSource.fetch() },
                addDomainToSystem: { domain, completion in addDomain.add(domain, completion: completion) })
        }
        return FileProviderDomainHost(
            config: config,
            pullProvider: NeverCalledPullProvider(),
            relayTransport: NoOpRelayTransport(),
            notificationCenter: notificationCenter,
            fetchDomains: { try await domainSource.fetch() })
    }

    /// Suspends until every block enqueued on the main queue before this call has
    /// run — used right after `setEnabled` (itself dispatched to main) so
    /// `applyEnabledOnMain` has deterministically finished, arming the
    /// domain-change observer, before a test posts to it.
    private func awaitMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: - Tests

    @Test("posting the domain-change notification while enabled re-probes via fetchDomains and applies the result")
    func notificationTriggersRefetchWhileEnabled() async throws {
        let domainIdentifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        let host = makeHost(
            domainIdentifier: domainIdentifierString, domainSource: domainSource,
            notificationCenter: center)
        host.setAvailabilityObserver { collector.record($0) }
        #expect(collector.values == [.inactive])

        host.setEnabled(true)
        await awaitMainQueueTurn()

        // A matching domain — `NSFileProviderDomain.userEnabled` is read-only and
        // defaults to `false` for a freshly constructed instance (there is no
        // public initializer that sets it `true`), so a match here always lands
        // `.needsEnabling`. The `userEnabled == true → .ready` mapping is already
        // locked directly by `FileProviderDomainHostAvailabilityTests`
        // above, since no live domain constructible here can produce it.
        let matching = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifierString),
            displayName: "Test")
        domainSource.setResult(.success([matching]))
        center.post(name: .fileProviderDomainDidChange, object: nil)

        try await collector.gate.wait { collector.values.contains(.needsEnabling) }

        // Change what the next probe reports, then trigger a second re-probe the
        // same way — proves the notification drives a fresh `fetchDomains` call
        // each time, not a cached first result.
        domainSource.setResult(.failure(FakeFetchError()))
        let callsBeforeSecondProbe = domainSource.callCount
        center.post(name: .fileProviderDomainDidChange, object: nil)
        try await collector.gate.wait { domainSource.callCount > callsBeforeSecondProbe }

        // `.needsEnabling` → `.unavailable` is a real transition (`setAvailability`
        // no-ops on a repeat), so an `.unavailable` strictly after the
        // `.needsEnabling` entry can only be this second, error-driven probe —
        // robust to the independent, real `NSFileProviderManager.add` failure
        // (see the suite doc comment) landing its own `.unavailable` at some
        // unrelated earlier point.
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

        // `setEnabled` was never called, so `startObservingDomainChanges()` never
        // registered an observer on `center` — the post above has nothing to
        // deliver to. Asserted synchronously rather than via a wait: with zero
        // observers registered, `NotificationCenter.post` has nothing to enqueue,
        // so there is no async delivery to race.
        #expect(collector.values == [.inactive])
        #expect(domainSource.callCount == 0)
        #expect(host.availability == .inactive)
    }

    @Test(
        "addDomain's registration failure reports .unavailable directly, without routing through the fetchDomains-driven mapping"
    )
    func registrationFailureReportsUnavailable() async throws {
        // Validates the `addDomain` failure branch's `self.setAvailability(.unavailable)`
        // consistency fix (previously a direct `self.availabilityStorage = .unavailable`
        // write that bypassed the observer). `addDomain`/domain registration has no
        // injected seam (see the suite doc comment), so this relies on the test
        // process's `NSFileProviderManager.add(domain)` genuinely failing — true for
        // a bare `swift test` executable with no registered File Provider extension,
        // which is what this test process is. If that ever stops being true (e.g. a
        // future test host where registration spuriously succeeds), this test would
        // need a real seam for `addDomain` to stay meaningful.
        //
        // `setEnabled(true)` also fires the discarded, throwaway priming
        // `fetchDomains` read exactly once (see the suite doc comment / issue
        // #448), so `domainSource.callCount == 0` no longer holds. Stage a
        // *matching* domain instead — one that would map to
        // `.ready`/`.needsEnabling` if it were ever consulted — and assert it's
        // never observed, while pinning `callCount == 1` to prove the priming
        // read is the *only* call: an exact count (not just "not zero") still
        // catches a future failure-branch edit that added its own extra,
        // similarly-discarded `fetchDomains` call.
        let domainIdentifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        let matching = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifierString),
            displayName: "Test")
        domainSource.setResult(.success([matching]))
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        let host = makeHost(
            domainIdentifier: domainIdentifierString,
            domainSource: domainSource, notificationCenter: center)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        try await collector.gate.wait(timeout: .seconds(20)) {
            collector.values.contains(.unavailable)
        }
        // The priming read is dispatched from an independent `Task`, so it can
        // still be in flight when `.unavailable` lands — wait for it too before
        // pinning the exact count.
        try await domainSource.gate.wait(timeout: .seconds(20)) { domainSource.callCount >= 1 }
        #expect(
            !collector.values.contains(.ready) && !collector.values.contains(.needsEnabling),
            "the addDomain failure branch must write .unavailable directly — a .ready/.needsEnabling here would mean it consulted the discarded priming read's result"
        )
        #expect(
            domainSource.callCount == 1,
            "only the priming read should ever call fetchDomains here — the addDomain failure branch must not consult it too"
        )
    }

    @Test(
        "enabling arms NSFileProviderDomainDidChange delivery via an eager, throwaway fetchDomains read, independent of registration outcome"
    )
    func enableEagerlyPrimesDomainNotifications() async throws {
        // The real `NSFileProviderManager.add(domain)` call in this test process
        // never succeeds (see the suite doc comment), so if the priming read were
        // gated on registration succeeding — as `refreshAvailability()` normally
        // is, via `addDomain`'s success completion — `domainSource` would never be
        // consulted here. Proves `primeDomainChangeNotifications()` runs
        // unconditionally at enable, arming the notification without waiting on
        // (or being blocked by) registration (issue #448).
        let domainSource = FakeDomainSource()
        let center = NotificationCenter()
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: center)

        host.setEnabled(true)

        try await domainSource.gate.wait(timeout: .seconds(20)) { domainSource.callCount >= 1 }
    }

    @Test("a paste that finds the domain unregistered after a transient add failure retries registration (#428)")
    func pasteRetriesTransientRegistrationFailure() async throws {
        // Simulates a one-off transient `NSFileProviderManager.add` failure: the
        // initial `setEnabled(true)` registration and its orphan-heal retry both
        // fail (calls 1-2), landing the domain in `.unavailable` with
        // `domainRegistered == false` — exactly the issue's reported dead end,
        // since nothing used to retry after that. A subsequent `publishSingleFile`
        // call (standing in for a real paste) must kick a bounded re-registration
        // (call 3), which this fake lets succeed, and the domain must come back.
        let domainIdentifierString = "kernova-clipboard-test-\(UUID().uuidString)"
        let domainSource = FakeDomainSource()
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        let addDomain = FakeAddDomain(failCount: 2)
        let host = makeHost(
            domainIdentifier: domainIdentifierString, domainSource: domainSource,
            notificationCenter: center, addDomain: addDomain)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        try await collector.gate.wait(timeout: .seconds(20)) {
            collector.values.contains(.unavailable)
        }
        #expect(
            addDomain.callCount == 2,
            "the initial registration plus its one orphan-heal retry should both have run")

        // Arm the domain source so the re-registration's post-success
        // `refreshAvailability()` finds a match — a fresh domain's `userEnabled`
        // defaults `false`, landing `.needsEnabling` (see
        // `notificationTriggersRefetchWhileEnabled` above for why `.ready` isn't
        // constructible here).
        let matching = NSFileProviderDomain(
            identifier: NSFileProviderDomainIdentifier(domainIdentifierString),
            displayName: "Test")
        domainSource.setResult(.success([matching]))

        let published = host.publishSingleFile(
            generation: 1, repIndex: 0, filename: "test.txt", byteCount: 10, uti: "public.data")
        #expect(published == nil, "the triggering paste itself must still fall back to the sync path")

        try await collector.gate.wait(timeout: .seconds(20)) {
            collector.values.contains(.needsEnabling)
        }
        #expect(
            addDomain.callCount == 3,
            "the usage-triggered re-registration should have retried add() exactly once more")
    }

    @Test("disabling stops observing the domain-change notification; a later post is a no-op")
    func disablingStopsObservingDomainChanges() async throws {
        let domainSource = FakeDomainSource()
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: center)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)
        await awaitMainQueueTurn()

        // Let the real (failing, per the suite doc comment) registration land
        // before disabling, so its async `.unavailable` write can't race with the
        // post-disable snapshot below.
        try await collector.gate.wait(timeout: .seconds(20)) {
            collector.values.contains(.unavailable)
        }

        host.setEnabled(false)
        await awaitMainQueueTurn()
        #expect(host.availability == .inactive)

        let valuesBeforePost = collector.values
        let callsBeforePost = domainSource.callCount
        center.post(name: .fileProviderDomainDidChange, object: nil)

        // `setEnabled(false)` runs `stopObservingDomainChanges()`, so the observer
        // is gone before this post — nothing to deliver to, hence a synchronous
        // assertion rather than a wait (mirrors `notificationIgnoredWhileNeverEnabled`).
        #expect(collector.values == valuesBeforePost)
        #expect(domainSource.callCount == callsBeforePost)
    }
}
