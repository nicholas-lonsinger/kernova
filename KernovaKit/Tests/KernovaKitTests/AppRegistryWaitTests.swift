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

    /// A bundle wait's first read is lookup one, so the release on lookup five
    /// follows four sleeps.
    @Test("A bundle wait ends on the fresh read that finds the instance gone")
    func bundleWaitEndsOnAFreshRead() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance()], releasedFromLookup: 5, clock: clock)

        let released = awaitDeregistration(from: registry, scope: .all, within: 20, clock: clock)

        #expect(released)
        #expect(clock.sleeps == Array(Self.schedule.prefix(4)))
    }

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

    @Test("A pid-keyed wait ends on the fresh read that finds the instance gone")
    func processWaitEndsOnAFreshRead() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance()], releasedFromLookup: 4, clock: clock)

        let released = awaitDeregistration(
            ofProcess: FakeRegisteredInstance.identifier, from: registry, within: 20, clock: clock)

        #expect(released)
        #expect(clock.sleeps == Array(Self.schedule.prefix(3)))
    }

    @Test("A long wait doubles its sleep up to the cap and stays there")
    func longWaitSleepsAtTheCap() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance()], releasedFromLookup: 9, clock: clock)

        let released = awaitDeregistration(from: registry, scope: .all, within: 20, clock: clock)

        #expect(released)
        #expect(clock.sleeps == Self.schedule)
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

    @Test("An instance macOS never lets go fails the pid-keyed wait, read last at its deadline")
    func processWaitFailsAtItsDeadline() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(registered: [FakeRegisteredInstance()], clock: clock)

        let released = awaitDeregistration(
            ofProcess: FakeRegisteredInstance.identifier, from: registry, within: 3, clock: clock)

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

    // MARK: - Nothing to wait for

    @Test("A registry holding nothing live ends the wait without sleeping")
    func waitEndsWhenNothingIsRegistered() {
        let clock = FakeClock()
        let empty = FakeAppRegistry(registered: [], clock: clock)
        let gone = FakeAppRegistry(
            registered: [FakeRegisteredInstance(terminated: true)], clock: clock)

        #expect(awaitDeregistration(from: empty, scope: .all, within: 20, clock: clock))
        #expect(awaitDeregistration(from: gone, scope: .all, within: 20, clock: clock))
        #expect(clock.sleeps.isEmpty)
    }

    /// The registry holds registered apps only, so a pid it does not know is
    /// nothing to wait for — including one it has already let go.
    @Test("A pid the registry does not hold ends the wait without sleeping")
    func processWaitEndsWhenThePidIsUnknown() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(registered: [], clock: clock)

        let released = awaitDeregistration(
            ofProcess: FakeRegisteredInstance.identifier, from: registry, within: 20, clock: clock)

        #expect(released)
        #expect(clock.sleeps.isEmpty)
    }

    @Test("An instance with no process identifier is not one to wait out")
    func instanceWithoutAPidIsReleased() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance(processIdentifier: 0)], clock: clock)

        let bundleReleased = awaitDeregistration(
            from: registry, scope: .all, within: 20, clock: clock)
        let processReleased = awaitDeregistration(
            ofProcess: 0, from: registry, within: 20, clock: clock)

        #expect(bundleReleased)
        #expect(processReleased)
        #expect(clock.sleeps.isEmpty)
    }

    // MARK: - Scope

    @Test("A running instance is not something the exited-processes scope waits on")
    func runningInstanceIsLeftAlone() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance(processExited: false)], clock: clock)

        let released = awaitDeregistration(
            from: registry, scope: .exitedProcesses, within: 20, clock: clock)

        #expect(released)
        #expect(clock.sleeps.isEmpty)
    }

    @Test("An instance whose process is gone is one the exited-processes scope waits on")
    func exitedInstanceIsWaitedOut() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance(processExited: true)], releasedFromLookup: 2,
            clock: clock)

        let released = awaitDeregistration(
            from: registry, scope: .exitedProcesses, within: 20, clock: clock)

        #expect(released)
        #expect(clock.sleeps == [Self.schedule[0]])
    }

    /// Only instances admitted when the wait begins count, so one the registry
    /// starts holding later does not extend the wait.
    @Test("An instance registered after the wait begins does not extend it")
    func laterInstanceDoesNotExtendTheWait() {
        let clock = FakeClock()
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance()], releasedFromLookup: 2, clock: clock,
            laterInstance: FakeRegisteredInstance(processIdentifier: 43))

        let released = awaitDeregistration(from: registry, scope: .all, within: 20, clock: clock)

        #expect(released)
        #expect(clock.sleeps == [Self.schedule[0]])
    }

    // MARK: - Process liveness

    /// Launch Services registers an instance before it has a process
    /// identifier for it. Reading that as "gone" would put `.exitedProcesses`
    /// on a healthy app mid-launch and hold it to the deadline.
    @Test("An identifier naming no process reads as running, not as gone")
    func identifierWithoutAProcessReadsAsRunning() {
        #expect(processIsRunning(0))
        #expect(processIsRunning(-1))
    }

    @Test("A live process reads as running and a pid the kernel cannot hold does not")
    func liveProcessReadsAsRunning() {
        // Above `PID_MAX`, so no process can ever carry it.
        #expect(processIsRunning(getpid()))
        #expect(!processIsRunning(999_999))
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

    private func awaitDeregistration(
        ofProcess identifier: pid_t, from registry: FakeAppRegistry,
        within deadline: TimeInterval, clock: FakeClock
    ) -> Bool {
        AppRegistryWait.awaitDeregistration(
            ofProcess: identifier, by: clock.date(after: deadline), registry: registry,
            now: clock.now, sleep: clock.sleep)
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
