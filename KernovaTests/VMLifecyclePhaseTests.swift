import Foundation
import Testing

@testable import Kernova

@Suite("VMLifecyclePhase Tests", .admissionGated)
struct VMLifecyclePhaseTests {
    // MARK: - Fixture completeness

    @Test("The fixture list has every phase kind, so a case added later cannot go uncovered")
    func fixtureListIsComplete() {
        #expect(
            Set(VMLifecyclePhaseFixtures.all.map(\.kind)) == Set(VMLifecyclePhaseKind.allCases))
    }

    // MARK: - Status Projection

    @Test("Every phase projects the status its vocabulary names")
    func statusProjection() {
        let id = VMLifecyclePhaseFixtures.session
        let expected: [(VMLifecyclePhase, VMStatus)] = [
            (.stopped, .stopped),
            (.initialBoot, .initialBoot),
            (.failed(message: "Boot failed."), .error),
            (.suspended, .paused),
            (.capturingAtRest, .snapshotting),
            (.revertingToSnapshot, .restoring),
            (.starting(sessionID: nil), .starting),
            (.starting(sessionID: id), .starting),
            (.installing(sessionID: nil), .installing),
            (.installing(sessionID: id), .installing),
            (.restoringSavedState(sessionID: nil), .restoring),
            (.restoringSavedState(sessionID: id), .restoring),
            (.running(sessionID: id), .running),
            (.livePaused(sessionID: id), .paused),
            (.saving(sessionID: id), .saving),
            (.capturingLive(sessionID: id), .snapshotting),
        ]
        for (phase, status) in expected {
            #expect(phase.status == status, "\(phase)")
        }
        // Every case is answered above, so a new one cannot slip past the
        // projection unexamined.
        #expect(expected.count == VMLifecyclePhaseFixtures.all.count)
    }

    @Test("The failure message is a payload of the failed phase and of nothing else")
    func errorMessageBelongsToFailedAlone() {
        #expect(VMLifecyclePhase.failed(message: "Disk went away").errorMessage == "Disk went away")
        for phase in VMLifecyclePhaseFixtures.all where phase.status != .error {
            #expect(phase.errorMessage == nil, "\(phase)")
        }
    }

    // MARK: - Session Identity

    @Test("Only the phases a `VZVirtualMachine` can exist during name a session")
    func sessionIdentity() {
        let id = VMLifecyclePhaseFixtures.session
        #expect(VMLifecyclePhase.running(sessionID: id).sessionID == id)
        #expect(VMLifecyclePhase.livePaused(sessionID: id).sessionID == id)
        #expect(VMLifecyclePhase.saving(sessionID: id).sessionID == id)
        #expect(VMLifecyclePhase.capturingLive(sessionID: id).sessionID == id)
        #expect(VMLifecyclePhase.starting(sessionID: id).sessionID == id)
        #expect(VMLifecyclePhase.installing(sessionID: id).sessionID == id)
        #expect(VMLifecyclePhase.restoringSavedState(sessionID: id).sessionID == id)

        for phase in [
            VMLifecyclePhase.stopped, .initialBoot, .failed(message: "Boot failed."), .suspended,
            .capturingAtRest, .revertingToSnapshot, .starting(sessionID: nil),
            .installing(sessionID: nil), .restoringSavedState(sessionID: nil),
        ] {
            #expect(phase.sessionID == nil, "\(phase)")
        }
    }

    @Test("A bring-up promotes only the three phases it can start from")
    func promotionCoversTheBringUpPhases() {
        let id = VMLifecyclePhaseFixtures.session
        #expect(VMLifecyclePhase.starting(sessionID: nil).naming(id) == .starting(sessionID: id))
        #expect(
            VMLifecyclePhase.installing(sessionID: nil).naming(id) == .installing(sessionID: id))
        #expect(
            VMLifecyclePhase.restoringSavedState(sessionID: nil).naming(id)
                == .restoringSavedState(sessionID: id))

        // Every other phase is left alone rather than silently gaining an
        // identity it cannot carry.
        for phase in VMLifecyclePhaseFixtures.all where !phase.admitsSessionIdentity {
            #expect(phase.naming(id) == phase, "\(phase)")
        }
        #expect(!VMLifecyclePhase.stopped.admitsSessionIdentity)
        #expect(!VMLifecyclePhase.suspended.admitsSessionIdentity)
        #expect(!VMLifecyclePhase.running(sessionID: id).admitsSessionIdentity)
    }

    // MARK: - Transition Predicates

    @Test("The mid-operation phases are exactly the ones with work to interrupt")
    func isTransitioning() {
        let transitioning = Set(VMLifecyclePhaseFixtures.all.filter(\.isTransitioning).map { "\($0)" })
        #expect(
            transitioning
                == Set(
                    [
                        VMLifecyclePhase.starting(sessionID: nil),
                        .starting(sessionID: VMLifecyclePhaseFixtures.session),
                        .installing(sessionID: nil), .installing(sessionID: VMLifecyclePhaseFixtures.session),
                        .restoringSavedState(sessionID: nil),
                        .restoringSavedState(sessionID: VMLifecyclePhaseFixtures.session),
                        .saving(sessionID: VMLifecyclePhaseFixtures.session),
                        .capturingLive(sessionID: VMLifecyclePhaseFixtures.session),
                        .capturingAtRest, .revertingToSnapshot,
                    ].map { "\($0)" }))
    }

    @Test("terminationMustWaitOut covers the in-place writes and stays a subset of transitioning")
    func terminationMustWaitOut() {
        #expect(VMLifecyclePhase.saving(sessionID: VMLifecyclePhaseFixtures.session).terminationMustWaitOut)
        #expect(VMLifecyclePhase.capturingLive(sessionID: VMLifecyclePhaseFixtures.session).terminationMustWaitOut)
        #expect(VMLifecyclePhase.capturingAtRest.terminationMustWaitOut)
        // A restore keeps the file it reads until its resume succeeds, and a
        // start or install writes nothing a relaunch cannot redo.
        #expect(
            !VMLifecyclePhase.restoringSavedState(sessionID: VMLifecyclePhaseFixtures.session).terminationMustWaitOut)
        #expect(!VMLifecyclePhase.revertingToSnapshot.terminationMustWaitOut)
        #expect(!VMLifecyclePhase.starting(sessionID: VMLifecyclePhaseFixtures.session).terminationMustWaitOut)
        #expect(!VMLifecyclePhase.installing(sessionID: VMLifecyclePhaseFixtures.session).terminationMustWaitOut)

        for phase in VMLifecyclePhaseFixtures.all {
            #expect(!phase.terminationMustWaitOut || phase.isTransitioning, "\(phase)")
        }
    }

    @Test("isActive excludes both paused meanings and every resting phase")
    func isActive() {
        #expect(VMLifecyclePhase.running(sessionID: VMLifecyclePhaseFixtures.session).isActive)
        #expect(VMLifecyclePhase.capturingAtRest.isActive)
        #expect(VMLifecyclePhase.revertingToSnapshot.isActive)
        for phase in [
            VMLifecyclePhase.livePaused(sessionID: VMLifecyclePhaseFixtures.session), .suspended, .stopped,
            .failed(message: "Boot failed."), .initialBoot,
        ] {
            #expect(!phase.isActive, "\(phase)")
        }
    }

    // MARK: - Liveness

    @Test("A live session is the running and live-paused pair, and nothing else")
    func hasLiveSession() {
        #expect(VMLifecyclePhase.running(sessionID: VMLifecyclePhaseFixtures.session).hasLiveSession)
        #expect(VMLifecyclePhase.livePaused(sessionID: VMLifecyclePhaseFixtures.session).hasLiveSession)
        for phase in VMLifecyclePhaseFixtures.all
        where phase != .running(sessionID: VMLifecyclePhaseFixtures.session)
            && phase != .livePaused(sessionID: VMLifecyclePhaseFixtures.session)
        {
            #expect(!phase.hasLiveSession, "\(phase)")
        }
    }

    @Test("The two paused meanings are distinct and mutually exclusive")
    func pausedMeaningsAreDistinct() {
        #expect(VMLifecyclePhase.suspended.isColdPaused)
        #expect(!VMLifecyclePhase.suspended.isLivePaused)
        #expect(VMLifecyclePhase.livePaused(sessionID: VMLifecyclePhaseFixtures.session).isLivePaused)
        #expect(!VMLifecyclePhase.livePaused(sessionID: VMLifecyclePhaseFixtures.session).isColdPaused)
        // Both report the one status the wire has for them.
        #expect(VMLifecyclePhase.suspended.status == .paused)
        #expect(VMLifecyclePhase.livePaused(sessionID: VMLifecyclePhaseFixtures.session).status == .paused)
    }

    // MARK: - Command Predicates

    @Test("canStart covers the at-rest phases a boot can begin from")
    func canStart() {
        for phase in [
            VMLifecyclePhase.stopped, .failed(message: "Boot failed."), .initialBoot,
        ] {
            #expect(phase.canStart, "\(phase)")
        }
        for phase in VMLifecyclePhaseFixtures.all where !phase.canEditSettings {
            #expect(!phase.canStart, "\(phase)")
        }
        // A suspended VM resumes rather than starting.
        #expect(!VMLifecyclePhase.suspended.canStart)
        #expect(VMLifecyclePhase.suspended.canResume)
    }

    @Test("Stop, Suspend and Pause need a live session; Resume takes either paused meaning")
    func lifecycleCommands() {
        let running = VMLifecyclePhase.running(sessionID: VMLifecyclePhaseFixtures.session)
        let livePaused = VMLifecyclePhase.livePaused(sessionID: VMLifecyclePhaseFixtures.session)
        #expect(running.canStop && livePaused.canStop)
        #expect(running.canSave && livePaused.canSave)
        #expect(running.canPause && !livePaused.canPause)
        #expect(!running.canResume && livePaused.canResume)
        #expect(VMLifecyclePhase.suspended.canResume)
        #expect(!VMLifecyclePhase.suspended.canStop)
        #expect(!VMLifecyclePhase.suspended.canSave)
        for phase in VMLifecyclePhaseFixtures.all where phase.isTransitioning {
            #expect(
                !phase.canStop && !phase.canSave && !phase.canPause && !phase.canResume,
                "\(phase)")
        }
    }

    @Test("A rename is offered outside a transition and taken outside a restore")
    func renaming() {
        for phase in VMLifecyclePhaseFixtures.all {
            #expect(phase.canRename == !phase.isTransitioning, "\(phase)")
        }
        #expect(!VMLifecyclePhase.revertingToSnapshot.renamePersists)
        #expect(!VMLifecyclePhase.restoringSavedState(sessionID: VMLifecyclePhaseFixtures.session).renamePersists)
        for phase in VMLifecyclePhaseFixtures.all where phase.status != .restoring {
            #expect(phase.renamePersists, "\(phase)")
        }
    }

    @Test("canForceStop needs a live VM to terminate, and skips the install that owns its cancel")
    func canForceStop() {
        for phase in [
            VMLifecyclePhase.running(sessionID: VMLifecyclePhaseFixtures.session),
            .livePaused(sessionID: VMLifecyclePhaseFixtures.session),
            .saving(sessionID: VMLifecyclePhaseFixtures.session),
            .capturingLive(sessionID: VMLifecyclePhaseFixtures.session),
            .starting(sessionID: VMLifecyclePhaseFixtures.session),
            .restoringSavedState(sessionID: VMLifecyclePhaseFixtures.session),
        ] {
            #expect(phase.canForceStop, "\(phase)")
        }
        // A disks-only capture is a file copy, a revert tore its session down
        // first, and a start still assembling its configuration has none yet.
        for phase in [
            VMLifecyclePhase.capturingAtRest, .revertingToSnapshot, .suspended,
            .starting(sessionID: nil), .restoringSavedState(sessionID: nil),
            .installing(sessionID: VMLifecyclePhaseFixtures.session), .stopped, .initialBoot,
            .failed(message: "Boot failed."),
        ] {
            #expect(!phase.canForceStop, "\(phase)")
        }
    }

    @Test("hasActiveDisplay covers every phase whose backing view has something to show")
    func hasActiveDisplay() {
        for phase in [
            VMLifecyclePhase.running(sessionID: VMLifecyclePhaseFixtures.session),
            .livePaused(sessionID: VMLifecyclePhaseFixtures.session), .suspended,
            .saving(sessionID: VMLifecyclePhaseFixtures.session),
            .capturingLive(sessionID: VMLifecyclePhaseFixtures.session), .capturingAtRest,
            .restoringSavedState(sessionID: VMLifecyclePhaseFixtures.session), .revertingToSnapshot,
        ] {
            #expect(phase.hasActiveDisplay, "\(phase)")
        }
        for phase in [
            VMLifecyclePhase.stopped, .initialBoot, .failed(message: "Boot failed."),
            .starting(sessionID: VMLifecyclePhaseFixtures.session),
            .installing(sessionID: VMLifecyclePhaseFixtures.session),
        ] {
            #expect(!phase.hasActiveDisplay, "\(phase)")
        }
    }

    @Test("canEditSettings is exactly the set canStart admits")
    func canEditSettingsMatchesCanStart() {
        for phase in VMLifecyclePhaseFixtures.all {
            #expect(phase.canEditSettings == phase.canStart, "\(phase)")
        }
    }
}
