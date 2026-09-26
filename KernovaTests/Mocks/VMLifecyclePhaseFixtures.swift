import Foundation
@testable import Kernova

/// The case a ``VMLifecyclePhase`` belongs to, with no associated value —
/// `VMLifecyclePhase` cannot be `CaseIterable` itself because of those, so
/// this is what lets ``VMLifecyclePhaseFixtures/all`` be checked against
/// `allCases` rather than trusted by inspection.
enum VMLifecyclePhaseKind: CaseIterable, Hashable {
    case stopped
    case initialBoot
    case failed
    case suspended
    case running
    case livePaused
    case operating
    case removed
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
        case .suspended: .suspended
        case .running: .running
        case .livePaused: .livePaused
        case .operating: .operating
        case .removed: .removed
        }
    }
}

/// Every settled `VMLifecyclePhase` case, and an operation of each
/// declaration shape, shared by the suites that sweep all of them.
@MainActor
enum VMLifecyclePhaseFixtures {
    /// A stand-in session identity: a live phase names the `VZVirtualMachine`
    /// it describes, and no CI test host can create one.
    nonisolated static let session = UUID()

    nonisolated static let settled: [VMLifecyclePhase] = [
        .stopped,
        .initialBoot,
        .failed(message: "Boot failed."),
        .suspended,
        .running(sessionID: session),
        .livePaused(sessionID: session),
        .removed,
    ]

    /// One operation per declared status, identity and edit shape, with a
    /// bring-up both before and after it bound its session.
    static let operations: [VMLifecyclePhase] = {
        let live = VMLifecyclePhase.running(sessionID: session)
        return [
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped),
            .operating(.bringUp(.guestStart(.starting(recovery: false))), from: .stopped, boundSession: session),
            .operating(.bringUp(.guestStart(.restoringSavedState)), from: .suspended),
            .operating(.bringUp(.settingUp(.macOSInstall)), from: .initialBoot),
            .operating(
                .bringUp(.reverting(snapshotID: session, resumesAfter: true)), from: live),
            .operating(.pausing, from: live),
            .operating(.resuming, from: .livePaused(sessionID: session)),
            .operating(.saving, from: live),
            .operating(.capturingSnapshot(.live), from: live),
            .operating(.capturingSnapshot(.stopped), from: .stopped),
            .operating(.deletingSnapshot, from: live),
            .operating(.attachingUSB(registryID: 1), from: live),
            .operating(.reconcilingMedia, from: live),
            .operating(.forceStopping, from: live),
            .operating(.deleting, from: .stopped),
            .operating(.creatingStorageDisk, from: .stopped),
            .operating(.creatingRemovableMedia, from: live),
            // At rest, where a snapshot delete tolerates a machine-key edit
            // and still refuses every other operation.
            .operating(.deletingSnapshot, from: .stopped),
        ]
    }()

    static let all: [VMLifecyclePhase] = settled + operations
}
