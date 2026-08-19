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
        await TestAdmission.admit()
        defer { TestAdmission.relinquish() }
        try await function()
    }
}

extension Trait where Self == AdmissionGateTrait {
    /// Runs this suite's test cases under the process-wide admission gate.
    static var admissionGated: Self { Self() }
}
