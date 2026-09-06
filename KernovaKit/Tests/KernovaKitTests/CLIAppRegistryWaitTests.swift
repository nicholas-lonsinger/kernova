import Foundation
import KernovaTestSupport
import Testing

@testable import KernovaCLICore

/// What the tool does after a quit's socket closes: hold on until Launch
/// Services has let the app go, since that registry is what the next verb's
/// launch consults.
@Suite("CLI app registry wait", .admissionGated)
struct CLIAppRegistryWaitTests {
    private let bundle = URL(fileURLWithPath: "/Applications/Kernova.app")

    @Test("The wait ends once the registered instance reports terminated")
    func waitEndsWhenTheInstanceTerminates() async throws {
        let instance = FakeRegisteredInstance()
        let registry = FakeAppRegistry(registered: [instance])

        async let outcome = self.awaitDeregistration(
            from: registry, within: testWaitBackstop)
        try await instance.observed.wait { instance.isObserved }
        instance.terminate()
        let failure = await outcome

        #expect(failure == nil)
    }

    @Test("A registry holding nothing live ends the wait without waiting at all")
    func waitEndsWhenNothingIsRegistered() async throws {
        let empty = FakeAppRegistry(registered: [])
        let gone = FakeAppRegistry(registered: [FakeRegisteredInstance(terminated: true)])

        // A zero deadline leaves no room to wait in, so a wait that returns is
        // one that never started.
        let nothingRegistered = await awaitDeregistration(from: empty, within: 0)
        let alreadyGone = await awaitDeregistration(from: gone, within: 0)

        #expect(nothingRegistered == nil)
        #expect(alreadyGone == nil)
    }

    @Test("An instance macOS never lets go fails the wait at its deadline")
    func waitFailsAtItsDeadline() async throws {
        let instance = FakeRegisteredInstance()
        let registry = FakeAppRegistry(registered: [instance])

        // The deadline is the assertion here, so it is deliberately small
        // (docs/TESTING.md, "Injected production timeouts").
        let failure = await awaitDeregistration(from: registry, within: 0.2)

        #expect(failure?.code == .timedOut)
        #expect(failure?.message.contains("still had it registered") == true)
    }

    /// Runs the wait on a GCD thread, the way production runs it on the tool's
    /// main thread: it services a run loop rather than parking, so it must not
    /// hold a cooperative-pool thread (docs/TESTING.md, "Blocking bridge
    /// calls").
    private func awaitDeregistration(
        from registry: FakeAppRegistry, within deadline: TimeInterval
    ) async -> CLIFailure? {
        let bundle = bundle
        return await offCooperativePool {
            do {
                try AppRegistryWait.awaitDeregistration(
                    ofBundleAt: bundle, within: deadline, registry: registry)
                return nil
            } catch let failure as CLIFailure {
                return failure
            } catch {
                return CLIFailure(.operationFailed, "\(error)")
            }
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

    private let lock = NSLock()
    private var terminated: Bool
    private var notify: (@Sendable () -> Void)?

    init(terminated: Bool = false) { self.terminated = terminated }

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
