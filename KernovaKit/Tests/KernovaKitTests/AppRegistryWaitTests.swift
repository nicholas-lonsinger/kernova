import Darwin
import Foundation
import KernovaSynchronization
import Testing

@testable import KernovaAppRegistry

/// Holding on until Launch Services has let a bundle go, and leaving a running
/// app alone while doing it.
///
/// Every wait runs on a ``FakeClock``: its sleeps advance virtual time and are
/// recorded, so the back-off schedule is asserted without real time passing.
@Suite("App registry wait", .caseScoped)
struct AppRegistryWaitTests {
    private let bundle = URL(fileURLWithPath: "/Applications/Kernova.app")

    /// The back-off the wait sleeps on, up to and past its cap.
    private static let schedule: [TimeInterval] = [0.025, 0.05, 0.1, 0.2, 0.4, 0.8, 1, 1]

    // MARK: - Released on a fresh read

    /// A fresh read can return an instance Launch Services has recorded as
    /// exited before it returns none at all.
    @Test("A bundle wait ends on the fresh read that finds the instance terminated")
    func bundleWaitEndsOnATerminatedRead() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance()], releasedFromLookup: 3, release: .terminated,
            clock: clock)

        let released = awaitDeregistration(from: registry, scope: .all, within: 20, clock: clock)

        #expect(released)
        #expect(clock.sleeps == Array(Self.schedule.prefix(2)))
    }

    // MARK: - Never released

    @Test("An instance macOS never lets go fails the bundle wait, read last at its deadline")
    func bundleWaitFailsAtItsDeadline() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(registered: [FakeRegisteredInstance()], clock: clock)

        let released = awaitDeregistration(from: registry, scope: .all, within: 3, clock: clock)

        #expect(!released)
        Self.expectStoppedAtDeadline(clock: clock, registry: registry, deadline: 3)
    }

    /// The schedule runs until the next sleep would pass the deadline; that
    /// sleep is cut to land on it, and one read there decides.
    private static func expectStoppedAtDeadline(
        clock: FakeClock, registry: FakeAppRegistry, deadline: TimeInterval
    ) {
        let sleeps = clock.sleeps
        #expect(Array(sleeps.dropLast()) == Array(schedule.prefix(7)))
        #expect(sleeps.last.map { $0 < 1 } == true)
        #expect(clock.elapsed == deadline)
        #expect(registry.lookupTimes.last == deadline)
    }

    // MARK: - Entry points

    private func awaitDeregistration(
        from registry: FakeAppRegistry, scope: RegisteredInstanceScope,
        within deadline: TimeInterval, clock: FakeClock
    ) -> Bool {
        AppRegistryWait.awaitDeregistration(
            ofBundleAt: bundle, scope: scope, by: clock.date(after: deadline),
            registry: registry, now: clock.now, sleep: clock.sleep)
    }
}

// MARK: - Doubles

/// Virtual time that moves only when the wait sleeps, recording each sleep.
///
/// Starts at the reference date, so elapsed time is the date's own value.
private final class FakeClock: Sendable {
    private struct State: Sendable {
        var elapsed: TimeInterval = 0
        var sleeps: [TimeInterval] = []
    }

    private let state = Locked(State())

    var elapsed: TimeInterval { state.withLock { $0.elapsed } }

    var sleeps: [TimeInterval] { state.withLock { $0.sleeps } }

    func now() -> Date { Date(timeIntervalSinceReferenceDate: elapsed) }

    func date(after interval: TimeInterval) -> Date { now().addingTimeInterval(interval) }

    func sleep(_ interval: TimeInterval) {
        state.withLock { state in
            state.elapsed += interval
            state.sleeps.append(interval)
        }
    }
}

/// A registry answering with whatever instances a test hands it, for any bundle.
private final class FakeAppRegistry: AppRegistry, Sendable {
    /// What a pid lookup finds once the registry has let go.
    enum Release: Sendable {
        /// No instance at all.
        case deregistered
        /// An instance recorded as exited.
        case terminated
    }

    private let registered: [FakeRegisteredInstance]

    /// The pid lookup, counted from one, from which the registry has let go.
    private let releasedFromLookup: Int?

    private let release: Release

    private let clock: FakeClock

    /// An instance the bundle listing includes only after its first call.
    private let laterInstance: FakeRegisteredInstance?

    private struct State: Sendable {
        var lookups = 0
        var lookupTimes: [TimeInterval] = []
        var listings = 0
    }

    private let state = Locked(State())

    init(
        registered: [FakeRegisteredInstance], releasedFromLookup: Int? = nil,
        release: Release = .deregistered, clock: FakeClock,
        laterInstance: FakeRegisteredInstance? = nil
    ) {
        self.registered = registered
        self.releasedFromLookup = releasedFromLookup
        self.release = release
        self.clock = clock
        self.laterInstance = laterInstance
    }

    /// The virtual time of every pid lookup, in order.
    var lookupTimes: [TimeInterval] { state.withLock { $0.lookupTimes } }

    func instances(ofBundleAt bundleURL: URL) -> [any RegisteredAppInstance] {
        let listing = state.withLock { state in
            state.listings += 1
            return state.listings
        }
        return listing > 1 ? registered + [laterInstance].compactMap { $0 } : registered
    }

    func instance(withProcessIdentifier identifier: pid_t) -> (any RegisteredAppInstance)? {
        let elapsed = clock.elapsed
        let lookup = state.withLock { state in
            state.lookups += 1
            state.lookupTimes.append(elapsed)
            return state.lookups
        }
        let held = (registered + [laterInstance].compactMap { $0 })
            .first { $0.processIdentifier == identifier }
        guard let held, let releasedFromLookup, lookup >= releasedFromLookup else { return held }
        switch release {
        case .deregistered:
            return nil
        case .terminated:
            return FakeRegisteredInstance(
                processIdentifier: held.processIdentifier, terminated: true)
        }
    }
}

/// One registry entry, fixed for its lifetime the way a fresh read's is.
private struct FakeRegisteredInstance: RegisteredAppInstance {
    /// The pid a fake instance runs as unless a test names another.
    static let identifier: pid_t = 42

    let processIdentifier: pid_t
    let hasTerminated: Bool
    let processHasExited: Bool

    init(
        processIdentifier: pid_t = FakeRegisteredInstance.identifier, terminated: Bool = false,
        processExited: Bool = true
    ) {
        self.processIdentifier = processIdentifier
        hasTerminated = terminated
        processHasExited = processExited
    }
}
