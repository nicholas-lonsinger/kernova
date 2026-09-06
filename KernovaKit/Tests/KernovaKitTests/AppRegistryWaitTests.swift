import Darwin
import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaKit

/// Holding on until Launch Services has let a bundle go, and leaving a running
/// app alone while doing it.
@Suite("App registry wait", .admissionGated)
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

        // The deadline is the assertion here, so it is deliberately small
        // (docs/TESTING.md, "Injected production timeouts").
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
    /// hold a cooperative-pool thread (docs/TESTING.md, "Blocking bridge
    /// calls").
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
}

// MARK: - Doubles

/// A registry answering with whatever instances a test hands it, for any bundle.
private struct FakeAppRegistry: AppRegistry {
    let registered: [FakeRegisteredInstance]

    func instances(ofBundleAt bundleURL: URL) -> [any RegisteredAppInstance] { registered }
}

/// An instance a test terminates on cue, reporting it through the same callback
/// Launch Services' own notification would.
private final class FakeRegisteredInstance: RegisteredAppInstance, @unchecked Sendable {
    /// Fires once the wait has registered its observer, so a test can terminate
    /// the instance without racing the registration.
    let observed = AsyncGate()

    let processHasExited: Bool

    private let lock = NSLock()
    private var terminated: Bool
    private var notify: (@Sendable () -> Void)?

    init(terminated: Bool = false, processExited: Bool = true) {
        self.terminated = terminated
        processHasExited = processExited
    }

    var hasTerminated: Bool { lock.withLock { terminated } }

    /// Whether the wait currently holds an observation of this instance.
    var isObserved: Bool { lock.withLock { notify != nil } }

    func observeTermination(_ notify: @escaping @Sendable () -> Void) -> TerminationObservation {
        lock.withLock { self.notify = notify }
        observed.notify()
        return TerminationObservation { [self] in lock.withLock { self.notify = nil } }
    }

    /// Reports the instance gone the way the registry would.
    func terminate() {
        let waiter = lock.withLock { () -> (@Sendable () -> Void)? in
            terminated = true
            return notify
        }
        waiter?()
    }
}
