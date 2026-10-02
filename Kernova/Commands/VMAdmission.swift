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
        /// The VM's state takes the request, but not with what the VM is
        /// configured with: only a stopped VM takes `change`.
        case takesStoppedVM(StoppedVMChange)
        case removed
        case identityConflict(VMIdentityConflict)
        /// Another attach already holds the accessory an attach names — the
        /// VM it was reserved for or passed through to.
        case accessoryHeld(by: VMInstance)
        /// This build cannot do what was asked at all.
        case unsupportedByBuild
        /// The app is terminating, and the request would begin an operation
        /// the termination did not ask for.
        ///
        /// Raised only where the VM would otherwise admit the request, so a
        /// surface reads it as applicable.
        case terminating
        /// Another running copy of Kernova holds the VM's bundle, and the
        /// request would begin an operation on it or write its state files
        /// (``VMAdmission/isRefusedWhileHeldByAnotherCopy(_:phase:)``).
        ///
        /// Raised only where the VM would otherwise admit the request, so a
        /// surface reads it as applicable.
        case heldByAnotherCopy

        static func == (lhs: Refusal, rhs: Refusal) -> Bool {
            switch (lhs, rhs) {
            case (.busy(let l), .busy(let r)): l == r
            case (.takesStoppedVM(let l), .takesStoppedVM(let r)): l == r
            case (.invalidState, .invalidState), (.removed, .removed),
                (.unsupportedByBuild, .unsupportedByBuild), (.terminating, .terminating),
                (.heldByAnotherCopy, .heldByAnotherCopy):
                true
            case (.identityConflict(let l), .identityConflict(let r)):
                l.other === r.other && l.reason == r.reason && l.asks == r.asks
            case (.accessoryHeld(let l), .accessoryHeld(let r)):
                l === r
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
        /// The saved state, if any, restores after the network device moves to
        /// another network of its mode
        /// (``VMConfiguration/savedStateSurvivesMembershipMove``).
        var savedStateSurvivesMembershipMove = false
        var clipboardSharingEnabled: Bool
        var hasPendingGuestSetup: Bool
        var usbSupported: Bool
        /// The guest can write to a disk outside its bundle — an external
        /// storage disk or removable media not marked read-only
        /// (``VMConfiguration/writesOutsideBundle``).
        var writesOutsideBundle: Bool
        /// The VM claiming the identity (``VMInstance/claimsIdentity``) that
        /// bringing this one up would duplicate — supplied only when deciding
        /// a bring-up.
        var identityConflict: VMIdentityConflict?
        /// The VM holding the accessory an attach names — supplied only when
        /// deciding an attach (``VMAccessoryHolders/holder(of:)``).
        var accessoryHolder: VMInstance?
        /// The app's termination has begun.
        var terminating: Bool
        /// Another running copy of Kernova holds the bundle of this VM, which
        /// is at rest here.
        var heldByAnotherCopy: Bool

        /// These facts as they will stand once the saved state is discarded.
        func discardingSavedState() -> Facts {
            var facts = self
            facts.hasSaveFile = false
            return facts
        }
    }

    // MARK: - Decide

    static func decide(
        _ request: Request, origin: VMRequestOrigin = .newWork, posture: Posture,
        phase: VMLifecyclePhase, facts: Facts
    ) -> Decision {
        let decision = decideOnTheVM(request, posture: posture, phase: phase, facts: facts)
        guard decision == .admit else { return decision }
        if facts.terminating, beginsOperation(request, phase: phase), !origin.exempts(request) {
            return .refuse(.terminating)
        }
        if facts.heldByAnotherCopy, isRefusedWhileHeldByAnotherCopy(request, phase: phase) {
            return .refuse(.heldByAnotherCopy)
        }
        return decision
    }

    /// Whether another copy of Kernova holding the bundle refuses `request` in
    /// `phase`: anything admitted on a VM at rest that begins an operation or
    /// writes its state files — the two ways this copy would write a bundle
    /// the other copy holds.
    static func isRefusedWhileHeldByAnotherCopy(
        _ request: Request, phase: VMLifecyclePhase
    ) -> Bool {
        guard phase.isAtRest else { return false }
        if case .edit = request { return true }
        return beginsOperation(request, phase: phase)
    }

    /// Whether admitting `request` in `phase` commits an operation: a Start, a
    /// Resume or an operation, and a hot-plug edit that owes a live session
    /// the media reconcile (``owesMediaReconcile(_:)``).
    ///
    /// A session action is not one: it is how a user interrupts a guest, and
    /// the Force Stop it may commit is one a quit waits out.
    static func beginsOperation(_ request: Request, phase: VMLifecyclePhase) -> Bool {
        switch request {
        case .start, .resume, .operation:
            return true
        case .edit(let classes):
            return !classes.isDisjoint(with: [.hotPlugMedia, .removableMediaRemoval])
                && owesMediaReconcile(phase)
        case .affordance(.guestAgentDisk):
            return owesMediaReconcile(phase)
        case .sessionAction, .cancel, .evict, .affordance:
            return false
        }
    }

    /// Whether a removable-media change on a VM in `phase` owes a reconcile
    /// operation of its own — run at once on a settled VM, and once the
    /// operation holding it ends otherwise: the VM has a live session, and no
    /// reconcile already holding it carries the change.
    static func owesMediaReconcile(_ phase: VMLifecyclePhase) -> Bool {
        guard phase.sessionID != nil else { return false }
        guard let operation = phase.operation else { return true }
        return !joins(.operation(.reconcilingMedia), operation)
    }

    /// How the VM's own phase and facts answer `request`, before the app's
    /// termination or another copy's hold refuses new work.
    private static func decideOnTheVM(
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

    /// What a Start performs.
    enum StartWork: Sendable, Equatable {
        case guestStart(VMGuestStartKind)
        /// The guest setup the VM still owes, which chains the boot itself.
        case setup(GuestSetupKind)

        var operationKind: VMOperationKind {
            switch self {
            case .guestStart(let kind): .bringUp(.guestStart(kind))
            case .setup(let kind): .bringUp(.settingUp(kind))
            }
        }
    }

    /// What a Resume performs.
    enum ResumeWork: Sendable, Equatable {
        /// A hot resume of a live-paused guest.
        case hot
        /// The restore of the bundle's saved state.
        case restore

        var operationKind: VMOperationKind {
            switch self {
            case .hot: .resuming
            case .restore: .bringUp(.guestStart(.restoringSavedState))
            }
        }
    }

    /// What Start performs on a VM with `facts`.
    ///
    /// Resolved from the facts alone, and the operation's own row then judges
    /// the phase: Start in Recovery is always a Recovery boot, so a VM that
    /// cannot take one refuses it rather than starting some other way.
    static func startWork(recovery: Bool, facts: Facts) -> StartWork {
        if recovery { return .guestStart(.starting(recovery: true)) }
        if facts.hasSaveFile { return .guestStart(.restoringSavedState) }
        if facts.hasPendingGuestSetup {
            return .setup(facts.guestOS == .macOS ? .macOSInstall : .linuxImageDownload)
        }
        return .guestStart(.starting(recovery: false))
    }

    /// What Resume performs on a VM in `phase`: a hot resume only of a
    /// live-paused guest, and otherwise the restore, whose row judges whether
    /// there is a saved state to restore.
    static func resumeWork(phase: VMLifecyclePhase) -> ResumeWork {
        if case .livePaused = phase { return .hot }
        return .restore
    }

    /// The operation a Start, Resume or operation request performs, or `nil`
    /// when it names none.
    static func operationKind(
        for request: Request, phase: VMLifecyclePhase, facts: Facts
    ) -> VMOperationKind? {
        switch request {
        case .start(let recovery):
            return startWork(recovery: recovery, facts: facts).operationKind
        case .resume:
            return resumeWork(phase: phase).operationKind
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
    /// A capture with no memory is taken only from a plainly stopped VM:
    /// `.initialBoot` holds disks with no installed guest, and `.failed` says the last
    /// operation did not finish.
    static func captureMode(phase: VMLifecyclePhase, facts: Facts) -> VMCaptureMode? {
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
    ) -> VMCaptureMode? {
        let settled = phase.operation?.settledBasis(slotOnDisk: facts.hasSaveFile) ?? phase
        return captureMode(phase: settled, facts: facts)
    }

    /// How a clone's copy taken from `phase` right now is made, or `nil` when
    /// the phase admits none: from disks alone at any rest with no saved
    /// state — a failed or never-booted VM included — and otherwise as a
    /// capture is (``captureMode(phase:facts:)``).
    static func cloneMode(phase: VMLifecyclePhase, facts: Facts) -> VMCaptureMode? {
        if phase.isAtRest, !facts.hasSaveFile { return .stopped }
        return captureMode(phase: phase, facts: facts)
    }

    /// The mode a clone is offered in, over the settled phase the VM rests at
    /// as ``settledCaptureMode(phase:facts:)`` reads it — so an operation in
    /// flight dims Clone rather than hiding it.
    static func settledCloneMode(phase: VMLifecyclePhase, facts: Facts) -> VMCaptureMode? {
        let settled = phase.operation?.settledBasis(slotOnDisk: facts.hasSaveFile) ?? phase
        return cloneMode(phase: settled, facts: facts)
    }

    /// The edit classes a settled phase admits.
    ///
    /// A share swap is admitted only by a running guest whose shares ride one
    /// device: it is the only phase with a device to swap on that was measured
    /// taking one (docs/research/2026-09-30-live-share-edits-reach-a-running-macos-guest.md).
    static func editClasses(settledAt phase: VMLifecyclePhase, facts: Facts) -> VMEditClasses {
        switch phase {
        case .stopped, .initialBoot, .failed, .suspended:
            let atRest = VMEditClasses.all.subtracting(.liveShares)
            guard facts.hasSaveFile else { return atRest }
            var pinned = atRest.subtracting([.machineKeys, .hotPlugMedia, .networkAttachment])
            if !facts.savedStateSurvivesMembershipMove { pinned.remove(.networkMembership) }
            return pinned
        case .running, .livePaused:
            var classes = VMEditClasses.all.subtracting([
                .machineKeys, .networkAttachment, .networkMembership, .liveShares,
            ])
            if facts.networkEnabled { classes.formUnion([.networkAttachment, .networkMembership]) }
            if case .running = phase, facts.guestOS.sharesDirectoriesThroughOneDevice {
                classes.insert(.liveShares)
            }
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
            if case .start = request, kind == .bringUp(.guestStart(.restoringSavedState)), posture == .offer {
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
        case .bringUp(.guestStart(.starting(let recovery))):
            admitted =
                atRest && !facts.hasSaveFile && !facts.hasPendingGuestSetup
                && (!recovery || (phase == .stopped && facts.guestOS == .macOS))
        case .bringUp(.guestStart(.restoringSavedState)):
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
        case .creatingStorageDisk, .removingStorageDisk:
            admitted = editClasses(settledAt: phase, facts: facts).contains(.machineKeys)
        case .creatingRemovableMedia:
            admitted = editClasses(settledAt: phase, facts: facts).contains(.hotPlugMedia)
        case .copyingOut(let mode):
            admitted = cloneMode(phase: phase, facts: facts) == mode
        }
        guard admitted else { return .refuse(.invalidState) }
        if let change = outsideBundleRule(kind, facts: facts) {
            return .refuse(.takesStoppedVM(change))
        }
        if case .bringUp(let bringUp) = kind, bringUp.checksIdentity {
            return identityChecked(facts)
        }
        if case .attachingUSB = kind, let holder = facts.accessoryHolder {
            return .refuse(.accessoryHeld(by: holder))
        }
        return .admit
    }

    /// The rule `kind` breaks on a VM with `facts`, or `nil` when it breaks
    /// none: a capture of a live or suspended VM carries its memory, and only
    /// the bundle's own disks are copied, so while the guest can write a disk
    /// outside the bundle that memory would resume over the disk as written
    /// since.
    private static func outsideBundleRule(
        _ kind: VMOperationKind, facts: Facts
    ) -> StoppedVMChange? {
        guard facts.writesOutsideBundle else { return nil }
        return switch kind {
        case .capturingSnapshot(let mode) where mode != .stopped: .snapshotWritingOutsideBundle
        case .copyingOut(let mode) where mode != .stopped: .cloneWritingOutsideBundle
        default: nil
        }
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
        // A session a Force Stop is terminating is held as `.forceStopping`: a
        // second Force Stop joins the first — offered, it reads as busy, like
        // every join — and the rest is answered as that kind declares.
        if let stop = operation.session?.stopping, request == .sessionAction(.forceStop) {
            return posture == .commit ? .join(stop) : .refuse(.busy(.forceStopping))
        }
        let holder = holder(of: operation)
        let declaration = holder.declaration
        if posture == .commit, joins(request, operation) {
            return .join(operation.outcome)
        }
        switch request {
        case .cancel(let family):
            if holder.belongs(to: family) { return .admit }
        case .edit(let classes):
            // A tolerated edit still answers to every settled rule — a build
            // without USB among them.
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
        return classified(request, posture: posture, against: basis, facts: facts, busy: holder)
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

    /// The kind whose declaration answers a request during `operation`: the
    /// operation's own, or ``VMOperationKind/forceStopping`` while a Force
    /// Stop is terminating its session.
    private static func holder(of operation: VMOperation) -> VMOperationKind {
        operation.session?.stopping == nil ? operation.kind : .forceStopping
    }

    /// Whether committing `request` during `operation` joins it — the one
    /// statement of the join rule.
    private static func joins(_ request: Request, _ operation: VMOperation) -> Bool {
        guard let join = join(for: request) else { return false }
        return holder(of: operation).declaration.joinedBy.contains(join)
    }

    private static func join(for request: Request) -> VMOperationDeclaration.Join? {
        switch request {
        case .start(recovery: false): .start
        case .resume: .resume
        case .operation(.reconcilingMedia): .reconcile
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
            return decideOnTheVM(
                .edit(.hotPlugMedia), posture: posture, phase: phase, facts: facts)
        }
        return admitted ? .admit : .refuse(.invalidState)
    }
}

/// Whose request admission is deciding, as the termination reads it.
///
/// Each exempt origin names the one request it exempts, and
/// ``exempts(_:)`` holds that pairing: any other request made under it is
/// decided as new work, so no caller can carry an exemption onto a request
/// it was not made for.
enum VMRequestOrigin: Sendable, Equatable {
    /// A person's verb, or work the app starts on its own — refused an
    /// operation once the termination has begun.
    case newWork
    /// The save pass's suspend of a VM settled live.
    case terminationSave
    /// The baseline revert an Ephemeral Mode VM owes each power-off, which a
    /// quit waits out rather than refuses — so a guest that powers off during
    /// one never rests on the disks the mode discards.
    case powerOffRevert
    /// The reconcile a removable-media edit admitted before the termination
    /// owes a live session, which a quit waits out rather than refuses — so
    /// the save that follows never pins a device list the configuration has
    /// left.
    case mediaEditReconcile

    /// Whether this origin exempts `request` from the termination's refusal.
    func exempts(_ request: VMAdmission.Request) -> Bool {
        switch self {
        case .newWork:
            return false
        case .terminationSave:
            return request == .operation(.saving)
        case .powerOffRevert:
            guard case .operation(.bringUp(.reverting)) = request else { return false }
            return true
        case .mediaEditReconcile:
            return request == .operation(.reconcilingMedia)
        }
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

    /// Whether the app's termination has begun.
    var isTerminating: Bool { get }

    /// Which VM holds each USB accessory passed through to a guest.
    var accessoryHolders: VMAccessoryHolders { get }

    /// The VM claiming the identity (``VMInstance/claimsIdentity``) that
    /// bringing `instance` up under `configuration` would duplicate, unless
    /// `override` waives it.
    func identityConflict(
        for instance: VMInstance, bringingUp configuration: VMConfiguration,
        override: VMIdentityOverride
    ) -> VMIdentityConflict?
}
