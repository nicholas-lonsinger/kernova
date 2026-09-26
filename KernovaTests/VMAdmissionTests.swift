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

    /// The facts a table row varies; every other fact is a macOS guest with
    /// snapshots, a network device, clipboard sharing and USB passthrough.
    private struct Variant: Sendable, CustomStringConvertible {
        var guestOS: VMGuestOS = .macOS
        var pendingSetup = false
        var clone = false
        var usbSupported = true
        var networkEnabled = true
        var clipboardSharing = true

        static let plain = Variant()
        static let linux = Variant(guestOS: .linux)
        static let pendingSetup = Variant(pendingSetup: true)
        static let linuxPendingSetup = Variant(guestOS: .linux, pendingSetup: true)
        static let clone = Variant(clone: true)
        static let cloneWithPendingSetup = Variant(pendingSetup: true, clone: true)
        static let noUSB = Variant(usbSupported: false)
        static let noNetwork = Variant(networkEnabled: false)
        static let noClipboard = Variant(clipboardSharing: false)

        var description: String {
            "\(guestOS) setup=\(pendingSetup) clone=\(clone) usb=\(usbSupported) "
                + "network=\(networkEnabled) clipboard=\(clipboardSharing)"
        }
    }

    private static func facts(
        slot: Bool, _ variant: Variant, terminating: Bool = false
    ) -> VMAdmission.Facts {
        VMAdmission.Facts(
            hasSaveFile: slot, hasSnapshots: true, guestOS: variant.guestOS,
            networkEnabled: variant.networkEnabled,
            clipboardSharingEnabled: variant.clipboardSharing,
            hasPendingGuestSetup: variant.pendingSetup, usbSupported: variant.usbSupported,
            cloneInFlight: variant.clone, identityConflict: nil, accessoryHolder: nil,
            terminating: terminating)
    }

    private static func facts(
        slot: Bool = false, pendingSetup: Bool = false, clone: Bool = false
    ) -> VMAdmission.Facts {
        facts(slot: slot, Variant(pendingSetup: pendingSetup, clone: clone))
    }

    /// One cell: `A` admit, `J` join, `B` busy with the held kind, `b` busy
    /// with a clone copying the VM out, `I` invalid state, `R` removed, `U`
    /// unsupported by this build, `C` an identity conflict, `H` an accessory
    /// another attach holds, `T` refused by the app's termination.
    private static func code(_ decision: VMAdmission.Decision, held: VMOperationKind?) -> Character {
        switch decision {
        case .admit: "A"
        case .join: "J"
        case .refuse(.busy(let kind)) where kind == held: "B"
        case .refuse(.busy(.copyingOut)): "b"
        case .refuse(.busy): "?"
        case .refuse(.invalidState): "I"
        case .refuse(.removed): "R"
        case .refuse(.unsupportedByBuild): "U"
        case .refuse(.identityConflict): "C"
        case .refuse(.accessoryHeld): "H"
        case .refuse(.terminating): "T"
        }
    }

    /// `expected` with the spaces grouping its columns taken out.
    private static func cells(_ expected: String) -> String {
        expected.filter { $0 != " " }
    }

    // MARK: - Settled phases × requests

    /// Columns: stopped, initialBoot, failed, suspended (slot), running,
    /// livePaused, removed.
    nonisolated private static let settledTable: [(VMAdmission.Request, String)] = [
        (.start(recovery: false), "AAAAIIR"),
        (.start(recovery: true), "AIIIIIR"),
        (.resume, "IIIAIAR"),
        (.operation(.bringUp(.guestStart(.starting(recovery: false)))), "AAAIIIR"),
        (.operation(.bringUp(.guestStart(.restoringSavedState))), "IIIAIIR"),
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
        (.operation(.creatingStorageDisk), "AAAIIIR"),
        (.operation(.removingStorageDisk), "AAAIIIR"),
        (.operation(.creatingRemovableMedia), "AAAIAAR"),
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
        #expect(Self.settledCells(request, .plain) == expected, "\(request)")
    }

    /// The settled answers where a fact other than the phase decides: the same
    /// columns, under the named variant.
    nonisolated private static let settledFactTable: [(Variant, VMAdmission.Request, String)] = [
        // Recovery and the guest-agent disk are macOS's; a plain Start is
        // every guest's.
        (.linux, .start(recovery: true), "IIIIIIR"),
        (.linux, .start(recovery: false), "AAAAIIR"),
        (.linux, .affordance(.guestAgentDisk), "IIIIIIR"),
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
        (.noClipboard, .affordance(.clipboard), "IIIIIIR"),
        (.noClipboard, .affordance(.externalDisplay), "IIIIAAR"),
        (.noUSB, .edit(.pairingRules), "UUUUUUR"),
        (.noUSB, .operation(.attachingUSB(registryID: 7)), "UUUUUUR"),
        (.noUSB, .operation(.detachingUSB(deviceID: session)), "UUUUUUR"),
        (.noUSB, .edit(.hotPlugMedia), "AAAIAAR"),
        (.noNetwork, .edit(.networkAttachment), "AAAIIIR"),
        // A clone copying the VM's files out holds every bring-up — whatever
        // Start or Resume resolved it to — the delete, and every machine-key
        // edit as busy; a hot resume and the rest do not touch those files.
        (.clone, .start(recovery: false), "bbbbIIR"),
        (.clone, .start(recovery: true), "bIIIIIR"),
        (.clone, .resume, "IIIbIAR"),
        (.clone, .operation(.bringUp(.reverting(snapshotID: session, resumesAfter: false))), "bbbbbbR"),
        (.clone, .operation(.deleting), "bbbbIIR"),
        (.clone, .edit(.machineKeys), "bbbIIIR"),
        (.clone, .edit(.liveKeys), "AAAAAAR"),
        (.clone, .operation(.copyingOut), "AAAIIIR"),
        (.clone, .operation(.deletingSnapshot), "AAAAAAR"),
        // A disk created in, or trashed from, the bundle is a machine-key
        // write; removable media lives outside it.
        (.clone, .operation(.creatingStorageDisk), "bbbIIIR"),
        (.clone, .operation(.removingStorageDisk), "bbbIIIR"),
        (.clone, .operation(.creatingRemovableMedia), "AAAIAAR"),
        (.cloneWithPendingSetup, .start(recovery: false), "bbbbIIR"),
        (.cloneWithPendingSetup, .operation(.bringUp(.settingUp(.macOSInstall))), "bbbIIIR"),
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
        origin: VMRequestOrigin = .newWork
    ) -> String {
        String(
            settledColumns.map { column in
                code(
                    VMAdmission.decide(
                        request, origin: origin, posture: .commit, phase: column.phase,
                        facts: facts(slot: column.slot, variant, terminating: terminating)),
                    held: nil)
            })
    }

    // MARK: - Termination

    /// The settled columns once the app's termination has begun, for new
    /// work: every request that would commit an operation is refused, and
    /// everything else answers as it did.
    nonisolated private static let terminatingTable: [(VMAdmission.Request, String)] = [
        (.start(recovery: false), "TTTTIIR"),
        (.start(recovery: true), "TIIIIIR"),
        (.resume, "IIITITR"),
        (.operation(.pausing), "IIIITIR"),
        (.operation(.saving), "IIIITTR"),
        (.operation(.capturingSnapshot(.stopped)), "TIIIIIR"),
        (.operation(.deletingSnapshot), "TTTTTTR"),
        (.operation(.bringUp(.reverting(snapshotID: session, resumesAfter: false))), "TTTTTTR"),
        (.operation(.attachingUSB(registryID: 7)), "IIIITTR"),
        (.operation(.forceStopping), "IIIITTR"),
        (.operation(.discardingSavedState), "IIITIIR"),
        (.operation(.deleting), "TTTTIIR"),
        (.operation(.copyingOut), "TTTIIIR"),
        (.operation(.creatingStorageDisk), "TTTIIIR"),
        (.operation(.removingStorageDisk), "TTTIIIR"),
        (.operation(.creatingRemovableMedia), "TTTITTR"),
        // A hot-plug edit commits the media reconcile only on a live VM; at
        // rest it is a write like any other.
        (.edit(.hotPlugMedia), "AAAITTR"),
        (.affordance(.guestAgentDisk), "IIIITTR"),
        (.edit(.machineKeys), "AAAIIIR"),
        (.edit(.liveKeys), "AAAAAAR"),
        (.edit(.rename), "AAAAAAR"),
        // A session action is how a user interrupts a guest.
        (.sessionAction(.requestStop), "IIIIAAR"),
        (.sessionAction(.forceStop), "IIIIAAR"),
        (.evict, "AAAAIIR"),
        (.affordance(.display), "IIIAAAR"),
    ]

    @Test(
        "Once the termination has begun, new work that would commit an operation is refused",
        arguments: terminatingTable.indices)
    func terminatingRefusesNewOperations(row: Int) {
        let (request, expected) = Self.terminatingTable[row]
        #expect(Self.settledCells(request, .plain, terminating: true) == expected, "\(request)")
    }

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
        (.powerOffRevert, .operation(.bringUp(.reverting(snapshotID: session, resumesAfter: false))), "AAAAAAR"),
        (.powerOffRevert, .operation(.bringUp(.reverting(snapshotID: session, resumesAfter: true))), "AAAAAAR"),
        (.powerOffRevert, .start(recovery: false), "TTTTIIR"),
        (.powerOffRevert, .resume, "IIITITR"),
        (.powerOffRevert, .operation(.saving), "IIIITTR"),
        (.powerOffRevert, .operation(.capturingSnapshot(.stopped)), "TIIIIIR"),
        (.powerOffRevert, .operation(.deletingSnapshot), "TTTTTTR"),
        (.powerOffRevert, .operation(.discardingSavedState), "IIITIIR"),
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

    @Test(
        "Under an exempt origin every other request decides as new work does",
        arguments: settledTable.indices)
    func exemptOriginWidensNothingElse(row: Int) {
        let (request, _) = Self.settledTable[row]
        let asNewWork = Self.settledCells(request, .plain, terminating: true)
        for origin in [VMRequestOrigin.terminationSave, .powerOffRevert] where !origin.exempts(request) {
            #expect(
                Self.settledCells(request, .plain, terminating: true, origin: origin) == asNewWork,
                "\(request) \(origin)")
        }
    }

    @Test("Outside the termination, an origin changes no decision", arguments: settledTable.indices)
    func originIsInertOutsideTheTermination(row: Int) {
        let (request, expected) = Self.settledTable[row]
        for origin in [VMRequestOrigin.terminationSave, .powerOffRevert] {
            #expect(Self.settledCells(request, .plain, origin: origin) == expected, "\(request) \(origin)")
        }
    }

    @Test("During an operation, the termination refuses nothing the operation tolerates or joins")
    func terminatingLeavesToleratedRequests() {
        let facts = Self.facts(slot: false, .plain, terminating: true)
        func decide(
            _ request: VMAdmission.Request, during kind: VMOperationKind,
            from startedFrom: VMLifecyclePhase
        ) -> VMAdmission.Decision {
            VMAdmission.decide(
                request, posture: .commit,
                phase: .operating(kind, from: startedFrom, boundSession: nil), facts: facts)
        }
        // An edit the running reconcile coalesces starts no operation of its own.
        #expect(decide(.edit(.hotPlugMedia), during: .reconcilingMedia, from: Self.live) == .admit)
        #expect(decide(.sessionAction(.forceStop), during: .pausing, from: Self.live) == .admit)
        #expect(
            decide(.operation(.saving), during: .pausing, from: Self.live)
                == .refuse(.busy(.pausing)))
        let start = decide(
            .start(recovery: false), during: .bringUp(.guestStart(.starting(recovery: false))),
            from: .stopped)
        guard case .join = start else {
            Issue.record("A Start during a start should join it, got \(start)")
            return
        }
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
    ///   guest-agent disk.
    nonisolated private static let heldColumns: [VMAdmission.Request] = [
        .start(recovery: false), .start(recovery: true), .resume,
        .operation(.pausing), .operation(.saving), .operation(.capturingSnapshot(.live)),
        .operation(.attachingUSB(registryID: 7)), .operation(.reconcilingMedia),
        .operation(.forceStopping),
        .operation(.capturingSnapshot(.stopped)), .operation(.capturingSnapshot(.suspended)),
        .operation(.discardingSavedState), .operation(.copyingOut),
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
        .affordance(.clipboard), .affordance(.guestAgentDisk),
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
            expected: "JBI IIIIII BIIB BBB BBB BBBBAAAAA IIIB AIIII"),
        // A plain Start joins a Recovery boot; Start in Recovery joins nothing.
        HeldRow(
            kind: .bringUp(.guestStart(.starting(recovery: true))), startedFrom: .stopped,
            expected: "JBI IIIIII BIIB BBB BBB BBBBAAAAA IIIB AIIII"),
        HeldRow(
            kind: .bringUp(.guestStart(.restoringSavedState)), startedFrom: .suspended, slot: true,
            expected: "JIJ IIIIII IBBI BBB III IBIIAAAAA IIIB AAIII"),
        HeldRow(
            kind: .bringUp(.settingUp(.macOSInstall)), startedFrom: .initialBoot,
            variant: .pendingSetup,
            expected: "BII IIIIII IIIB BBB BBB BBBBAAAAA IIAB AIIII"),
        HeldRow(
            kind: .bringUp(.settingUp(.linuxImageDownload)), startedFrom: .initialBoot,
            variant: .linuxPendingSetup,
            expected: "BII IIIIII IIIB BBB BBB BBBBAAAAA IIAB AIIII"),
        HeldRow(
            kind: .bringUp(.reverting(snapshotID: session, resumesAfter: true)),
            startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IBBBABAAA BBII AAIII"),
        HeldRow(
            kind: .bringUp(.reverting(snapshotID: session, resumesAfter: false)),
            startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BBBBABAAA IIIB AAIII"),
        HeldRow(
            kind: .pausing, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IABAAAAAA AAII AAAAB"),
        HeldRow(
            kind: .resuming, startedFrom: .livePaused(sessionID: session),
            expected: "IIB IBBBBB IIII BBI IIB IABAAAAAA AAII AAAAB"),
        HeldRow(
            kind: .saving, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IBBBAAAAA BBII AAIII"),
        HeldRow(
            kind: .capturingSnapshot(.live), startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IBBBAAAAA BBII AAIII"),
        HeldRow(
            kind: .capturingSnapshot(.stopped), startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BBBBAAAAA IIIB AAIII"),
        HeldRow(
            kind: .capturingSnapshot(.suspended), startedFrom: .suspended, slot: true,
            expected: "BIB IIIIII IBBI BBB III IBIIAAAAA IIIB AAIII"),
        HeldRow(
            kind: .deletingSnapshot, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IABAAABAA AAII AAAAB"),
        HeldRow(
            kind: .attachingUSB(registryID: 7), startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IABAAAAAA AAII AAAAB"),
        HeldRow(
            kind: .detachingUSB(deviceID: session), startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IABAAAAAA AAII AAAAB"),
        // Removable-media edits, the guest-agent disk among them, coalesce
        // into the pass.
        HeldRow(
            kind: .reconcilingMedia, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IAAAAAAAA AAII AAAAA"),
        // Answered as the powered-off VM will answer, with a second Force Stop
        // joining the first and presentation and metadata edits taken; the
        // guest is presented until its session ends.
        HeldRow(
            kind: .forceStopping, startedFrom: live,
            expected: "BBI IIIIII BIIB BBB BBB BBBBAAAAA IJIB AAAAB"),
        HeldRow(
            kind: .discardingSavedState, startedFrom: .suspended, slot: true,
            expected: "BIB IIIIII IBBI BBB III IBIIBBBBB IIIB AAIII"),
        HeldRow(
            kind: .deleting, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BBBBBBBBB IIIB AIIII"),
        HeldRow(
            kind: .creatingStorageDisk, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BAAAAAAAA IIIB AIIII"),
        HeldRow(
            kind: .removingStorageDisk, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BAAAAAAAA IIIB AIIII"),
        // A live guest keeps taking a stop while the image is written and
        // attached.
        HeldRow(
            kind: .creatingRemovableMedia, startedFrom: live,
            expected: "III BBBBBB IIII BBI IIB IABAAAAAA AAII AAAAB"),
        HeldRow(
            kind: .creatingRemovableMedia, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BABAAAAAA IIIB AIIII"),
        HeldRow(
            kind: .copyingOut, startedFrom: .stopped,
            expected: "BBI IIIIII BIIB BBB BBB BAAAAAAAA IIIB AIIII"),

        // Facts varied under a held operation.

        // A clone's lock on the files outlasts the operation, so what it
        // holds is busy with the clone — a tolerated machine-key edit too.
        HeldRow(
            kind: .deletingSnapshot, startedFrom: .stopped, variant: .clone,
            expected: "bbI IIIIII BIIB Bbb bbB bABAAABAA IIIB AIIII"),
        // A build without USB passthrough refuses it as unsupported whatever
        // holds the VM.
        HeldRow(
            kind: .deletingSnapshot, startedFrom: live, variant: .noUSB,
            expected: "III BBBUBB IIII BBI IIB IABAAABUA AAII AAAAB"),
        HeldRow(
            kind: .deleting, startedFrom: .stopped, variant: .noUSB,
            expected: "BBI IIIUII BIIB BBB BBB BBBBBBBUB IIIB AIIII"),
        // Once the session ended, requests answer as the rest that end
        // implies: suspended where the slot survived it…
        HeldRow(
            kind: .saving, startedFrom: live, slot: true, sessionEnd: .endedByOperation,
            expected: "BIB IIIIII IBBI BBB III IBIIAAAAA IIIB AAIII"),
        // …and failed after Virtualization stopped the guest with an error.
        HeldRow(
            kind: .pausing, startedFrom: live, sessionEnd: .stoppedWithError(message: "boom"),
            expected: "BII IIIIII IIIB BBB BBB AABAAAAAA IIIB AIIII"),
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

    @Test("A join hands back the held operation's own outcome")
    func joinCarriesTheHeldOutcome() {
        let outcome = VMOutcome()
        let phase = VMLifecyclePhase.operating(
            VMOperation(
                kind: .bringUp(.guestStart(.starting(recovery: false))), startedFrom: .stopped,
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
                == .guestStart(.restoringSavedState))
    }

    @Test("A bring-up is joined only on commit; offered, it reads as busy")
    func joinIsCommitOnly() {
        let phase = VMLifecyclePhase.operating(
            VMOperation(
                kind: .bringUp(.guestStart(.restoringSavedState)), startedFrom: .suspended,
                sessionState: .none, outcome: VMOutcome()))
        let facts = Self.facts(slot: true)
        #expect(
            VMAdmission.decide(.resume, posture: .offer, phase: phase, facts: facts)
                == .refuse(.busy(.bringUp(.guestStart(.restoringSavedState)))))
        #expect(
            VMAdmission.decide(.start(recovery: false), posture: .offer, phase: phase, facts: facts)
                == .refuse(.invalidState))
    }

    // MARK: - Facts

    /// What a request resolves to: the operation it performs, and the
    /// bring-up among them — `nil` for a request that performs none.
    nonisolated private static let resolutionTable:
        [(VMAdmission.Request, VMLifecyclePhase, Bool, Variant, VMOperationKind?, VMBringUpKind?)] = [
            (
                .start(recovery: false), .initialBoot, false, .pendingSetup,
                .bringUp(.settingUp(.macOSInstall)), .settingUp(.macOSInstall)
            ),
            (
                .start(recovery: false), .initialBoot, false, .linuxPendingSetup,
                .bringUp(.settingUp(.linuxImageDownload)), .settingUp(.linuxImageDownload)
            ),
            // A saved state is restored ahead of any setup still pending.
            (
                .start(recovery: false), .suspended, true, .pendingSetup,
                .bringUp(.guestStart(.restoringSavedState)), .guestStart(.restoringSavedState)
            ),
            (
                .start(recovery: false), .stopped, false, .linux,
                .bringUp(.guestStart(.starting(recovery: false))), .guestStart(.starting(recovery: false))
            ),
            (
                .start(recovery: true), .stopped, false, .linux,
                .bringUp(.guestStart(.starting(recovery: true))), .guestStart(.starting(recovery: true))
            ),
            (
                .start(recovery: true), .initialBoot, false, .pendingSetup,
                .bringUp(.guestStart(.starting(recovery: true))), .guestStart(.starting(recovery: true))
            ),
            (.resume, .livePaused(sessionID: session), false, .plain, .resuming, nil),
            (
                .resume, .suspended, true, .linux, .bringUp(.guestStart(.restoringSavedState)),
                .guestStart(.restoringSavedState)
            ),
            // Resume outside a live pause is the restore, which its row
            // refuses without a saved state.
            (
                .resume, .stopped, false, .plain,
                .bringUp(.guestStart(.restoringSavedState)), .guestStart(.restoringSavedState)
            ),
            (.operation(.pausing), .running(sessionID: session), false, .plain, .pausing, nil),
            (.edit(.rename), .stopped, false, .plain, nil, nil),
        ]

    @Test(
        "Start and Resume resolve to the operation the facts name",
        arguments: resolutionTable.indices)
    func requestsResolveToTheirOperation(row: Int) {
        let (request, phase, slot, variant, operation, bringUp) = Self.resolutionTable[row]
        let facts = Self.facts(slot: slot, variant)
        #expect(
            VMAdmission.operationKind(for: request, phase: phase, facts: facts) == operation,
            "\(request) \(phase) \(variant)")
        #expect(
            VMAdmission.bringUpKind(for: request, phase: phase, facts: facts) == bringUp,
            "\(request) \(phase) \(variant)")
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
                    == .guestStart(.starting(recovery: true)))
            #expect(
                VMAdmission.decide(.start(recovery: true), posture: .commit, phase: phase, facts: facts)
                    == .refuse(.invalidState), "\(phase)")
        }
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

    @Test("A session a Force Stop is terminating takes what a Force Stop does, and a second Force Stop joins it")
    func stoppingSessionTakesWhatAForceStopTakes() {
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
            .start(recovery: false), .edit(.machineKeys), .edit(.liveKeys),
            .operation(.bringUp(.reverting(snapshotID: Self.session, resumesAfter: false))),
        ] {
            #expect(decide(request) == .refuse(.busy(.forceStopping)), "\(request)")
        }
        // The edits a Force Stop takes, it takes here too.
        for classes: VMEditClasses in [.hostPresentation, .rename, .observations] {
            #expect(decide(.edit(classes)) == .admit, "\(classes)")
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

    // MARK: - Accessory Holders

    @Test("An attach of an accessory a VM holds is refused as held wherever an attach would be taken")
    func anAttachOfAHeldAccessoryIsRefusedAsHeld() {
        let holder = VMInstanceFixture.make(name: "Holder")
        let attach = VMAdmission.Request.operation(.attachingUSB(registryID: 7))
        func facts(slot: Bool = false, _ variant: Variant = .plain) -> VMAdmission.Facts {
            var facts = Self.facts(slot: slot, variant)
            facts.accessoryHolder = holder
            return facts
        }

        let settled = String(
            Self.settledColumns.map { column in
                Self.code(
                    VMAdmission.decide(
                        attach, posture: .commit, phase: column.phase,
                        facts: facts(slot: column.slot)),
                    held: nil)
            })

        // Only a live VM takes an attach at all; where one would be taken, the
        // holder refuses it, and names itself.
        #expect(settled == "IIIIHHR")
        #expect(
            VMAdmission.decide(attach, posture: .commit, phase: Self.live, facts: facts())
                == .refuse(.accessoryHeld(by: holder)))
        #expect(
            VMAdmission.decide(attach, posture: .commit, phase: Self.live, facts: facts(.noUSB))
                == .refuse(.unsupportedByBuild))
        // Still held once the operation holding this VM ends, so that is the
        // answer during it too.
        #expect(
            VMAdmission.decide(
                attach, posture: .commit, phase: .operating(.pausing, from: Self.live),
                facts: facts()) == .refuse(.accessoryHeld(by: holder)))
        // A detach names an attachment the VM holds, not an accessory.
        #expect(
            VMAdmission.decide(
                .operation(.detachingUSB(deviceID: Self.session)), posture: .commit,
                phase: Self.live, facts: facts()) == .admit)
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
