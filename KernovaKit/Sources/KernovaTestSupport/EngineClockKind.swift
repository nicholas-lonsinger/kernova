import Foundation

/// The two production `EngineClock` conformances, as a parameterization axis
/// for suites that must exercise both on every CI run.
///
/// `.continuous` names `ContinuousEngineClock` (macOS 13+); on a pre-13 runner
/// — where that clock cannot exist — helpers substitute the monotonic clock.
public enum EngineClockKind: String, CaseIterable, Sendable {
    case continuous
    case monotonic
}
