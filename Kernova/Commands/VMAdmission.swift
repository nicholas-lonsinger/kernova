import Foundation
import KernovaKit

/// The one decision every request on a VM goes through: what the catalog
/// offers, what a verb accepts, and what ``VMActivity`` commits.
///
/// Pure: the same request, phase and facts always decide the same way, which
/// is what lets a surface's answer and the commit agree by construction.
enum VMAdmission {
    /// Something asked of one VM.
    enum Request: Sendable, Equatable {
        /// Start, resolved from the facts to the bring-up it performs.
        case start(recovery: Bool)
        /// Resume: a hot resume of a live-paused VM, or the restore of a saved
        /// state.
        case resume
        case operation(VMOperationKind)
        case edit(VMEditClasses)
        case sessionAction(VMSessionAction)
        case cancel(VMOperationKind.Family)
        /// Drop the VM from the library.
        case evict
        case affordance(VMAffordance)
    }

    enum Decision: Equatable {
        case admit
        /// The request asks for what the operation holding the VM is already
        /// producing; await its outcome.
        case join(VMOutcome)
        case refuse(Refusal)
    }

    enum Refusal: Equatable, Sendable {
        /// An operation holds the VM, and the request would be admitted once
        /// it ends.
        case busy(VMOperationKind)
        case invalidState
        case removed
        case identityConflict(VMIdentityConflict)
        /// This build cannot do what was asked at all.
        case unsupportedByBuild

        static func == (lhs: Refusal, rhs: Refusal) -> Bool {
            switch (lhs, rhs) {
            case (.busy(let l), .busy(let r)): l == r
            case (.invalidState, .invalidState), (.removed, .removed),
                (.unsupportedByBuild, .unsupportedByBuild):
                true
            case (.identityConflict(let l), .identityConflict(let r)):
                l.other === r.other && l.reason == r.reason
            default: false
            }
        }
    }

    /// Whether the request is being offered on a surface or committed.
    ///
    /// They differ only for Start and Resume: a VM holding a saved state is
    /// offered Resume rather than Start, and a request that would join a
    /// bring-up is committed, never offered.
    enum Posture: Sendable, Equatable {
        case offer
        case commit
    }

    /// The VM's own facts, and the library's, that a decision reads besides the
    /// phase.
    struct Facts {
        var hasSaveFile: Bool
        var hasSnapshots: Bool
        var guestOS: VMGuestOS
        var networkEnabled: Bool
        var clipboardSharingEnabled: Bool
        var hasPendingGuestSetup: Bool
        var usbSupported: Bool
        /// A clone copying this VM's files out of its bundle.
        var cloneInFlight: Bool
        /// The live VM whose identity bringing this one up would duplicate —
        /// supplied only when deciding a bring-up.
        var identityConflict: VMIdentityConflict?

        /// These facts as they will stand once the saved state is discarded.
        func discardingSavedState() -> Facts {
            var facts = self
            facts.hasSaveFile = false
            return facts
        }
    }

    // MARK: - Decide

    static func decide(
        _ request: Request, posture: Posture, phase: VMLifecyclePhase, facts: Facts
    ) -> Decision {
        if case .affordance(let affordance) = request {
            return decideAffordance(affordance, phase: phase, facts: facts, posture: posture)
        }
        switch phase {
        case .removed:
            return .refuse(.removed)
        case .operating(let operation):
            return decideDuring(operation, request, posture: posture, facts: facts)
        case .stopped, .initialBoot, .failed, .suspended, .running, .livePaused:
            return decideSettled(request, posture: posture, phase: phase, facts: facts)
        }
    }

    /// The operation a Start, Resume or operation request performs, or `nil`
    /// when it names none.
    ///
    /// Start resolves from the facts alone, and the operation's own row then
    /// judges the phase: Start in Recovery is always a Recovery boot, so a VM
    /// that cannot take one refuses it rather than starting some other way.
    static func operationKind(
        for request: Request, phase: VMLifecyclePhase, facts: Facts
    ) -> VMOperationKind? {
        switch request {
        case .start(recovery: true):
            return .bringUp(.starting(recovery: true))
        case .start(recovery: false):
            if facts.hasSaveFile { return .bringUp(.restoringSavedState) }
            if facts.hasPendingGuestSetup {
                return .bringUp(
                    .settingUp(facts.guestOS == .macOS ? .macOSInstall : .linuxImageDownload))
            }
            return .bringUp(.starting(recovery: false))
        case .resume:
            if case .livePaused = phase { return .resuming }
            return facts.hasSaveFile ? .bringUp(.restoringSavedState) : nil
        case .operation(let kind):
            return kind
        case .edit, .sessionAction, .cancel, .evict, .affordance:
            return nil
        }
    }

    /// The bring-up ``operationKind(for:phase:facts:)`` names, or `nil` when
    /// the request performs none — a hot resume among them.
    static func bringUpKind(
        for request: Request, phase: VMLifecyclePhase, facts: Facts
    ) -> VMBringUpKind? {
        guard case .bringUp(let kind)? = operationKind(for: request, phase: phase, facts: facts)
        else { return nil }
        return kind
    }

    /// How a capture taken from `phase` right now is made, or `nil` when the
    /// phase admits none.
    ///
    /// Disks alone are captured only from a plainly stopped VM: `.initialBoot`
    /// holds disks with no installed guest, and `.failed` says the last
    /// operation did not finish.
    static func captureMode(phase: VMLifecyclePhase, facts: Facts) -> VMSnapshotCaptureMode? {
        if phase.isSettledLive { return .live }
        guard phase.isAtRest else { return nil }
        if facts.hasSaveFile { return .suspended }
        return phase == .stopped ? .stopped : nil
    }

    /// The mode a capture is offered in: ``captureMode(phase:facts:)`` over the
    /// settled phase the VM rests at, or an operation's
    /// ``VMOperation/settledBasis(slotOnDisk:)`` — so an operation in flight
    /// dims Take Snapshot rather than hiding it.
    static func settledCaptureMode(
        phase: VMLifecyclePhase, facts: Facts
    ) -> VMSnapshotCaptureMode? {
        let settled = phase.operation?.settledBasis(slotOnDisk: facts.hasSaveFile) ?? phase
        return captureMode(phase: settled, facts: facts)
    }

    /// The edit classes a settled phase admits.
    static func editClasses(settledAt phase: VMLifecyclePhase, facts: Facts) -> VMEditClasses {
        switch phase {
        case .stopped, .initialBoot, .failed, .suspended:
            guard facts.hasSaveFile else { return .all }
            return VMEditClasses.all.subtracting([.machineKeys, .hotPlugMedia, .networkAttachment])
        case .running, .livePaused:
            var classes = VMEditClasses.all.subtracting([.machineKeys, .networkAttachment])
            if facts.networkEnabled { classes.insert(.networkAttachment) }
            return classes
        case .operating, .removed:
            return []
        }
    }

    // MARK: - Settled

    /// One exhaustive answer per request over the settled phases.
    private static func decideSettled(
        _ request: Request, posture: Posture, phase: VMLifecyclePhase, facts: Facts
    ) -> Decision {
        let atRest = phase.isAtRest
        let live = phase.isSettledLive
        switch request {
        case .start, .resume, .operation:
            guard let kind = operationKind(for: request, phase: phase, facts: facts) else {
                return .refuse(.invalidState)
            }
            // A VM holding a saved state is offered Resume, not Start.
            if case .start = request, kind == .bringUp(.restoringSavedState), posture == .offer {
                return .refuse(.invalidState)
            }
            return decideSettledOperation(kind, phase: phase, facts: facts)
        case .edit(let classes):
            // A pairing rule is a preference about which accessory to pass
            // through, so only a build that cannot pass one through at all
            // has nothing to edit.
            if classes.contains(.pairingRules), !facts.usbSupported {
                return .refuse(.unsupportedByBuild)
            }
            guard editClasses(settledAt: phase, facts: facts).isSuperset(of: classes) else {
                return .refuse(.invalidState)
            }
            if classes.contains(.machineKeys), facts.cloneInFlight {
                return .refuse(.busy(.copyingOut))
            }
            return .admit
        case .sessionAction:
            return live ? .admit : .refuse(.invalidState)
        case .cancel:
            return .refuse(.invalidState)
        case .evict:
            return atRest ? .admit : .refuse(.invalidState)
        case .affordance(let affordance):
            return decideAffordance(affordance, phase: phase, facts: facts, posture: posture)
        }
    }

    private static func decideSettledOperation(
        _ kind: VMOperationKind, phase: VMLifecyclePhase, facts: Facts
    ) -> Decision {
        let atRest = phase.isAtRest
        let live = phase.isSettledLive
        let slot = atRest && facts.hasSaveFile
        let admitted: Bool
        switch kind {
        case .bringUp(.starting(let recovery)):
            admitted =
                atRest && !facts.hasSaveFile && !facts.hasPendingGuestSetup
                && (!recovery || (phase == .stopped && facts.guestOS == .macOS))
        case .bringUp(.restoringSavedState):
            admitted = slot
        case .bringUp(.settingUp):
            admitted = atRest && !facts.hasSaveFile && facts.hasPendingGuestSetup
        case .bringUp(.reverting):
            admitted = facts.hasSnapshots
        case .pausing:
            if case .running = phase { admitted = true } else { admitted = false }
        case .resuming:
            if case .livePaused = phase { admitted = true } else { admitted = false }
        case .saving, .reconcilingMedia, .forceStopping:
            admitted = live
        case .capturingSnapshot(let mode):
            admitted = captureMode(phase: phase, facts: facts) == mode
        case .deletingSnapshot:
            admitted = true
        case .attachingUSB, .detachingUSB:
            guard facts.usbSupported else { return .refuse(.unsupportedByBuild) }
            admitted = live
        case .discardingSavedState:
            admitted = slot
        case .deleting:
            admitted = atRest
        case .copyingOut:
            admitted = atRest && !facts.hasSaveFile
        }
        guard admitted else { return .refuse(.invalidState) }
        switch kind {
        case .bringUp, .deleting:
            if facts.cloneInFlight { return .refuse(.busy(.copyingOut)) }
        default:
            break
        }
        if case .bringUp(let bringUp) = kind, bringUp.checksIdentity {
            return identityChecked(facts)
        }
        return .admit
    }

    private static func identityChecked(_ facts: Facts) -> Decision {
        guard let conflict = facts.identityConflict else { return .admit }
        return .refuse(.identityConflict(conflict))
    }

    // MARK: - During an Operation

    private static func decideDuring(
        _ operation: VMOperation, _ request: Request, posture: Posture, facts: Facts
    ) -> Decision {
        let basis = operation.settledBasis(slotOnDisk: facts.hasSaveFile)
        // A session a Force Stop is terminating takes nothing new: a second
        // Force Stop joins the first — offered, it reads as busy, like every
        // join — and the rest is answered as the powered-off VM will answer.
        if let stop = operation.session?.stopping {
            if request == .sessionAction(.forceStop) {
                return posture == .commit ? .join(stop) : .refuse(.busy(.forceStopping))
            }
            return classified(request, posture: posture, against: basis, facts: facts, busy: .forceStopping)
        }
        let declaration = operation.kind.declaration
        if posture == .commit, let join = join(for: request),
            declaration.joinedBy.contains(join)
        {
            return .join(operation.outcome)
        }
        switch request {
        case .cancel(let family):
            if operation.kind.belongs(to: family) { return .admit }
        case .edit(let classes):
            // A tolerated edit still answers to every settled rule — the clone
            // lock and a build without USB among them.
            if tolerated(declaration.edits, from: basis, facts: facts).isSuperset(of: classes) {
                return decideSettled(request, posture: posture, phase: basis, facts: facts)
            }
        case .sessionAction(let action):
            if operation.session != nil, declaration.toleratedSessionActions.contains(action) {
                return .admit
            }
        case .start, .resume, .operation, .evict, .affordance:
            break
        }
        return classified(request, posture: posture, against: basis, facts: facts, busy: operation.kind)
    }

    /// What the VM would answer once the operation holding it ends, settled
    /// at `basis`: a request it would take is busy with `holder`, and one it
    /// would refuse anyway is refused for the same reason.
    private static func classified(
        _ request: Request, posture: Posture, against basis: VMLifecyclePhase, facts: Facts,
        busy holder: VMOperationKind
    ) -> Decision {
        var settledFacts = facts
        settledFacts.identityConflict = nil
        switch decideSettled(request, posture: posture, phase: basis, facts: settledFacts) {
        case .admit, .join:
            return .refuse(.busy(holder))
        case .refuse(let refusal):
            return .refuse(refusal)
        }
    }

    private static func join(for request: Request) -> VMOperationDeclaration.Join? {
        switch request {
        case .start(recovery: false): .start
        case .resume: .resume
        default: nil
        }
    }

    private static func tolerated(
        _ edits: VMOperationDeclaration.Edits, from startedFrom: VMLifecyclePhase,
        facts: Facts
    ) -> VMEditClasses {
        let base = editClasses(settledAt: startedFrom, facts: facts)
        switch edits {
        case .only(let classes): return base.intersection(classes)
        case .baseExcept(let excluded): return base.subtracting(excluded)
        }
    }

    // MARK: - Affordances

    /// Affordances read what the VM presents rather than taking admission: an
    /// operation that presents the phase it started from changes none of them.
    private static func decideAffordance(
        _ affordance: VMAffordance, phase: VMLifecyclePhase, facts: Facts, posture: Posture
    ) -> Decision {
        if phase == .removed { return .refuse(.removed) }
        let admitted: Bool
        switch affordance {
        case .inspect:
            admitted = true
        case .display:
            admitted = phase.hasActiveDisplay
        case .externalDisplay:
            admitted = phase.hasLiveSession
        case .clipboard:
            admitted = facts.clipboardSharingEnabled && phase.hasLiveSession
        case .guestAgentDisk:
            guard facts.guestOS == .macOS, phase.hasLiveSession else {
                return .refuse(.invalidState)
            }
            return decide(.edit(.hotPlugMedia), posture: posture, phase: phase, facts: facts)
        }
        return admitted ? .admit : .refuse(.invalidState)
    }
}

/// A request that reads what a VM presents rather than moving it.
enum VMAffordance: Sendable, Equatable {
    /// Info, the address, the snapshot list, reveal, Show in Finder.
    case inspect
    /// Open the display, or toggle the settings pane over it.
    case display
    /// Pop out, or go fullscreen.
    case externalDisplay
    case clipboard
    /// Attach or eject the guest-agent installer disk.
    case guestAgentDisk
}

/// A request ``VMActivity`` refused, and why.
struct VMAdmissionRefusal: Error, Equatable {
    let refusal: VMAdmission.Refusal
}

/// What a VM's library contributes to its admission facts.
@MainActor
protocol VMAdmissionPeers: AnyObject {
    /// Whether this build can pass a host USB accessory through to a guest.
    var supportsUSBAccessories: Bool { get }

    /// Whether a clone is copying `instance`'s files out of its bundle.
    func hasCloneInFlight(from instance: VMInstance) -> Bool

    /// The live VM whose identity bringing `instance` up under `configuration`
    /// would duplicate.
    func identityConflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration
    ) -> VMIdentityConflict?
}
