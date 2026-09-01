import Foundation
@testable import Kernova

/// The case a ``VMLifecyclePhase`` belongs to, with no associated value —
/// `VMLifecyclePhase` cannot be `CaseIterable` itself because of those, so
/// this is what lets ``VMLifecyclePhaseFixtures/all`` be checked against
/// `allCases` rather than trusted by inspection.
enum VMLifecyclePhaseKind: CaseIterable {
    case stopped
    case initialBoot
    case failed
    case installing
    case starting
    case running
    case livePaused
    case saving
    case capturingLive
    case restoringSavedState
    case suspended
    case capturingAtRest
    case revertingToSnapshot
}

extension VMLifecyclePhase {
    /// This phase's ``VMLifecyclePhaseKind``.
    ///
    /// Exhaustive rather than `default`, so a case added to `VMLifecyclePhase`
    /// fails this switch's compile instead of silently under-covering
    /// ``VMLifecyclePhaseFixtures/all``.
    var kind: VMLifecyclePhaseKind {
        switch self {
        case .stopped: .stopped
        case .initialBoot: .initialBoot
        case .failed: .failed
        case .installing: .installing
        case .starting: .starting
        case .running: .running
        case .livePaused: .livePaused
        case .saving: .saving
        case .capturingLive: .capturingLive
        case .restoringSavedState: .restoringSavedState
        case .suspended: .suspended
        case .capturingAtRest: .capturingAtRest
        case .revertingToSnapshot: .revertingToSnapshot
        }
    }
}

/// Every `VMLifecyclePhase` case, shared by the suites that sweep all of
/// them — the sessionless and session-bearing variants of the three phases
/// that admit either, `starting`, `installing` and `restoringSavedState`.
///
/// A test asserting `Set(all.map(\.kind)) == Set(VMLifecyclePhaseKind.allCases)`
/// is what keeps this list complete: the kind switch above cannot be
/// answered without a case, and this constant cannot claim completeness
/// without listing it.
enum VMLifecyclePhaseFixtures {
    /// A stand-in session identity: a live phase names the `VZVirtualMachine`
    /// it describes, and no CI test host can create one.
    static let session = UUID()

    static let all: [VMLifecyclePhase] = [
        .stopped,
        .initialBoot,
        .failed(message: "Boot failed."),
        .suspended,
        .capturingAtRest,
        .revertingToSnapshot,
        .starting(sessionID: nil),
        .installing(sessionID: nil),
        .restoringSavedState(sessionID: nil),
        .starting(sessionID: session),
        .installing(sessionID: session),
        .restoringSavedState(sessionID: session),
        .running(sessionID: session),
        .livePaused(sessionID: session),
        .saving(sessionID: session),
        .capturingLive(sessionID: session),
    ]
}
