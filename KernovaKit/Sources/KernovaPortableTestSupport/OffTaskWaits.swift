#if canImport(Testing)
import KernovaSynchronization
import Testing

/// Where a wait made for a test case off the case's own task reports how it
/// failed: a double holding the code under test until the test releases it, or
/// a thread the test starts to play a peer.
///
/// Swift Testing gives an issue to the case whose task records it, and a
/// production thread, a dispatch queue or a thread a test starts is no case's
/// task, so a failure recorded where such a wait runs fails no case. Made in
/// the case's task — where a test makes its doubles and starts its threads —
/// this captures the case's ledger, and the case records what the ledger holds
/// as it ends, once no wait run here is still in flight. A case that has no
/// ledger, because neither `.caseScoped` nor ``Trait/offTaskWaitsReported``
/// scopes its suite, fails where it makes one of these.
///
/// A wait that starts once its case has ended, in work the case left running,
/// records its failure where it runs.
public struct OffTaskWaits: Sendable {
    private let ledger: Ledger?
    /// Where this was made, which each failure is recorded at.
    private let site: SourceLocation

    /// Captures the ledger of the test case running now.
    public init(fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column) {
        site = SourceLocation(fileID: fileID, filePath: filePath, line: line, column: column)
        ledger = Ledger.current
        if ledger == nil {
            Issue.record(
                "Waits made off this case's task fail no case: scope its suite by .caseScoped or .offTaskWaitsReported",
                sourceLocation: site)
        }
    }

    /// Runs `wait`, answering whether it ended without throwing.
    ///
    /// What it throws — its backstop's failure, most often — fails the case
    /// this was made in, and this answers `false`, leaving the caller to go on
    /// as it chooses: most stop holding rather than keep a thread for good.
    @discardableResult
    @available(*, noasync, message: "Await run(isolation:_:) instead of blocking a cooperative thread")
    public func run(_ wait: () throws -> Void) -> Bool {
        let counted = ledger?.begin() ?? false
        do {
            try wait()
            end(counted, nil)
            return true
        } catch {
            end(counted, error)
            return false
        }
    }

    // `isolation` uses the Swift `isolated` keyword to run `wait` in the
    // caller's isolation, so it is never referenced by name.
    // periphery:ignore:parameters isolation
    /// Runs `wait` as the blocking overload does, suspending instead of
    /// blocking.
    @discardableResult
    public func run(isolation: isolated (any Actor)? = #isolation, _ wait: () async throws -> Void) async -> Bool {
        let counted = ledger?.begin() ?? false
        do {
            try await wait()
            end(counted, nil)
            return true
        } catch {
            end(counted, error)
            return false
        }
    }

    /// Runs `function`, a test case, with a ledger of its own, then records in
    /// the case each failure a wait run through an ``OffTaskWaits`` made in it
    /// kept there — once none is still in flight.
    public static func scope(_ function: () async throws -> Void) async throws {
        let ledger = Ledger()
        let outcome: Result<Void, any Error>
        do {
            try await Ledger.$current.withValue(ledger) { try await function() }
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        for failure in await ledger.close() {
            if let site = failure.site {
                Issue.record(failure.error, sourceLocation: site)
            } else {
                Issue.record(failure.error)
            }
        }
        try outcome.get()
    }

    /// Keeps `failure` in the ledger when the wait was counted there and the
    /// case has not ended; records it where the wait ran otherwise.
    private func end(_ counted: Bool, _ failure: (any Error)?) {
        let kept = failure.map { Ledger.Failure(error: $0, site: site) }
        if counted, let ledger, ledger.end(kept) { return }
        if let failure { Issue.record(failure, sourceLocation: site) }
    }
}

extension OffTaskWaits {
    /// One test case's account of the waits made for it off its task.
    fileprivate final class Ledger: Sendable {
        @TaskLocal static var current: Ledger?

        struct Failure: Sendable {
            let error: any Error
            let site: SourceLocation?
        }

        private struct State: Sendable {
            var inFlight = 0
            var failures: [Failure] = []
            /// Whether the case has ended; a wait ended after it records where it ran.
            var closed = false
            /// The case's close, waiting on the waits still in flight.
            var closing: (@Sendable ([Failure]) -> Void)?
        }

        private let state = Locked(State())

        /// Counts a wait in flight, answering whether the case is still open to it.
        func begin() -> Bool {
            state.withLock { state in
                guard !state.closed else { return false }
                state.inFlight += 1
                return true
            }
        }

        /// Ends a wait ``begin()`` counted, keeping `failure` for the case;
        /// answers `false` when the case has ended first.
        func end(_ failure: Failure?) -> Bool {
            let (kept, close): (Bool, (() -> Void)?) = state.withLock { state in
                guard !state.closed else { return (false, nil) }
                if let failure { state.failures.append(failure) }
                state.inFlight -= 1
                guard state.inFlight == 0, let closing = state.closing else { return (true, nil) }
                state.closed = true
                state.closing = nil
                let failures = state.failures
                return (true, { closing(failures) })
            }
            close?()
            return kept
        }

        /// Closes once no counted wait is in flight, answering every failure
        /// kept — and, when waits are still in flight at the backstop, the
        /// backstop's failure with them, leaving those to record where they run.
        func close() async -> [Failure] {
            let backstop = Backstop("the waits made off the test case's task")
            do {
                return try await backstop.park { resume in
                    let failures: [Failure]? = state.withLock { state in
                        guard state.inFlight > 0 else {
                            state.closed = true
                            return state.failures
                        }
                        state.closing = resume
                        return nil
                    }
                    if let failures { resume(failures) }
                }
            } catch {
                return state.withLock { state in
                    state.closed = true
                    state.closing = nil
                    let outlived = backstop.failure("\(state.inFlight) still in flight")
                    return state.failures + [Failure(error: outlived, site: nil)]
                }
            }
        }
    }
}

/// Gives each test case a ledger of the waits made for it off its task, failing
/// the case for each that failed (``OffTaskWaits``).
public struct OffTaskWaitsTrait: TestTrait, SuiteTrait, TestScoping {
    /// A trait on a suite scopes every case in it, nested suites included.
    public var isRecursive: Bool { true }

    /// Scopes each test case, never a suite or a parameterized function as a whole.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    /// Runs the test case through ``OffTaskWaits/scope(_:)``.
    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await OffTaskWaits.scope(function)
    }
}

extension Trait where Self == OffTaskWaitsTrait {
    /// Fails each test case for the waits made for it off its task that
    /// failed. `.caseScoped` includes it; a suite in a target that builds where
    /// `KernovaTestSupport` does not names this instead.
    public static var offTaskWaitsReported: Self { Self() }
}
#endif
