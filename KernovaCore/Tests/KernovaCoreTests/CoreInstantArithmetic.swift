import KernovaAgentCore

@testable import KernovaCore

extension CoreInstant {
    /// The instant `duration` later; tests only.
    static func + (lhs: CoreInstant, rhs: Duration) -> CoreInstant { lhs.advanced(by: CoreDuration(rhs)) }
}
