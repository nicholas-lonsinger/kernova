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
/// `setEnabled(true)` also runs the *real*, non-stubbable `registerDomain()` →
/// `NSFileProviderManager.add(domain)` — there is no injected seam for domain
/// registration itself (see the type's doc comment on why: it's shared,
/// direction-agnostic system machinery). In this test process (a bare `swift
/// test` executable, not an app bundle with a registered File Provider
/// extension) that call reliably fails, which is exactly what
/// `registrationFailureReportsUnavailable` below exercises. Every fake domain
/// identifier is a fresh UUID so the (failing) registration attempts from
/// different tests can never collide.
@Suite("FileProviderDomainHost enablement & availability wiring")
@MainActor
struct FileProviderDomainHostEnablementTests {
    // MARK: - Fakes

    /// Stands in for `NSFileProviderManager.domains()`, returning (or throwing)
    /// whatever a test last configured and counting invocations so a test can
    /// tell a probe actually ran.
    private final class FakeDomainSource: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[NSFileProviderDomain], Error> = .success([])
        private var callCountStorage = 0

        var callCount: Int { lock.withLock { callCountStorage } }

        func setResult(_ result: Result<[NSFileProviderDomain], Error>) {
            lock.withLock { self.result = result }
        }

        func fetch() async throws -> [NSFileProviderDomain] {
            let outcome = lock.withLock { () -> Result<[NSFileProviderDomain], Error> in
                callCountStorage += 1
                return result
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

    // MARK: - Helpers

    private func makeHost(
        domainIdentifier: String, domainSource: FakeDomainSource,
        notificationCenter: NotificationCenter
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

    @Test("addDomain's registration failure reports .unavailable directly, without consulting fetchDomains")
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
        let domainSource = FakeDomainSource()
        let collector = AvailabilityCollector()
        let center = NotificationCenter()
        let host = makeHost(
            domainIdentifier: "kernova-clipboard-test-\(UUID().uuidString)",
            domainSource: domainSource, notificationCenter: center)
        host.setAvailabilityObserver { collector.record($0) }

        host.setEnabled(true)

        try await collector.gate.wait(timeout: .seconds(20)) {
            collector.values.contains(.unavailable)
        }
        #expect(
            domainSource.callCount == 0,
            "the addDomain failure branch writes .unavailable directly — it must not consult fetchDomains")
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
