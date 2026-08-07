import Foundation
import KernovaKit

/// The two production `EngineClock` conformances, as a parameterization axis
/// for suites that must exercise both on every CI run.
///
/// `.continuous` names `ContinuousEngineClock` (macOS 13+); on a pre-13 runner
/// — where that clock cannot exist — helpers substitute the monotonic clock.
public enum EngineClockKind: String, CaseIterable, Sendable {
    case continuous
    case monotonic

    /// The concrete clock this kind names, erased for the caller's generic
    /// build function to open — the one kind-selection `#available` in tests.
    public func makeClock() -> any EngineClock {
        if self == .continuous, #available(macOS 13.0, *) {
            return ContinuousEngineClock()
        }
        return MonotonicEngineClock()
    }
}
