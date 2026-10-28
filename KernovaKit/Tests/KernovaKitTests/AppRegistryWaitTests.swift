import Darwin
import Foundation
import KernovaSynchronization
import KernovaTestSupport
import Testing

@testable import KernovaAppRegistry

/// Holding on until Launch Services has let a bundle go, and leaving a running
/// app alone while doing it.
@Suite("App registry wait", .caseScoped)
struct AppRegistryWaitTests {
    private let bundle = URL(fileURLWithPath: "/Applications/Kernova.app")

    @Test("The wait ends once the registered instance reports terminated")
    func waitEndsWhenTheInstanceTerminates() async throws {
        let instance = FakeRegisteredInstance()
        let registry = FakeAppRegistry(registered: [instance])

        async let outcome = self.awaitDeregistration(
            from: registry, scope: .all, within: testWaitBackstop)
        try await instance.observed.wait { instance.isObserved }
        instance.terminate()
        let released = await outcome

        #expect(released)
    }

    @Test("A registry holding nothing live ends the wait without waiting at all")
    func waitEndsWhenNothingIsRegistered() async throws {
        let empty = FakeAppRegistry(registered: [])
        let gone = FakeAppRegistry(registered: [FakeRegisteredInstance(terminated: true)])

        // A zero deadline leaves no room to wait in, so a wait that returns
        // `true` is one that never started.
        let nothingRegistered = await awaitDeregistration(from: empty, scope: .all, within: 0)
        let alreadyGone = await awaitDeregistration(from: gone, scope: .all, within: 0)

        #expect(nothingRegistered)
        #expect(alreadyGone)
    }

    @Test("An instance macOS never lets go fails the wait at its deadline")
    func waitFailsAtItsDeadline() async throws {
        let registry = FakeAppRegistry(registered: [FakeRegisteredInstance()])

        // The deadline is the assertion here, so it is small — the
        // exception `testWaitBackstop` names.
        let released = await awaitDeregistration(from: registry, scope: .all, within: 0.2)

        #expect(!released)
    }

    // MARK: - Scope

    @Test("A running instance is not something the exited-processes scope waits on")
    func runningInstanceIsLeftAlone() async throws {
        let registry = FakeAppRegistry(registered: [FakeRegisteredInstance(processExited: false)])

        // Zero deadline again: the scope has to drop the instance before the
        // wait starts, not outlast it.
        let released = await awaitDeregistration(from: registry, scope: .exitedProcesses, within: 0)

        #expect(released)
    }

    @Test("An instance whose process is gone is one the exited-processes scope waits on")
    func exitedInstanceIsWaitedOut() async throws {
        let instance = FakeRegisteredInstance(processExited: true)
        let registry = FakeAppRegistry(registered: [instance])

        async let outcome = self.awaitDeregistration(
            from: registry, scope: .exitedProcesses, within: testWaitBackstop)
        try await instance.observed.wait { instance.isObserved }
        instance.terminate()
        let released = await outcome

        #expect(released)
    }

    // MARK: - Keyed on the process

    @Test("A pid-keyed wait ends once that instance reports terminated")
    func processWaitEndsWhenTheInstanceTerminates() async throws {
        let instance = FakeRegisteredInstance()
        let registry = FakeAppRegistry(registered: [instance])

        async let outcome = self.awaitDeregistration(
            ofProcess: FakeRegisteredInstance.identifier, from: registry, within: testWaitBackstop)
        try await instance.observed.wait { instance.isObserved }
        instance.terminate()
        let released = await outcome

        #expect(released)
    }

    /// The registry holds registered apps only, so a pid it does not know is
    /// nothing to wait for — including one it has already let go.
    @Test("A pid the registry does not hold ends the wait without waiting at all")
    func processWaitEndsWhenThePidIsUnknown() async throws {
        let registry = FakeAppRegistry(registered: [])

        let released = await awaitDeregistration(
            ofProcess: FakeRegisteredInstance.identifier, from: registry, within: 0)

        #expect(released)
    }

    @Test("A pid-keyed wait on an instance macOS never lets go fails at its deadline")
    func processWaitFailsAtItsDeadline() async throws {
        let registry = FakeAppRegistry(registered: [FakeRegisteredInstance()])

        // The deadline is the assertion here, so it is small — the
        // exception `testWaitBackstop` names.
        let released = await awaitDeregistration(
            ofProcess: FakeRegisteredInstance.identifier, from: registry, within: 0.2)

        #expect(!released)
    }

    // MARK: - A notice that never arrives

    /// Launch Services can let an instance go before AppKit's channel to this
    /// process connects, and then the instance's own notice never arrives.
    @Test("A pid-keyed wait ends on a fresh read alone when the instance never announces")
    func processWaitEndsOnAFreshRead() async throws {
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance()], releasedFromLookup: Self.unannouncedRelease)

        let released = await awaitDeregistration(
            ofProcess: FakeRegisteredInstance.identifier, from: registry, within: testWaitBackstop)

        #expect(released)
    }

    @Test("A bundle wait ends on a fresh read alone when the instance never announces")
    func bundleWaitEndsOnAFreshRead() async throws {
        let registry = FakeAppRegistry(
            registered: [FakeRegisteredInstance()], releasedFromLookup: Self.unannouncedRelease)

        let released = await awaitDeregistration(
            from: registry, scope: .all, within: testWaitBackstop)

        #expect(released)
    }

    /// The pid lookup from which the registry has let go: past the reads a
    /// wait makes on its way in, so only a later re-read can see it.
    private static let unannouncedRelease = 4

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

    /// Runs the wait on a GCD thread, the way production runs it on a main
    /// thread whose run loop it services rather than parks — so it must not
    /// hold a cooperative-pool thread (`offCooperativePool`).
    private func awaitDeregistration(
        from registry: FakeAppRegistry, scope: RegisteredInstanceScope, within deadline: TimeInterval
    ) async -> Bool {
        let bundle = bundle
        return await offCooperativePool {
            AppRegistryWait.awaitDeregistration(
                ofBundleAt: bundle, scope: scope,
                by: Date(timeIntervalSinceNow: deadline), registry: registry)
        }
    }

    /// ``awaitDeregistration(from:scope:within:)`` for the pid-keyed entry
    /// point, on the same off-main thread.
    private func awaitDeregistration(
        ofProcess identifier: pid_t, from registry: FakeAppRegistry, within deadline: TimeInterval
    ) async -> Bool {
        await offCooperativePool {
            AppRegistryWait.awaitDeregistration(
                ofProcess: identifier, by: Date(timeIntervalSinceNow: deadline),
                registry: registry)
        }
    }
}

// MARK: - Doubles

/// A registry answering with whatever instances a test hands it, for any bundle.
private final class FakeAppRegistry: AppRegistry, Sendable {
    let registered: [FakeRegisteredInstance]

    /// The pid lookup, counted from one, from which the registry holds nothing —
    /// Launch Services letting go with no notice to the instance.
    private let releasedFromLookup: Int?

    private let lookups = Locked(0)

    init(registered: [FakeRegisteredInstance], releasedFromLookup: Int? = nil) {
        self.registered = registered
        self.releasedFromLookup = releasedFromLookup
    }

    func instances(ofBundleAt bundleURL: URL) -> [any RegisteredAppInstance] { registered }

    func instance(withProcessIdentifier identifier: pid_t) -> (any RegisteredAppInstance)? {
        let lookup = lookups.withLock { count in
            count += 1
            return count
        }
        if let releasedFromLookup, lookup >= releasedFromLookup { return nil }
        return registered.first { $0.processIdentifier == identifier }
    }
}

/// An instance a test terminates on cue, reporting it through the same callback
/// Launch Services' own notification would.
private final class FakeRegisteredInstance: RegisteredAppInstance, Sendable {
    /// Fires once the wait has registered its observer, so a test can terminate
    /// the instance without racing the registration.
    let observed = AsyncGate()

    /// The pid every fake instance runs as.
    static let identifier: pid_t = 42

    let processIdentifier = FakeRegisteredInstance.identifier

    let processHasExited: Bool

    private struct State: Sendable {
        var terminated: Bool
        var notify: (@Sendable () -> Void)?
    }

    private let state: Locked<State>

    init(terminated: Bool = false, processExited: Bool = true) {
        state = Locked(State(terminated: terminated))
        processHasExited = processExited
    }

    var hasTerminated: Bool { state.withLock { $0.terminated } }

    /// Whether the wait currently holds an observation of this instance.
    var isObserved: Bool { state.withLock { $0.notify != nil } }

    func observeTermination(_ notify: @escaping @Sendable () -> Void) -> TerminationObservation {
        state.withLock { $0.notify = notify }
        observed.notify()
        return TerminationObservation { [state] in state.withLock { $0.notify = nil } }
    }

    /// Reports the instance gone the way the registry would.
    func terminate() {
        let waiter = state.withLock { state in
            state.terminated = true
            return state.notify
        }
        waiter?()
    }
}
