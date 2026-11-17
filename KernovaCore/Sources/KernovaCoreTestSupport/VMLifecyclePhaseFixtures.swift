import Foundation

@testable import KernovaCore

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
