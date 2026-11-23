import Foundation
import KernovaCommandModel
import KernovaTestSupport
import Testing

@testable import KernovaCore
@testable import KernovaCoreTestSupport

/// The expectation tables below are written out independently of
/// ``VMAdmission``: each row is what the request should get in each column, so
/// a change to a declaration or to the settled switch shows up as a cell that
/// no longer matches.
@Suite("VMAdmission Tests", .caseScoped)
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

    /// The facts a table row varies; every other fact is a macOS guest with
    /// snapshots, a network device and USB passthrough.
    private struct Variant: Sendable, CustomStringConvertible {
        var guestOS: VMGuestOS = .macOS
        var pendingSetup = false
        var usbPassthroughGap: USBAccessoryPassthrough.Gap?
        var networkEnabled = true
        /// The saved state restores after a membership move — a NAT VM's.
        var survivesMembershipMove = false
        var writesOutsideBundle = false
        var reachesGuestAgent = true

        static let plain = Variant()
        static let natNetwork = Variant(survivesMembershipMove: true)
        static let linux = Variant(guestOS: .linux)
        static let pendingSetup = Variant(pendingSetup: true)
        static let linuxPendingSetup = Variant(guestOS: .linux, pendingSetup: true)
        static let noUSB = Variant(usbPassthroughGap: .needsEntitlement)
        static let noNetwork = Variant(networkEnabled: false)
        static let writesOutsideBundle = Variant(writesOutsideBundle: true)
        static let noAgentChannel = Variant(guestOS: .linux, reachesGuestAgent: false)

        var description: String {
            "\(guestOS) setup=\(pendingSetup) usbGap=\(String(describing: usbPassthroughGap)) "
                + "network=\(networkEnabled) "
                + "survivesMembershipMove=\(survivesMembershipMove) "
                + "writesOutsideBundle=\(writesOutsideBundle) reachesGuestAgent=\(reachesGuestAgent)"
        }
    }

    private static func facts(
        slot: Bool, _ variant: Variant, terminating: Bool = false, heldByAnotherCopy: Bool = false
    ) -> VMAdmission.Facts {
        VMAdmission.Facts(
            hasSaveFile: slot, hasSnapshots: true, guestOS: variant.guestOS,
            networkEnabled: variant.networkEnabled,
            savedStateSurvivesMembershipMove: variant.survivesMembershipMove,
            reachesGuestAgent: variant.reachesGuestAgent,
            hasPendingGuestSetup: variant.pendingSetup, usbPassthroughGap: variant.usbPassthroughGap,
            writesOutsideBundle: variant.writesOutsideBundle, identityConflict: nil,
            accessoryHolder: nil, terminating: terminating,
            heldByAnotherCopy: heldByAnotherCopy, stopRequestInFlight: false)
    }

    private static func facts(slot: Bool = false, pendingSetup: Bool = false) -> VMAdmission.Facts {
        facts(slot: slot, Variant(pendingSetup: pendingSetup))
    }

    /// One cell: `A` admit, `J` join, `B` busy with the held kind, `I`
    /// invalid state, `R` removed, `U` USB passthrough unavailable, `C` an
    /// identity conflict, `H` an accessory another attach holds, `T` refused
    /// by the app's termination, `O` refused as held by another copy, `S`
    /// taken only by a stopped VM, `E` an Ephemeral baseline that can't be read,
    /// `L` a symbolic link in the bundle, `W` waiting out a return to the
    /// Ephemeral baseline.
    private static func code(_ decision: VMAdmission.Decision, held: VMOperationKind?) -> Character {
        switch decision {
        case .admit: "A"
        case .join: "J"
        case .wait: "W"
        case .refuse(.busy(let kind)) where kind == held: "B"
        case .refuse(.busy): "?"
        case .refuse(.invalidState): "I"
        case .refuse(.removed): "R"
        case .refuse(.usbPassthroughUnavailable): "U"
        case .refuse(.identityConflict): "C"
        case .refuse(.accessoryHeld): "H"
        case .refuse(.terminating): "T"
        case .refuse(.heldByAnotherCopy): "O"
        case .refuse(.takesStoppedVM): "S"
        case .refuse(.ephemeralBaselineUnreadable): "E"
        case .refuse(.symbolicLinkInBundle): "L"
        case .refuse(.stopRequestInFlight): "G"
        // Raised by the catalog alone, never by admission.
        case .refuse(.guestPaused): "?"
        }
    }

    /// `expected` with the spaces grouping its columns taken out.
    private static func cells(_ expected: String) -> String {
        expected.filter { $0 != " " }
    }

    // MARK: - Settled phases × requests

    /// The settled answers where a fact other than the phase decides: the same
    /// columns, under the named variant.
    nonisolated private static let settledFactTable: [(Variant, VMAdmission.Request, String)] = [
        // Recovery is macOS's; a plain Start and the guest-agent disk are
        // every guest's.
        (.linux, .start(recovery: true), "IIIIIIR"),
        (.linux, .start(recovery: false), "AAAAIIR"),
        (.linux, .affordance(.guestAgentDisk), "IIIIAAR"),
        (.linux, .affordance(.guestAgentStatus), "IIIIAAR"),
        // A session with no channel to an agent has nothing to install into,
        // and no agent status to show.
        (.noAgentChannel, .affordance(.guestAgentDisk), "IIIIIIR"),
        (.noAgentChannel, .affordance(.guestAgentStatus), "IIIIIIR"),
        // A pending setup is what a Start runs, and nothing else boots the
        // VM until it has run — a saved state still restores.
        (.pendingSetup, .start(recovery: false), "AAAAIIR"),
        (.pendingSetup, .start(recovery: true), "IIIIIIR"),
        (.pendingSetup, .operation(.bringUp(.settingUp(.macOSInstall))), "AAAIIIR"),
        (.pendingSetup, .operation(.bringUp(.guestStart(.starting(recovery: false)))), "IIIIIIR"),
        (.pendingSetup, .operation(.bringUp(.guestStart(.starting(recovery: true)))), "IIIIIIR"),
        (.pendingSetup, .cancel(.guestSetup), "IIIIIIR"),
        (.linuxPendingSetup, .start(recovery: false), "AAAAIIR"),
        (.linuxPendingSetup, .operation(.bringUp(.settingUp(.linuxImageDownload))), "AAAIIIR"),
        // The clipboard is carried by the guest agent of macOS alone.
        (.linux, .affordance(.clipboard), "IIIIIIR"),
        (.noUSB, .edit(.pairingRules), "UUUUUUR"),
        (.noUSB, .operation(.attachingUSB(registryID: 7)), "UUUUUUR"),
        (.noUSB, .operation(.detachingUSB(deviceID: session)), "UUUUUUR"),
        (.noUSB, .edit(.hotPlugMedia), "AAAIAAR"),
        (.noNetwork, .edit(.networkAttachment), "AAAIIIR"),
        (.noNetwork, .edit(.networkMembership), "AAAIIIR"),
        // Only membership is open beside a saved state that survives a move.
        (.natNetwork, .edit(.networkMembership), "AAAAAAR"),
        (.natNetwork, .edit(.networkAttachment), "AAAIAAR"),
        (.natNetwork, .edit(.machineKeys), "AAAIIIR"),
        // A disk outside the bundle is not copied, so only a stopped VM is
        // cloned or snapshotted while its guest can write one: a capture with
        // memory would resume over the disk as written since.
        (.writesOutsideBundle, .operation(.copyingOut(.stopped)), "AAAIIIR"),
        (.writesOutsideBundle, .operation(.copyingOut(.suspended)), "IIISIIR"),
        (.writesOutsideBundle, .operation(.copyingOut(.live)), "IIIISSR"),
        (.writesOutsideBundle, .operation(.capturingSnapshot(.stopped)), "AIIIIIR"),
        (.writesOutsideBundle, .operation(.capturingSnapshot(.suspended)), "IIISIIR"),
        (.writesOutsideBundle, .operation(.capturingSnapshot(.live)), "IIIISSR"),
        // A Linux guest's shares ride a device each, so no swap keeps its
        // devices.
        (.linux, .edit(.liveShares), "IIIIIIR"),
    ]

    @Test(
        "A settled phase decides as the table states under every fact varied",
        arguments: settledFactTable.indices)
    func settledPhaseDecisionsUnderFacts(row: Int) {
        let (variant, request, expected) = Self.settledFactTable[row]
        #expect(Self.settledCells(request, variant) == expected, "\(request) \(variant)")
    }

    private static func settledCells(
        _ request: VMAdmission.Request, _ variant: Variant, terminating: Bool = false,
        heldByAnotherCopy: Bool = false, origin: VMRequestOrigin = .newWork,
        posture: VMAdmission.Posture = .commit
    ) -> String {
        String(
            settledColumns.map { column in
                code(
                    VMAdmission.decide(
                        request, origin: origin, posture: posture, phase: column.phase,
                        facts: facts(
                            slot: column.slot, variant, terminating: terminating,
                            heldByAnotherCopy: heldByAnotherCopy)),
                    held: nil)
            })
    }

    // MARK: - Termination

    /// The settled columns during the termination under each exempt origin:
    /// the one request it names decides as though nothing were terminating,
    /// and every other request is refused as new work is.
    nonisolated private static let exemptTable: [(VMRequestOrigin, VMAdmission.Request, String)] = [
        (.terminationSave, .operation(.saving), "IIIIAAR"),
        (.terminationSave, .start(recovery: false), "TTTTIIR"),
        (.terminationSave, .resume, "IIITITR"),
        (.terminationSave, .operation(.capturingSnapshot(.live)), "IIIITTR"),
        (.terminationSave, .operation(.bringUp(.reverting(snapshotID: session, resumesAfter: false))), "TTTTTTR"),
        (.terminationSave, .operation(.deleting), "TTTTIIR"),
        (.terminationSave, .edit(.hotPlugMedia), "AAAITTR"),
        (.sessionEndRevert, .operation(.bringUp(.reverting(snapshotID: session, resumesAfter: false))), "AAAAAAR"),
        (.sessionEndRevert, .operation(.bringUp(.reverting(snapshotID: session, resumesAfter: true))), "AAAAAAR"),
        (.sessionEndRevert, .start(recovery: false), "TTTTIIR"),
        (.sessionEndRevert, .resume, "IIITITR"),
        (.sessionEndRevert, .operation(.saving), "IIIITTR"),
        (.sessionEndRevert, .operation(.capturingSnapshot(.stopped)), "TIIIIIR"),
        (.sessionEndRevert, .operation(.deletingSnapshot), "TTTTTTR"),
        (.sessionEndRevert, .operation(.discardingSavedState), "IIITIIR"),
        (.mediaEditReconcile, .operation(.reconcilingMedia), "IIIIAAR"),
        (.mediaEditReconcile, .start(recovery: false), "TTTTIIR"),
        (.mediaEditReconcile, .operation(.pausing), "IIIITIR"),
        (.mediaEditReconcile, .operation(.saving), "IIIITTR"),
        (.mediaEditReconcile, .edit(.hotPlugMedia), "AAAITTR"),
    ]

    @Test(
        "During the termination an exempt origin exempts only the request it names",
        arguments: exemptTable.indices)
    func exemptOriginExemptsOnlyItsRequest(row: Int) {
        let (origin, request, expected) = Self.exemptTable[row]
        #expect(
            Self.settledCells(request, .plain, terminating: true, origin: origin) == expected,
            "\(request) \(origin)")
    }

    @Test("A share swap is tolerated by an operation that rests on the running guest, and by no other")
    func shareSwapDuringOperations() {
        let facts = Self.facts(slot: false, .plain)
        func decide(_ kind: VMOperationKind) -> VMAdmission.Decision {
            VMAdmission.decide(
                .edit(.liveShares), posture: .commit,
                phase: .operating(kind, from: Self.live, boundSession: nil), facts: facts)
        }
        for kind: VMOperationKind in [
            .attachingUSB(registryID: 7), .reconcilingMedia, .deletingSnapshot,
            .creatingRemovableMedia,
        ] {
            #expect(decide(kind) == .admit, "\(kind)")
        }
        // A pause ends live-paused, and a save or a capture pins the device.
        for kind: VMOperationKind in [.pausing, .saving, .capturingSnapshot(.live)] {
            #expect(decide(kind) == .refuse(.busy(kind)), "\(kind)")
        }
    }

    @Test("Whether a media change owes a reconcile is exactly whether the reconcile would not join")
    func owedReconcileAgreesWithTheJoin() {
        let facts = Self.facts(slot: false, .plain)
        let stoppingReconcile = VMLifecyclePhase.operating(
            VMOperation(
                kind: .reconcilingMedia, startedFrom: Self.live,
                sessionState: .live(
                    VMOperationSession(id: Self.session, guest: .running, stopping: VMOutcome())),
                outcome: VMOutcome()))
        let phases: [VMLifecyclePhase] =
            VMLifecyclePhaseFixtures.all + [stoppingReconcile]
        for phase in phases where phase.sessionID != nil {
            let decision = VMAdmission.decide(
                .operation(.reconcilingMedia), posture: .commit, phase: phase, facts: facts)
            let joins: Bool
            if case .join = decision { joins = true } else { joins = false }
            #expect(VMAdmission.owesMediaReconcile(phase) == !joins, "\(phase)")
        }
        // A Force Stop terminating a reconcile's session holds the VM as
        // `.forceStopping`, which carries no change: the reconcile is owed, not
        // joined.
        #expect(VMAdmission.owesMediaReconcile(stoppingReconcile))
        #expect(
            !VMAdmission.owesMediaReconcile(.operating(.reconcilingMedia, from: Self.live)))
    }

    // MARK: - Held kinds × requests

    /// Columns, grouped as each row's expectation spaces them:
    /// - Start, Start in Recovery, Resume;
    /// - Pause, Suspend, live capture, USB attach, media reconcile, Force Stop
    ///   operation;
    /// - stopped capture, suspended capture, discard, clone copy-out;
    /// - snapshot delete, revert, delete;
    /// - storage disk create, storage disk remove, removable disk create;
    /// - the edit classes M L H N P Nm S R O;
    /// - Stop, Force Stop, Cancel Setup, evict;
    /// - the affordances inspect, display, external display, clipboard,
    ///   guest-agent disk, guest-agent status.
    nonisolated private static let heldColumns: [VMAdmission.Request] = [
        .start(recovery: false), .start(recovery: true), .resume,
        .operation(.pausing), .operation(.saving), .operation(.capturingSnapshot(.live)),
        .operation(.attachingUSB(registryID: 7)), .operation(.reconcilingMedia),
        .operation(.forceStopping),
        .operation(.capturingSnapshot(.stopped)), .operation(.capturingSnapshot(.suspended)),
        .operation(.discardingSavedState), .operation(.copyingOut(.stopped)),
        .operation(.deletingSnapshot),
        .operation(.bringUp(.reverting(snapshotID: session, resumesAfter: false))),
        .operation(.deleting),
        .operation(.creatingStorageDisk), .operation(.removingStorageDisk),
        .operation(.creatingRemovableMedia),
        .edit(.machineKeys), .edit(.liveKeys), .edit(.hotPlugMedia), .edit(.networkAttachment),
        .edit(.hostPresentation), .edit(.rename), .edit(.snapshotMetadata), .edit(.pairingRules),
        .edit(.observations),
        .sessionAction(.requestStop), .sessionAction(.forceStop), .cancel(.guestSetup), .evict,
        .affordance(.inspect), .affordance(.display), .affordance(.externalDisplay),
        .affordance(.clipboard), .affordance(.guestAgentDisk), .affordance(.guestAgentStatus),
    ]

    private struct HeldRow: Sendable {
        let kind: VMOperationKind
        let startedFrom: VMLifecyclePhase
        var slot = false
        /// How the operation's session ended, when it already has.
        var sessionEnd: VMSessionEnd? = nil
        var variant = Variant.plain
        let expected: String
    }

    nonisolated private static let live = VMLifecyclePhase.running(sessionID: session)

    nonisolated private static let heldTable: [HeldRow] = [
        HeldRow(
            kind: .bringUp(.guestStart(.starting(recovery: false))), startedFrom: .stopped,
            expected: "JBI IIIIII BIIB BBB BBB BBBBAAAAA IIIB AIIIII"),
        // A plain Start joins a Recovery boot; Start in Recovery joins nothing.
        HeldRow(
            kind: .bringUp(.guestStart(.starting(recovery: true))), startedFrom: .stopped,
            expected: "JBI IIIIII BIIB BBB BBB BBBBAAAAA IIIB AIIIII"),
        HeldRow(
            kind: .bringUp(.guestStart(.restoringSavedState)), startedFrom: .suspended, slot: true,
            expected: "JIJ IIIIII IBBI BBB III IBIIAAAAA IIIB AAIIII"),
        HeldRow(
            kind: .bringUp(.settingUp(.macOSInstall)), startedFrom: .initialBoot,
            variant: .pendingSetup,
            expected: "BII IIIIII IIIB BBB BBB BBBBAAAAA IIAB AIIIII"),
        HeldRow(
            kind: .bringUp(.settingUp(.linuxImageDownload)), startedFrom: .initialBoot,
            variant: .linuxPendingSetup,
            expected: "BII IIIIII IIIB BBB BBB BBBBAAAAA IIAB AIIIII"),
        HeldRow(
            kind: .bringUp(.reverting(snapshotID: session, resumesAfter: true)),
            startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IBBBABAAA BBII AAIIII"),
        HeldRow(
            kind: .bringUp(.reverting(snapshotID: session, resumesAfter: false)),
            startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BBBBABAAA IIIB AAIIII"),
        // A removable-media edit, the guest-agent disk among them, is taken,
        // and the reconcile it owes waits for the operation to end.
        HeldRow(
            kind: .pausing, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IAAAAAAAA AAII AAAAAA"),
        HeldRow(
            kind: .resuming, startedFrom: .livePaused(sessionID: session),
            expected: "IIB IBBBBB IIII BBI IIB IAAAAAAAA AAII AAAIAA"),
        HeldRow(
            kind: .saving, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IBBBAAAAA BBII AAIIII"),
        HeldRow(
            kind: .capturingSnapshot(.live), startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IBBBAAAAA BBII AAIIII"),
        HeldRow(
            kind: .capturingSnapshot(.stopped), startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BBBBAAAAA IIIB AAIIII"),
        HeldRow(
            kind: .capturingSnapshot(.suspended), startedFrom: .suspended, slot: true,
            expected: "BIB IIIIII IBBI BBB III IBIIAAAAA IIIB AAIIII"),
        HeldRow(
            kind: .deletingSnapshot, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IAAAAABAA AAII AAAAAA"),
        HeldRow(
            kind: .attachingUSB(registryID: 7), startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IAAAAAAAA AAII AAAAAA"),
        HeldRow(
            kind: .detachingUSB(deviceID: session), startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IAAAAAAAA AAII AAAAAA"),
        // Removable-media edits, the guest-agent disk among them, coalesce
        // into the pass, and so does the reconcile one owes.
        HeldRow(
            kind: .reconcilingMedia, startedFrom: live,
            expected: "III BBBBJB IIII BBI IIB IAAAAAAAA AAII AAAAAA"),
        // Answered as the powered-off VM will answer, with a second Force Stop
        // joining the first and presentation and metadata edits taken; nothing
        // of the guest is presented, its display gone with the stop.
        HeldRow(
            kind: .forceStopping, startedFrom: live,
            expected: "BBI IIIIII BIIB BBB BBB BBBBAAAAA IJIB AIIIII"),
        HeldRow(
            kind: .discardingSavedState, startedFrom: .suspended, slot: true,
            expected: "BIB IIIIII IBBI BBB III IBIIBBBBB IIIB AAIIII"),
        HeldRow(
            kind: .deleting, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BBBBBBBBB IIIB AIIIII"),
        HeldRow(
            kind: .creatingStorageDisk, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BAAAAAAAA IIIB AIIIII"),
        HeldRow(
            kind: .removingStorageDisk, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BAAAAAAAA IIIB AIIIII"),
        // A live guest keeps taking a stop while the image is written and
        // attached.
        HeldRow(
            kind: .creatingRemovableMedia, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IAAAAAAAA AAII AAAAAA"),
        HeldRow(
            kind: .creatingRemovableMedia, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BAAAAAAAA IIIB AIIIII"),
        HeldRow(
            kind: .copyingOut(.stopped), startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BAAAAAAAA IIIB AIIIII"),
        // The slot stays for the copy's length, so neither a restore nor a
        // discard takes it.
        HeldRow(
            kind: .copyingOut(.suspended), startedFrom: .suspended, slot: true,
            expected: "BIB IIIIII IBBI BBB III IAIIAAAAA IIIB AAIIII"),
        // A live copy pins the guest as a live capture does.
        HeldRow(
            kind: .copyingOut(.live), startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IBBBAAAAA BBII AAIIII"),

        // Facts varied under a held operation.

        // A process without USB passthrough refuses it as unavailable whatever
        // holds the VM.
        HeldRow(
            kind: .deletingSnapshot, startedFrom: live, variant: .noUSB,
            expected: "III BBBUBB IIII BBI IIB IAAAAABUA AAII AAAAAA"),
        HeldRow(
            kind: .deleting, startedFrom: .stopped, variant: .noUSB,
            expected: "BBI IIIUII BIIB BBB BBB BBBBBBBUB IIIB AIIIII"),
        // Once the session ended, requests answer as the rest that end
        // implies: suspended where the slot survived it…
        HeldRow(
            kind: .saving, startedFrom: live, slot: true, sessionEnd: .endedByOperation,
            expected: "BIB IIIIII IBBI BBB III IBIIAAAAA IIIB AAIIII"),
        // …and failed after Virtualization stopped the guest with an error.
        HeldRow(
            kind: .pausing, startedFrom: live, sessionEnd: .stoppedWithError(message: "boom"),
            expected: "BII IIIIII IIIB BBB BBB AAAAAAAAA IIIB AIIIII"),
    ]

    @Test(
        "Every held kind decides every request as the table states",
        arguments: heldTable.indices)
    func heldKindDecisions(row: Int) {
        let held = Self.heldTable[row]
        let phase = VMLifecyclePhase.operating(
            held.kind, from: held.startedFrom, sessionEnd: held.sessionEnd)
        let facts = Self.facts(slot: held.slot, held.variant)
        let actual = String(
            Self.heldColumns.map {
                Self.code(
                    VMAdmission.decide($0, posture: .commit, phase: phase, facts: facts),
                    held: held.kind)
            })
        #expect(
            actual == Self.cells(held.expected),
            "\(held.kind) from \(held.startedFrom), \(String(describing: held.sessionEnd)), \(held.variant)")
    }

    // MARK: - Facts

    @Test("A bring-up whose identity another live VM holds is refused with the conflict")
    func identityConflictRefusesBringUps() {
        let mine = VMInstanceFixture.make(name: "Mine")
        let other = VMInstanceFixture.make(name: "Other")
        var facts = Self.facts()
        facts.identityConflict = VMIdentityConflict(
            vm: mine, other: other, reason: .macAddress, configuration: mine.configuration)
        let conflict = VMAdmission.Decision.refuse(.identityConflict(facts.identityConflict!))
        #expect(
            VMAdmission.decide(.start(recovery: false), posture: .commit, phase: .stopped, facts: facts)
                == conflict)
        #expect(
            VMAdmission.decide(
                .operation(.bringUp(.guestStart(.starting(recovery: false)))), posture: .commit,
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

    @Test("A bring-up that runs the guest is refused while the bundle holds a symbolic link; a revert to rest is not")
    func symbolicLinkInBundleRefusesBringUps() {
        let link = VMBundleItems.SymbolicLinkError(url: URL(filePath: "/VM.kernova/Disk.asif"))
        func facts(slot: Bool = false, pendingSetup: Bool = false) -> VMAdmission.Facts {
            var facts = Self.facts(slot: slot, pendingSetup: pendingSetup)
            facts.bundleSymbolicLink = link
            return facts
        }
        let refused = VMAdmission.Decision.refuse(.symbolicLinkInBundle(link))
        #expect(
            VMAdmission.decide(.start(recovery: false), posture: .commit, phase: .stopped, facts: facts())
                == refused)
        #expect(
            VMAdmission.decide(.start(recovery: true), posture: .commit, phase: .stopped, facts: facts())
                == refused)
        #expect(
            VMAdmission.decide(.resume, posture: .commit, phase: .suspended, facts: facts(slot: true))
                == refused)
        #expect(
            VMAdmission.decide(
                .start(recovery: false), posture: .commit, phase: .initialBoot,
                facts: facts(pendingSetup: true)) == refused)
        #expect(
            VMAdmission.decide(
                .operation(.bringUp(.reverting(snapshotID: Self.session, resumesAfter: true))),
                posture: .commit, phase: Self.live, facts: facts()) == refused)
        // The revert to rest replaces what the snapshot holds, and a hot
        // resume opens nothing.
        #expect(
            VMAdmission.decide(
                .operation(.bringUp(.reverting(snapshotID: Self.session, resumesAfter: false))),
                posture: .commit, phase: .stopped, facts: facts()) == .admit)
        #expect(
            VMAdmission.decide(
                .resume, posture: .commit, phase: .livePaused(sessionID: Self.session), facts: facts())
                == .admit)
    }
}
