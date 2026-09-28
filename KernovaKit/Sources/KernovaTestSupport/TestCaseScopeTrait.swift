import Testing

/// Runs each test case in its own scope: admitted through the shared
/// `TestAdmission` gate before its body — and its setup — starts, and with a
/// scratch ledger in which every ``TestScratchDirectory`` it mints is recorded
/// and removed when the case ends.
///
/// Queued cases cost one suspended task and arm none of the test's own
/// backstops; the plan's execution-time allowance runs (`TestAdmission.width`).
/// The gate resolves to pass-through unless a width is configured.
public struct TestCaseScopeTrait: TestTrait, SuiteTrait, TestScoping {
    /// The trait scopes cases itself rather than vending a separate provider.
    public typealias TestScopeProvider = Self

    /// Recursive so a suite's annotation reaches the cases inside it, which is
    /// the only level that is scoped.
    public var isRecursive: Bool { true }

    /// Scopes test cases only. A suite-level scope would hold a permit for the
    /// whole suite while that suite's own cases queued for one, deadlocking at
    /// any width below the number of suites in flight.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    /// Runs the test case holding one admission permit and its own scratch
    /// ledger, removing the scratch and then returning the permit when it ends.
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // A case can reach this more than once — inherited from an outer suite
        // and again from a nested one that carries the trait itself. Only the
        // outermost scopes it: a second admission while holding the first is
        // what would deadlock the pool at any width below the number of such
        // cases in flight.
        guard TestScratchLedger.current == nil else {
            try await function()
            return
        }
        await TestAdmission.admit()
        defer { TestAdmission.relinquish() }
        try await TestScratchLedger.scoping(function)
    }
}

extension Trait where Self == TestCaseScopeTrait {
    /// Runs each of this suite's test cases in its own scope: admitted through
    /// the process-wide gate, with its scratch removed when it ends.
    public static var caseScoped: Self { Self() }
}
