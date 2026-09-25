import Foundation
import KernovaKit

// MARK: - Phase

/// Where a VM is in its lifecycle — the one value ``VMActivity`` stores, and
/// what its ``VMStatus``, its failure message and every liveness predicate
/// project from.
///
/// Settled phases name where the VM rests or runs; ``operating(_:)`` names the
/// one long operation that holds it. A live phase carries the session's
/// identity, and ``VMActivity/sessionContext`` holds the session whose `id`
/// equals it.
enum VMLifecyclePhaseNext: Sendable, Equatable {
    /// Powered off, with no saved state to come back on.
    case stopped

    /// In the library but never booted — Start runs the guest setup first.
    case initialBoot

    /// The last operation failed permanently. `message` is what the error
    /// banner and the status tooltip read, so it cannot survive the move to any
    /// other phase.
    case failed(message: String)

    /// Suspended to disk: the guest's memory is in the bundle's suspend slot
    /// and nothing is live.
    case suspended

    case running(sessionID: UUID)

    /// Paused with the `VZVirtualMachine` still in memory, which Resume takes
    /// straight back — as opposed to ``suspended``.
    case livePaused(sessionID: UUID)

    /// Exactly one long operation holds the VM.
    indirect case operating(VMOperation)

    /// Evicted from the library; admits nothing.
    case removed

    // MARK: Settled

    /// Whether this is a settled phase — anything but an operation.
    var isSettled: Bool {
        if case .operating = self { return false }
        return true
    }

    /// Whether the VM is settled with nothing live — the phases a bring-up
    /// begins from.
    var isAtRest: Bool {
        switch self {
        case .stopped, .initialBoot, .failed, .suspended: true
        case .running, .livePaused, .operating, .removed: false
        }
    }

    /// Whether the VM is settled with a live session.
    var isSettledLive: Bool {
        switch self {
        case .running, .livePaused: true
        case .stopped, .initialBoot, .failed, .suspended, .operating, .removed: false
        }
    }

    /// The operation holding the VM, or `nil` in a settled phase.
    var operation: VMOperation? {
        guard case .operating(let operation) = self else { return nil }
        return operation
    }

    // MARK: Session Identity

    /// The live session this phase names — a settled live phase's, or the
    /// session an operation holds — or `nil`.
    ///
    /// A `VZVirtualMachine` is in memory exactly while this is non-`nil`.
    var sessionID: UUID? {
        switch self {
        case .running(let id), .livePaused(let id): id
        case .operating(let operation): operation.session?.id
        case .stopped, .initialBoot, .failed, .suspended, .removed: nil
        }
    }

    // MARK: Presentation

    /// The settled phase surfaces present: this phase, except for an operation
    /// that declares ``VMOperationDeclaration/Status/base`` status, which
    /// presents the phase it started from — so a USB attach or a media
    /// reconcile never changes what the user sees.
    var presented: VMLifecyclePhaseNext {
        guard case .operating(let operation) = self,
            operation.kind.declaration.status == .base
        else { return self }
        guard operation.sessionEnd == nil else { return .stopped }
        guard let session = operation.session else { return operation.startedFrom }
        switch session.guest {
        case .running: return .running(sessionID: session.id)
        case .paused: return .livePaused(sessionID: session.id)
        }
    }

    /// The vocabulary every automation surface and every label reads.
    var status: VMStatus {
        switch self {
        case .stopped, .removed: .stopped
        case .initialBoot: .initialBoot
        case .failed: .error
        case .running: .running
        case .livePaused, .suspended: .paused
        case .operating(let operation):
            switch operation.kind.declaration.status {
            case .shows(let status): status
            case .base: presented.status
            }
        }
    }

    /// The permanent-failure message, or `nil` in every other phase.
    var errorMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }

    /// Whether a live session is presented as settled — the VMs a device can be
    /// attached to, a display can pop out of, and a termination save-suspends.
    var hasLiveSession: Bool { presented.isSettledLive }

    /// Whether the presented phase is paused with the VM still in memory.
    var isLivePaused: Bool {
        if case .livePaused = presented { return true }
        return false
    }

    /// Whether the VM counts as holding its machine identity and MAC address
    /// against another VM's bring-up and a live network-mode switch.
    var holdsLiveIdentity: Bool {
        switch self {
        case .running, .livePaused: true
        case .stopped, .initialBoot, .failed, .suspended, .removed: false
        case .operating(let operation):
            switch operation.kind.declaration.holdsIdentity {
            case .always: true
            case .viaSession: operation.session != nil
            case .never: false
            }
        }
    }

    /// Whether the VM has a display session a backing view should present.
    var hasActiveDisplay: Bool {
        switch self {
        case .running, .livePaused, .suspended: true
        case .stopped, .initialBoot, .failed, .removed: false
        case .operating(let operation):
            switch operation.kind.declaration.display {
            case .shown: true
            case .hidden: false
            case .base: presented.hasActiveDisplay
            }
        }
    }
}

// MARK: - Operation

/// The one long operation holding a VM.
struct VMOperation: Sendable, Equatable {
    let kind: VMOperationKind

    /// The settled phase the operation was admitted from — what its base
    /// status presents, and what a request during it is classified against.
    let startedFrom: VMLifecyclePhaseNext

    /// The session the operation holds, or `nil` while it has none — before a
    /// bring-up creates one, or once the session ended mid-operation.
    var session: VMOperationSession?

    /// How the operation's session ended, once it has.
    var sessionEnd: VMSessionEnd?

    /// What a caller joining the operation awaits.
    let outcome: VMOutcome
}

/// A session an operation holds, and whether its guest is executing.
struct VMOperationSession: Sendable, Equatable {
    let id: UUID
    var guest: VMGuestRunState
}

/// Whether a live guest is executing.
enum VMGuestRunState: Sendable, Equatable {
    case running
    case paused
}

/// How an operation's session ended.
enum VMSessionEnd: Sendable, Equatable {
    /// The guest powered off — shut down from inside, or force stopped.
    case poweredOff
    /// Virtualization stopped the guest with an error.
    case stoppedWithError(message: String)
    /// The operation ended the session itself: a save, a revert.
    case endedByOperation
}

/// How an operation ended, for every caller that joined it.
///
/// Equal by identity: one operation, one outcome.
@MainActor
final class VMOutcome: Sendable, Equatable {
    private var result: Result<Void, any Error>?
    private var waiters: [CheckedContinuation<Result<Void, any Error>, Never>] = []

    /// The task a launched operation runs its body in, which cancelling the
    /// operation cancels.
    var task: Task<Void, Never>?

    /// Records how the operation ended and wakes every joined caller.
    ///
    /// The first resolution stands.
    func resolve(_ result: Result<Void, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        let waiting = waiters
        waiters = []
        for waiter in waiting { waiter.resume(returning: result) }
    }

    /// Waits for the operation to end and rethrows how it failed.
    func value() async throws {
        let result: Result<Void, any Error>
        if let resolved = self.result {
            result = resolved
        } else {
            result = await withCheckedContinuation { waiters.append($0) }
        }
        try result.get()
    }

    nonisolated static func == (lhs: VMOutcome, rhs: VMOutcome) -> Bool { lhs === rhs }
}

// MARK: - Kinds

/// What an operation does.
enum VMOperationKind: Sendable, Equatable {
    case bringUp(VMBringUpKind)
    case pausing
    /// A hot resume of a live-paused VM.
    case resuming
    case saving
    case capturingSnapshot(VMSnapshotCaptureMode)
    case deletingSnapshot
    case attachingUSB(registryID: UInt64)
    case detachingUSB(deviceID: UUID)
    case reconcilingMedia
    /// Force Stop of a settled live VM.
    case forceStopping
    case discardingSavedState
    case deleting
    /// A clone copying the VM's files out of its bundle.
    case copyingOut

    /// The operations a cancel request names.
    enum Family: Sendable, Equatable {
        case guestSetup
    }

    /// Whether this operation belongs to `family`.
    func belongs(to family: Family) -> Bool {
        switch family {
        case .guestSetup:
            if case .bringUp(.settingUp) = self { return true }
            return false
        }
    }
}

/// An operation that brings a guest up, or holds the VM across a restore that
/// may resume one.
enum VMBringUpKind: Sendable, Equatable {
    /// A cold boot, into Recovery when `recovery`.
    case starting(recovery: Bool)
    /// Start or Resume of a VM holding a saved state.
    case restoringSavedState
    case settingUp(GuestSetupKind)
    /// A revert to `snapshotID`, resuming the guest at its end when
    /// `resumesAfter`.
    case reverting(snapshotID: UUID, resumesAfter: Bool)

    /// Whether admission checks this bring-up against the identities other
    /// live VMs hold.
    ///
    /// A revert that resumes was live, so it already held its identity.
    var checksIdentity: Bool {
        switch self {
        case .starting, .restoringSavedState, .settingUp: true
        case .reverting: false
        }
    }
}

/// Which guest setup a first start runs.
enum GuestSetupKind: Sendable, Equatable {
    case macOSInstall
    case linuxImageDownload
}

/// An action on a live session that takes no admission of its own.
enum VMSessionAction: Sendable, Equatable {
    /// The ACPI shutdown request.
    case requestStop
    case forceStop
}

// MARK: - Edit Classes

/// What a write to a VM's persisted state touches, as admission reads it.
struct VMEditClasses: OptionSet, Sendable, Hashable {
    let rawValue: Int

    /// Hardware the `VZVirtualMachine` is built from, pinned by a live session
    /// and by a saved state.
    static let machineKeys = VMEditClasses(rawValue: 1 << 0)
    /// Settings read at moments other than boot.
    static let liveKeys = VMEditClasses(rawValue: 1 << 1)
    /// Removable media: pinned at rest by a saved state, hot-plugged live.
    static let hotPlugMedia = VMEditClasses(rawValue: 1 << 2)
    /// The live network attachment swap.
    static let networkAttachment = VMEditClasses(rawValue: 1 << 3)
    /// Where and how the host presents the VM.
    static let hostPresentation = VMEditClasses(rawValue: 1 << 4)
    static let snapshotMetadata = VMEditClasses(rawValue: 1 << 5)
    static let pairingRules = VMEditClasses(rawValue: 1 << 6)
    static let rename = VMEditClasses(rawValue: 1 << 7)
    /// What the host records from a live guest.
    static let observations = VMEditClasses(rawValue: 1 << 8)

    static let all: VMEditClasses = [
        .machineKeys, .liveKeys, .hotPlugMedia, .networkAttachment, .hostPresentation,
        .snapshotMetadata, .pairingRules, .rename, .observations,
    ]

    /// The classes a bring-up, save or capture leaves open.
    static let presentationAndMetadata: VMEditClasses = [
        .hostPresentation, .snapshotMetadata, .pairingRules, .rename, .observations,
    ]
}

// MARK: - Declarations

/// Everything admission and the projections read about one kind.
struct VMOperationDeclaration: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        /// The operation shows a status of its own.
        case shows(VMStatus)
        /// The operation presents the phase it started from.
        case base
    }

    enum Identity: Sendable, Equatable {
        case always
        /// While the operation's session is live.
        case viaSession
        case never
    }

    enum Quit: Sendable, Equatable {
        /// A quit may end the operation where it stands.
        case interrupt
        /// A quit waits for the operation to end.
        case waitOut
        /// The operation is synchronous; no quit can land during it.
        case notApplicable
    }

    enum Display: Sendable, Equatable {
        case shown
        case hidden
        case base
    }

    enum Edits: Sendable, Equatable {
        /// These classes, where the phase the operation started from admits
        /// them.
        case only(VMEditClasses)
        /// What the phase the operation started from admits, minus these.
        case baseExcept(VMEditClasses)
    }

    /// A request that joins the operation instead of being refused as busy.
    enum Join: Sendable, Equatable {
        case start
        case resume
        case forceStop
    }

    let status: Status
    let holdsIdentity: Identity
    let quit: Quit
    let display: Display
    let toleratedSessionActions: [VMSessionAction]
    let edits: Edits
    let joinedBy: [Join]
}

extension VMOperationKind {
    /// This kind's declaration, stated exhaustively.
    var declaration: VMOperationDeclaration {
        let stoppable: [VMSessionAction] = [.requestStop, .forceStop]
        switch self {
        case .bringUp(.starting):
            return .init(
                status: .shows(.starting), holdsIdentity: .always, quit: .interrupt,
                display: .hidden, toleratedSessionActions: [],
                edits: .only(.presentationAndMetadata), joinedBy: [.start])
        case .bringUp(.restoringSavedState):
            return .init(
                status: .shows(.restoring), holdsIdentity: .always, quit: .interrupt,
                display: .shown, toleratedSessionActions: [],
                edits: .only(.presentationAndMetadata), joinedBy: [.start, .resume])
        case .bringUp(.settingUp):
            return .init(
                status: .shows(.installing), holdsIdentity: .always, quit: .interrupt,
                display: .hidden, toleratedSessionActions: [],
                edits: .only(.presentationAndMetadata), joinedBy: [])
        case .bringUp(.reverting):
            return .init(
                status: .shows(.restoring), holdsIdentity: .always, quit: .waitOut,
                display: .shown, toleratedSessionActions: [],
                edits: .only(.presentationAndMetadata.subtracting(.rename)), joinedBy: [])
        case .pausing, .resuming, .attachingUSB, .detachingUSB:
            return .init(
                status: .base, holdsIdentity: .viaSession, quit: .waitOut, display: .base,
                toleratedSessionActions: stoppable, edits: .baseExcept(.hotPlugMedia),
                joinedBy: [])
        case .saving:
            return .init(
                status: .shows(.saving), holdsIdentity: .viaSession, quit: .waitOut,
                display: .shown, toleratedSessionActions: [],
                edits: .only(.presentationAndMetadata), joinedBy: [])
        case .capturingSnapshot:
            return .init(
                status: .shows(.snapshotting), holdsIdentity: .always, quit: .waitOut,
                display: .shown, toleratedSessionActions: [],
                edits: .only(.presentationAndMetadata), joinedBy: [])
        case .deletingSnapshot:
            return .init(
                status: .base, holdsIdentity: .viaSession, quit: .waitOut, display: .base,
                toleratedSessionActions: stoppable,
                edits: .baseExcept([.hotPlugMedia, .snapshotMetadata]), joinedBy: [])
        case .reconcilingMedia:
            return .init(
                status: .base, holdsIdentity: .viaSession, quit: .waitOut, display: .base,
                toleratedSessionActions: stoppable, edits: .baseExcept([]), joinedBy: [])
        case .forceStopping:
            return .init(
                status: .base, holdsIdentity: .viaSession, quit: .waitOut, display: .base,
                toleratedSessionActions: [], edits: .only(.presentationAndMetadata),
                joinedBy: [.forceStop])
        case .discardingSavedState:
            return .init(
                status: .base, holdsIdentity: .never, quit: .notApplicable, display: .base,
                toleratedSessionActions: [], edits: .only([]), joinedBy: [])
        case .deleting:
            return .init(
                status: .base, holdsIdentity: .never, quit: .waitOut, display: .base,
                toleratedSessionActions: [], edits: .only([]), joinedBy: [])
        case .copyingOut:
            return .init(
                status: .base, holdsIdentity: .never, quit: .interrupt, display: .base,
                toleratedSessionActions: [], edits: .baseExcept(.machineKeys), joinedBy: [])
        }
    }
}
