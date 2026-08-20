import KernovaTestSupport
import Testing

/// Bounds how many test cases run concurrently in this process, admitting each
/// through the shared `TestAdmission` gate before its body — and its setup —
/// starts. Queued cases cost one suspended task and arm no clocks.
///
/// The gate resolves to pass-through unless a width is configured, so applying
/// this trait everywhere is inert by default.
struct AdmissionGateTrait: TestTrait, SuiteTrait, TestScoping {
    typealias TestScopeProvider = Self

    /// Recursive so a suite's annotation reaches the cases inside it, which is
    /// the only level that takes a permit.
    var isRecursive: Bool { true }

    /// Scopes test cases only. A suite-level scope would hold a permit for the
    /// whole suite while that suite's own cases queued for one, deadlocking at
    /// any width below the number of suites in flight.
    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // A case can reach this more than once — inherited from an outer suite
        // and again from a nested one that carries the trait itself. Only the
        // outermost takes a permit; a second acquisition while holding the first
        // is what would deadlock the pool.
        guard !TestAdmission.isAdmitted else {
            try await function()
            return
        }
        await TestAdmission.admit()
        defer { TestAdmission.relinquish() }
        try await TestAdmission.$isAdmitted.withValue(true) {
            try await function()
        }
    }
}

extension Trait where Self == AdmissionGateTrait {
    /// Runs this suite's test cases under the process-wide admission gate.
    static var admissionGated: Self { Self() }
}
