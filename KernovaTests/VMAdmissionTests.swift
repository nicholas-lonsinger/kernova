import Foundation
import KernovaKit
import KernovaTestSupport
import Testing

@testable import Kernova

/// The expectation tables below are written out independently of
/// ``VMAdmission``: each row is what the request should get in each column, so
/// a change to a declaration or to the settled switch shows up as a cell that
/// no longer matches.
@Suite("VMAdmission Tests", .admissionGated)
@MainActor
struct VMAdmissionTests {
    nonisolated private static let session = UUID()

    /// Every settled phase, with whether its bundle holds a suspend slot.
    nonisolated private static let settledColumns: [(phase: VMLifecyclePhase, slot: Bool)] = [
        (.stopped, false),
        (.initialBoot, false),
        (.failed(message: "boom"), false),
        (.suspended, true),
        (.running(sessionID: session), false),
        (.livePaused(sessionID: session), false),
        (.removed, false),
    ]

    private static func facts(
        slot: Bool = false, pendingSetup: Bool = false, clone: Bool = false,
        networkEnabled: Bool = true, usbSupported: Bool = true
    ) -> VMAdmission.Facts {
        VMAdmission.Facts(
            hasSaveFile: slot, hasSnapshots: true, guestOS: .macOS,
            networkEnabled: networkEnabled, clipboardSharingEnabled: true,
            hasPendingGuestSetup: pendingSetup, usbSupported: usbSupported,
            cloneInFlight: clone, identityConflict: nil)
    }

    /// One cell: `A` admit, `J` join, `B` busy with the held kind, `I` invalid
    /// state, `R` removed, `U` unsupported by this build.
    private static func code(_ decision: VMAdmission.Decision, held: VMOperationKind?) -> Character {
        switch decision {
        case .admit: "A"
        case .join: "J"
        case .refuse(.busy(let kind)): kind == held ? "B" : "b"
        case .refuse(.invalidState): "I"
        case .refuse(.removed): "R"
        case .refuse(.unsupportedByBuild): "U"
        case .refuse(.identityConflict): "C"
        }
    }

    // MARK: - Settled phases × requests

    /// Columns: stopped, initialBoot, failed, suspended (slot), running,
    /// livePaused, removed.
    nonisolated private static let settledTable: [(VMAdmission.Request, String)] = [
        (.start(recovery: false), "AAAAIIR"),
        (.start(recovery: true), "AIIIIIR"),
        (.resume, "IIIAIAR"),
        (.operation(.bringUp(.starting(recovery: false))), "AAAIIIR"),
        (.operation(.bringUp(.restoringSavedState)), "IIIAIIR"),
        (.operation(.bringUp(.settingUp(.macOSInstall))), "IIIIIIR"),
        (.operation(.bringUp(.reverting(snapshotID: session, resumesAfter: false))), "AAAAAAR"),
        (.operation(.pausing), "IIIIAIR"),
        (.operation(.resuming), "IIIIIAR"),
        (.operation(.saving), "IIIIAAR"),
        (.operation(.capturingSnapshot(.live)), "IIIIAAR"),
        (.operation(.capturingSnapshot(.suspended)), "IIIAIIR"),
        (.operation(.capturingSnapshot(.stopped)), "AIIIIIR"),
        (.operation(.deletingSnapshot), "AAAAAAR"),
        (.operation(.attachingUSB(registryID: 7)), "IIIIAAR"),
        (.operation(.detachingUSB(deviceID: session)), "IIIIAAR"),
        (.operation(.reconcilingMedia), "IIIIAAR"),
        (.operation(.forceStopping), "IIIIAAR"),
        (.operation(.discardingSavedState), "IIIAIIR"),
        (.operation(.deleting), "AAAAIIR"),
        (.operation(.copyingOut), "AAAIIIR"),
        (.edit(.machineKeys), "AAAIIIR"),
        (.edit(.liveKeys), "AAAAAAR"),
        (.edit(.hotPlugMedia), "AAAIAAR"),
        (.edit(.networkAttachment), "AAAIAAR"),
        (.edit(.hostPresentation), "AAAAAAR"),
        (.edit(.snapshotMetadata), "AAAAAAR"),
        (.edit(.pairingRules), "AAAAAAR"),
        (.edit(.rename), "AAAAAAR"),
        (.edit(.observations), "AAAAAAR"),
        (.sessionAction(.requestStop), "IIIIAAR"),
        (.sessionAction(.forceStop), "IIIIAAR"),
        (.cancel(.guestSetup), "IIIIIIR"),
        (.evict, "AAAAIIR"),
        (.affordance(.inspect), "AAAAAAR"),
        (.affordance(.display), "IIIAAAR"),
        (.affordance(.externalDisplay), "IIIIAAR"),
        (.affordance(.clipboard), "IIIIAAR"),
        (.affordance(.guestAgentDisk), "IIIIAAR"),
    ]

    @Test(
        "Every settled phase decides every request as the table states",
        arguments: settledTable.indices)
    func settledPhaseDecisions(row: Int) {
        let (request, expected) = Self.settledTable[row]
        let actual = String(
            Self.settledColumns.map { column in
                Self.code(
                    VMAdmission.decide(
                        request, posture: .commit, phase: column.phase,
                        facts: Self.facts(slot: column.slot)),
                    held: nil)
            })
        #expect(actual == expected, "\(request)")
    }

    // MARK: - Held kinds × requests

    /// Columns: Start, Start in Recovery, Resume, Pause, Suspend, live capture,
    /// snapshot delete, revert, delete, then the edit classes M L H N P Nm S,
    /// then Stop, Force Stop, Cancel Setup, evict.
    nonisolated private static let heldColumns: [VMAdmission.Request] = [
        .start(recovery: false), .start(recovery: true), .resume,
        .operation(.pausing), .operation(.saving), .operation(.capturingSnapshot(.live)),
        .operation(.deletingSnapshot),
        .operation(.bringUp(.reverting(snapshotID: session, resumesAfter: false))),
        .operation(.deleting),
        .edit(.machineKeys), .edit(.liveKeys), .edit(.hotPlugMedia), .edit(.networkAttachment),
        .edit(.hostPresentation), .edit(.rename), .edit(.snapshotMetadata),
        .sessionAction(.requestStop), .sessionAction(.forceStop), .cancel(.guestSetup), .evict,
    ]

    private struct HeldRow: Sendable {
        let kind: VMOperationKind
        let startedFrom: VMLifecyclePhase
        let slot: Bool
        let pendingSetup: Bool
        let expected: String
    }

    nonisolated private static let live = VMLifecyclePhase.running(sessionID: session)

    nonisolated private static let heldTable: [HeldRow] = [
        HeldRow(
            kind: .bringUp(.starting(recovery: false)), startedFrom: .stopped, slot: false,
            pendingSetup: false, expected: "JBIIIIBBB" + "BBBBAAA" + "IIIB"),
        HeldRow(
            kind: .bringUp(.restoringSavedState), startedFrom: .suspended, slot: true,
            pendingSetup: false, expected: "JIJIIIBBB" + "IBIIAAA" + "IIIB"),
        HeldRow(
            kind: .bringUp(.settingUp(.macOSInstall)), startedFrom: .initialBoot, slot: false,
            pendingSetup: true, expected: "BIIIIIBBB" + "BBBBAAA" + "IIAB"),
        HeldRow(
            kind: .bringUp(.reverting(snapshotID: session, resumesAfter: true)),
            startedFrom: live, slot: false, pendingSetup: false,
            expected: "IIIBBBBBI" + "IBBBABA" + "BBII"),
        HeldRow(
            kind: .pausing, startedFrom: live, slot: false, pendingSetup: false,
            expected: "IIIBBBBBI" + "IABAAAA" + "AAII"),
        HeldRow(
            kind: .resuming, startedFrom: .livePaused(sessionID: session), slot: false,
            pendingSetup: false, expected: "IIBIBBBBI" + "IABAAAA" + "AAII"),
        HeldRow(
            kind: .saving, startedFrom: live, slot: false, pendingSetup: false,
            expected: "IIIBBBBBI" + "IBBBAAA" + "BBII"),
        HeldRow(
            kind: .capturingSnapshot(.live), startedFrom: live, slot: false, pendingSetup: false,
            expected: "IIIBBBBBI" + "IBBBAAA" + "BBII"),
        HeldRow(
            kind: .capturingSnapshot(.stopped), startedFrom: .stopped, slot: false,
            pendingSetup: false, expected: "BBIIIIBBB" + "BBBBAAA" + "IIIB"),
        HeldRow(
            kind: .deletingSnapshot, startedFrom: live, slot: false, pendingSetup: false,
            expected: "IIIBBBBBI" + "IABAAAB" + "AAII"),
        HeldRow(
            kind: .attachingUSB(registryID: 7), startedFrom: live, slot: false,
            pendingSetup: false, expected: "IIIBBBBBI" + "IABAAAA" + "AAII"),
        HeldRow(
            kind: .reconcilingMedia, startedFrom: live, slot: false, pendingSetup: false,
            expected: "IIIBBBBBI" + "IAAAAAA" + "AAII"),
        // Answered as the powered-off VM will answer, with a second Force Stop
        // joining the first.
        HeldRow(
            kind: .forceStopping, startedFrom: live, slot: false, pendingSetup: false,
            expected: "BBIIIIBBB" + "BBBBBBB" + "IJIB"),
        HeldRow(
            kind: .deleting, startedFrom: .stopped, slot: false, pendingSetup: false,
            expected: "BBIIIIBBB" + "BBBBBBB" + "IIIB"),
    ]

    private static func holding(_ row: HeldRow) -> VMLifecyclePhase {
        .operating(row.kind, from: row.startedFrom)
    }

    @Test(
        "Every held kind decides every request as the table states",
        arguments: heldTable.indices)
    func heldKindDecisions(row: Int) {
        let held = Self.heldTable[row]
        let phase = Self.holding(held)
        let facts = Self.facts(slot: held.slot, pendingSetup: held.pendingSetup)
        let actual = String(
            Self.heldColumns.map {
                Self.code(
                    VMAdmission.decide($0, posture: .commit, phase: phase, facts: facts),
                    held: held.kind)
            })
        #expect(actual == held.expected, "\(held.kind)")
    }

    @Test("A join hands back the held operation's own outcome")
    func joinCarriesTheHeldOutcome() {
        let outcome = VMOutcome()
        let phase = VMLifecyclePhase.operating(
            VMOperation(
                kind: .bringUp(.starting(recovery: false)), startedFrom: .stopped,
                sessionState: .none, outcome: outcome))
        #expect(
            VMAdmission.decide(
                .start(recovery: false), posture: .commit, phase: phase, facts: Self.facts())
                == .join(outcome))
    }

    // MARK: - Posture

    @Test("Offering Start names Resume for a VM holding a saved state; committing it restores")
    func startOfferVersusCommitOnASlot() {
        let facts = Self.facts(slot: true)
        #expect(
            VMAdmission.decide(
                .start(recovery: false), posture: .offer, phase: .suspended, facts: facts)
                == .refuse(.invalidState))
        #expect(
            VMAdmission.decide(
                .start(recovery: false), posture: .commit, phase: .suspended, facts: facts)
                == .admit)
        #expect(
            VMAdmission.bringUpKind(
                for: .start(recovery: false), phase: .suspended, facts: facts)
                == .restoringSavedState)
    }

    @Test("A bring-up is joined only on commit; offered, it reads as busy")
    func joinIsCommitOnly() {
        let phase = VMLifecyclePhase.operating(
            VMOperation(
                kind: .bringUp(.restoringSavedState), startedFrom: .suspended,
                sessionState: .none, outcome: VMOutcome()))
        let facts = Self.facts(slot: true)
        #expect(
            VMAdmission.decide(.resume, posture: .offer, phase: phase, facts: facts)
                == .refuse(.busy(.bringUp(.restoringSavedState))))
        #expect(
            VMAdmission.decide(.start(recovery: false), posture: .offer, phase: phase, facts: facts)
                == .refuse(.invalidState))
    }

    // MARK: - Facts

    @Test("A clone copying the VM's files holds what writes or reads them as busy")
    func cloneInFlightIsBusy() {
        let facts = Self.facts(clone: true)
        let busy = VMAdmission.Decision.refuse(.busy(.copyingOut))
        for request: VMAdmission.Request in [
            .start(recovery: false), .start(recovery: true), .edit(.machineKeys),
            .operation(.deleting),
            .operation(.bringUp(.reverting(snapshotID: Self.session, resumesAfter: false))),
        ] {
            #expect(
                VMAdmission.decide(request, posture: .commit, phase: .stopped, facts: facts)
                    == busy, "\(request)")
        }
        // Every bring-up writes the bundle's files, whatever Start or Resume
        // resolved it to.
        let slot = Self.facts(slot: true, clone: true)
        for request: VMAdmission.Request in [
            .start(recovery: false), .resume, .operation(.bringUp(.restoringSavedState)),
        ] {
            #expect(
                VMAdmission.decide(request, posture: .commit, phase: .suspended, facts: slot)
                    == busy, "\(request)")
        }
        let setup = Self.facts(pendingSetup: true, clone: true)
        for request: VMAdmission.Request in [
            .start(recovery: false), .operation(.bringUp(.settingUp(.macOSInstall))),
        ] {
            #expect(
                VMAdmission.decide(request, posture: .commit, phase: .initialBoot, facts: setup)
                    == busy, "\(request)")
        }
        #expect(
            VMAdmission.decide(.edit(.liveKeys), posture: .commit, phase: .stopped, facts: facts)
                == .admit)
        #expect(
            VMAdmission.decide(.operation(.copyingOut), posture: .commit, phase: .stopped, facts: facts)
                == .admit)
    }

    @Test(
        "Start and Resume decide as the operation they resolve to, over every settled phase and fact",
        arguments: [false, true], [false, true])
    func startAndResumeDecideAsTheirOperation(slot: Bool, pendingSetup: Bool) {
        for clone in [false, true] {
            for guestOS in [VMGuestOS.macOS, .linux] {
                var facts = Self.facts(slot: slot, pendingSetup: pendingSetup, clone: clone)
                facts.guestOS = guestOS
                for column in Self.settledColumns where column.phase != .removed {
                    for request: VMAdmission.Request in [
                        .start(recovery: false), .start(recovery: true), .resume,
                    ] {
                        let decided = VMAdmission.decide(
                            request, posture: .commit, phase: column.phase, facts: facts)
                        let kind = VMAdmission.operationKind(
                            for: request, phase: column.phase, facts: facts)
                        let expected =
                            kind.map {
                                VMAdmission.decide(
                                    .operation($0), posture: .commit, phase: column.phase,
                                    facts: facts)
                            } ?? .refuse(.invalidState)
                        #expect(
                            decided == expected,
                            "\(request) \(column.phase) clone=\(clone) \(guestOS)")
                    }
                }
            }
        }
    }

    @Test("Start in Recovery is a Recovery boot or nothing: a VM that cannot take one refuses it")
    func recoveryStartNeverFallsThroughToAnotherBringUp() {
        for (phase, facts) in [
            (VMLifecyclePhase.stopped, Self.facts(pendingSetup: true)),
            (.suspended, Self.facts(slot: true)),
            (.initialBoot, Self.facts()),
        ] {
            #expect(
                VMAdmission.bringUpKind(for: .start(recovery: true), phase: phase, facts: facts)
                    == .starting(recovery: true))
            #expect(
                VMAdmission.decide(.start(recovery: true), posture: .commit, phase: phase, facts: facts)
                    == .refuse(.invalidState), "\(phase)")
        }
        var linux = Self.facts()
        linux.guestOS = .linux
        #expect(
            VMAdmission.decide(.start(recovery: true), posture: .commit, phase: .stopped, facts: linux)
                == .refuse(.invalidState))
    }

    @Test("A bring-up whose identity another live VM holds is refused with the conflict")
    func identityConflictRefusesBringUps() {
        let mine = VMInstanceFixture.make(name: "Mine")
        let other = VMInstanceFixture.make(name: "Other")
        var facts = Self.facts()
        facts.identityConflict = VMIdentityConflict(vm: mine, other: other, reason: .macAddress)
        let conflict = VMAdmission.Decision.refuse(.identityConflict(facts.identityConflict!))
        #expect(
            VMAdmission.decide(.start(recovery: false), posture: .commit, phase: .stopped, facts: facts)
                == conflict)
        #expect(
            VMAdmission.decide(
                .operation(.bringUp(.starting(recovery: false))), posture: .commit,
                phase: .stopped, facts: facts) == conflict)
        // A revert that resumes brings the snapshot's configuration up; one
        // that rests brings nothing up.
        #expect(
            VMAdmission.decide(
                .operation(.bringUp(.reverting(snapshotID: Self.session, resumesAfter: true))),
                posture: .commit, phase: Self.live, facts: facts) == conflict)
        #expect(
            VMAdmission.decide(
                .operation(.bringUp(.reverting(snapshotID: Self.session, resumesAfter: false))),
                posture: .commit, phase: .stopped, facts: facts) == .admit)
    }

    @Test("A build that cannot pass USB accessories through refuses their operations as unsupported")
    func usbUnsupportedByBuild() {
        #expect(
            VMAdmission.decide(
                .operation(.attachingUSB(registryID: 1)), posture: .commit, phase: Self.live,
                facts: Self.facts(usbSupported: false)) == .refuse(.unsupportedByBuild))
        #expect(
            VMAdmission.decide(
                .edit(.pairingRules), posture: .commit, phase: .stopped,
                facts: Self.facts(usbSupported: false)) == .refuse(.unsupportedByBuild))
    }

    @Test("A VM with no network device takes no live attachment swap")
    func networkAttachmentNeedsANetwork() {
        #expect(
            VMAdmission.decide(
                .edit(.networkAttachment), posture: .commit, phase: Self.live,
                facts: Self.facts(networkEnabled: false)) == .refuse(.invalidState))
    }

    @Test("Discarding the saved state reopens the edits the slot pinned")
    func discardingSavedStateCounterfactual() {
        let facts = Self.facts(slot: true)
        #expect(
            VMAdmission.decide(.edit(.machineKeys), posture: .commit, phase: .failed(message: "x"), facts: facts)
                == .refuse(.invalidState))
        #expect(
            VMAdmission.decide(
                .edit(.machineKeys), posture: .commit, phase: .failed(message: "x"),
                facts: facts.discardingSavedState()) == .admit)
    }

    @Test("Once an operation's session ended, a request is classified against where that end rests the VM")
    func endedSessionIsClassifiedAtRest() {
        let phase = VMLifecyclePhase.operating(
            VMOperation(
                kind: .reconcilingMedia, startedFrom: Self.live, sessionState: .ended(.poweredOff),
                outcome: VMOutcome()))
        let facts = Self.facts()
        // Taken once the pass ends at rest, so busy rather than invalid.
        #expect(
            VMAdmission.decide(.start(recovery: false), posture: .commit, phase: phase, facts: facts)
                == .refuse(.busy(.reconcilingMedia)))
        #expect(
            VMAdmission.decide(.operation(.pausing), posture: .commit, phase: phase, facts: facts)
                == .refuse(.invalidState))
        // No session left to stop.
        #expect(
            VMAdmission.decide(
                .sessionAction(.requestStop), posture: .commit, phase: phase, facts: facts)
                == .refuse(.invalidState))
    }

    @Test("A session a Force Stop is terminating takes nothing new, and a second Force Stop joins it")
    func stoppingSessionTakesNothingNew() {
        let stop = VMOutcome()
        let phase = VMLifecyclePhase.operating(
            VMOperation(
                kind: .pausing, startedFrom: Self.live,
                sessionState: .live(
                    VMOperationSession(id: Self.session, guest: .running, stopping: stop)),
                outcome: VMOutcome()))
        let facts = Self.facts()
        func decide(_ request: VMAdmission.Request, _ posture: VMAdmission.Posture = .commit)
            -> VMAdmission.Decision
        {
            VMAdmission.decide(request, posture: posture, phase: phase, facts: facts)
        }
        #expect(decide(.sessionAction(.forceStop)) == .join(stop))
        #expect(decide(.sessionAction(.forceStop), .offer) == .refuse(.busy(.forceStopping)))
        // What the powered-off VM refuses is refused; what it takes waits.
        for request: VMAdmission.Request in [
            .operation(.saving), .resume, .operation(.pausing), .sessionAction(.requestStop),
        ] {
            #expect(decide(request) == .refuse(.invalidState), "\(request)")
        }
        for request: VMAdmission.Request in [
            .start(recovery: false), .edit(.hostPresentation), .edit(.machineKeys),
            .operation(.bringUp(.reverting(snapshotID: Self.session, resumesAfter: false))),
        ] {
            #expect(decide(request) == .refuse(.busy(.forceStopping)), "\(request)")
        }
        // A slot that survives the session is what the VM will rest on.
        #expect(
            VMAdmission.decide(.resume, posture: .commit, phase: phase, facts: Self.facts(slot: true))
                == .refuse(.busy(.forceStopping)))
    }

    @Test("A capture is offered in the mode of where an operation's ended session rests the VM")
    func captureModeReadsTheSessionEnd() {
        let live = VMLifecyclePhase.operating(
            VMOperation(
                kind: .deletingSnapshot, startedFrom: Self.live,
                sessionState: .live(VMOperationSession(id: Self.session, guest: .running)),
                outcome: VMOutcome()))
        let ended = VMLifecyclePhase.operating(
            VMOperation(
                kind: .deletingSnapshot, startedFrom: Self.live, sessionState: .ended(.poweredOff),
                outcome: VMOutcome()))
        #expect(VMAdmission.settledCaptureMode(phase: live, facts: Self.facts()) == .live)
        #expect(VMAdmission.settledCaptureMode(phase: ended, facts: Self.facts()) == .stopped)
        #expect(
            VMAdmission.settledCaptureMode(phase: ended, facts: Self.facts(slot: true)) == .suspended)
    }

    // MARK: - Projections

    @Test("An operation that presents its base changes nothing a surface reads")
    func baseStatusKindsPresentTheirStart() {
        let phase = VMLifecyclePhase.operating(
            VMOperation(
                kind: .attachingUSB(registryID: 1), startedFrom: Self.live,
                sessionState: .live(VMOperationSession(id: Self.session, guest: .running)),
                outcome: VMOutcome()))
        #expect(phase.status == .running)
        #expect(phase.hasLiveSession)
        #expect(phase.hasActiveDisplay)
        #expect(phase.sessionID == Self.session)
        #expect(phase.holdsLiveIdentity)
    }

    @Test("An operation whose session ended presents stopped")
    func endedSessionPresentsStopped() {
        let phase = VMLifecyclePhase.operating(
            VMOperation(
                kind: .pausing, startedFrom: Self.live, sessionState: .ended(.poweredOff),
                outcome: VMOutcome()))
        #expect(phase.status == .stopped)
        #expect(!phase.hasLiveSession)
        #expect(phase.sessionID == nil)
        #expect(!phase.holdsLiveIdentity)
    }

    @Test("An operation with a status of its own shows it")
    func declaredStatus() {
        let saving = VMLifecyclePhase.operating(
            VMOperation(
                kind: .saving, startedFrom: Self.live,
                sessionState: .live(VMOperationSession(id: Self.session, guest: .running)),
                outcome: VMOutcome()))
        #expect(saving.status == .saving)
        #expect(!saving.hasLiveSession)
        #expect(saving.sessionID == Self.session)
    }
}
