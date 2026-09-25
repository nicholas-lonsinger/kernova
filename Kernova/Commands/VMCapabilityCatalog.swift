import Foundation
import KernovaKit

/// One thing a VM can be asked to do — every wire verb, plus the GUI-only
/// affordances that carry a predicate of their own.
///
/// A case per *distinct* predicate. The ⌥-alternates (Clone with the opposite
/// machine-ID choice, Delete Immediately) share their primary's exactly, so
/// they get none: a second case would be a second thing to keep in step.
///
/// Declaration order is the order ``VMCommandCore/allowedVerbs(for:)`` reports,
/// which a refusal reads out to the user as "What it accepts now" — so moving a
/// case rewrites a sentence.
enum VMCapability: CaseIterable, Hashable {
    case info
    case ipAddress
    case snapshots
    case start
    case startInRecovery
    case cancelGuestSetup
    case stop
    case restart
    case forceStop
    case discardSavedState
    case pause
    case resume
    case suspend
    case open
    case reveal
    case takeSnapshot
    case revertToSnapshot
    case deleteSnapshot
    case renameSnapshot
    case setSnapshotNotes
    case editStorageDisks
    case editRemovableMedia
    case editSharedDirectories
    case editUSBAccessories
    case forgetUSBPairing
    case editConfiguration
    case editLiveConfiguration
    case switchNetworkMode
    case clone
    case rename
    case delete
    case showInFinder
    case togglePopOut
    case toggleFullscreen
    case showClipboard
    case toggleGuestAgentDisk
    case toggleSettingsPane

    /// The wire verb this capability performs, or `nil` for an affordance only
    /// the GUI offers.
    ///
    /// Not injective: the graceful stop, the forceful one and the cold-paused
    /// discard are one verb on the wire and three differently-gated commands in
    /// the UI.
    var verb: VMVerb? {
        switch self {
        case .info: .info
        case .ipAddress: .ipAddress
        case .snapshots: .snapshots
        case .start: .start
        case .cancelGuestSetup: .cancelGuestSetup
        case .stop, .forceStop, .discardSavedState: .stop
        case .restart: .restart
        case .pause: .pause
        case .resume: .resume
        case .suspend: .suspend
        case .open: .open
        case .reveal: .reveal
        case .takeSnapshot: .takeSnapshot
        case .revertToSnapshot: .revertToSnapshot
        case .deleteSnapshot: .deleteSnapshot
        case .renameSnapshot: .renameSnapshot
        case .setSnapshotNotes: .setSnapshotNotes
        case .editStorageDisks: .editStorageDisk
        case .editRemovableMedia: .editRemovableMedia
        case .editSharedDirectories: .editSharedDirectory
        case .editUSBAccessories: .editUSBAccessory
        case .forgetUSBPairing: .forgetUSBPairing
        case .editConfiguration, .editLiveConfiguration, .switchNetworkMode: .setConfiguration
        case .clone: .clone
        case .rename: .rename
        case .delete: .delete
        case .showInFinder: .showInFinder
        case .toggleGuestAgentDisk: .guestAgentDisk
        case .startInRecovery, .togglePopOut, .toggleFullscreen, .showClipboard,
            .toggleSettingsPane:
            nil
        }
    }

    /// The request admission decides for this capability on `instance`, or
    /// `nil` when the VM's state names none — a capture from a phase no mode
    /// is taken from.
    @MainActor
    func request(on instance: VMInstance) -> VMAdmission.Request? {
        switch self {
        case .info, .ipAddress, .snapshots, .reveal, .showInFinder:
            return .affordance(.inspect)
        case .start:
            return .start(recovery: false)
        case .startInRecovery:
            return .start(recovery: true)
        case .cancelGuestSetup:
            return .cancel(.guestSetup)
        case .stop, .restart:
            return .sessionAction(.requestStop)
        case .forceStop:
            return .sessionAction(.forceStop)
        case .discardSavedState:
            return .operation(.discardingSavedState)
        case .pause:
            return .operation(.pausing)
        case .resume:
            return .resume
        case .suspend:
            return .operation(.saving)
        case .open, .toggleSettingsPane:
            return .affordance(.display)
        case .takeSnapshot:
            guard
                let mode = VMAdmission.settledCaptureMode(
                    phase: instance.phase, facts: instance.admissionFacts)
            else { return nil }
            return .operation(.capturingSnapshot(mode))
        case .revertToSnapshot:
            // Which snapshot does not change the decision.
            return .operation(.bringUp(.reverting(snapshotID: UUID(), resumesAfter: false)))
        case .deleteSnapshot:
            return .operation(.deletingSnapshot)
        case .renameSnapshot, .setSnapshotNotes:
            return .edit(.snapshotMetadata)
        case .editStorageDisks, .editSharedDirectories, .editConfiguration:
            return .edit(.machineKeys)
        case .editRemovableMedia:
            return .edit(.hotPlugMedia)
        case .editUSBAccessories:
            // Which accessory does not change the decision.
            return .operation(.attachingUSB(registryID: 0))
        case .forgetUSBPairing:
            return .edit(.pairingRules)
        case .editLiveConfiguration:
            return .edit(.liveKeys)
        case .switchNetworkMode:
            return .edit(.networkAttachment)
        case .clone:
            return .operation(.copyingOut)
        case .rename:
            return .edit(.rename)
        case .delete:
            return .operation(.deleting)
        case .togglePopOut, .toggleFullscreen:
            return .affordance(.externalDisplay)
        case .showClipboard:
            return .affordance(.clipboard)
        case .toggleGuestAgentDisk:
            return .affordance(.guestAgentDisk)
        }
    }
}

/// Where every per-VM capability predicate is derived, for the headless verbs
/// and every surface that offers them.
///
/// Three levels, because the surfaces genuinely read three:
/// ``isApplicable(_:to:)`` for what to *show*, ``isAvailable(_:on:)`` for what
/// to *enable*, ``accepts(_:on:)`` for what a verb takes when the user commits.
///
/// Headless: it imports no AppKit and holds no titles. What a command is called
/// belongs to `VMInstance+Display`, and a menu's structure to the menu.
@MainActor
struct VMCapabilityCatalog {
    let library: VMLibrary

    /// How admission decides `capability` on `instance` right now, in
    /// `posture`; `nil` when the VM's state names no request for it.
    ///
    /// The one reading every level below is taken from, and the same decision
    /// ``VMActivity`` commits — so what a surface offers and what a verb takes
    /// agree by construction.
    func decision(
        _ capability: VMCapability, on instance: VMInstance, posture: VMAdmission.Posture
    ) -> VMAdmission.Decision? {
        capability.request(on: instance).map {
            instance.activity.decide($0, posture: posture)
        }
    }

    /// Whether the VM's own state admits `capability` at all — the level a
    /// surface that *hides* an unavailable command reads.
    ///
    /// An operation holding the VM is no reason to hide one: a VM that can be
    /// snapshotted still shows Take Snapshot while another operation runs,
    /// dimmed.
    func isApplicable(_ capability: VMCapability, to instance: VMInstance) -> Bool {
        switch decision(capability, on: instance, posture: .offer) {
        case .admit, .join, .refuse(.busy): true
        case .refuse, nil: false
        }
    }

    /// Whether `capability` can be invoked right now — the level every
    /// `isEnabled` and every menu- or toolbar-validation reads.
    func isAvailable(_ capability: VMCapability, on instance: VMInstance) -> Bool {
        decision(capability, on: instance, posture: .offer) == .admit
    }

    /// Whether one snapshot's delete is offered, and what bars it when it is
    /// not.
    enum SnapshotDeleteOffer: Equatable {
        /// The delete is taken now.
        case offered
        /// The VM's Ephemeral baseline — the restore point its every power-off
        /// needs, so the mode bars deleting it.
        case barredAsBaseline
        /// The VM's state, or an operation still settling, holds the manifest.
        case unavailable
    }

    /// What `snapshot`'s delete is offered as — the one derivation a row renders
    /// both its enablement and the reason behind it from.
    func snapshotDeleteOffer(
        _ snapshot: VMSnapshot, on instance: VMInstance
    ) -> SnapshotDeleteOffer {
        guard isAvailable(.deleteSnapshot, on: instance) else { return .unavailable }
        return instance.isEphemeralBaseline(snapshot) ? .barredAsBaseline : .offered
    }

    /// Whether `snapshot` may be deleted.
    func canDeleteSnapshot(_ snapshot: VMSnapshot, on instance: VMInstance) -> Bool {
        snapshotDeleteOffer(snapshot, on: instance) == .offered
    }

    /// Where bringing one VM in front of the user lands.
    enum RevealSurface: Equatable {
        /// The VM's own display window — the pop-out or fullscreen host.
        case displayWindow
        /// The library window, selected on the VM — which is also where an
        /// inline display lives.
        case library
    }

    /// Which window a request to bring `instance` in front of the user puts on
    /// screen — the derivation ``VMCommandCore/reveal(_:)``'s surfacing and the
    /// status item's per-VM command both read.
    ///
    /// Two terms. The ``VMCapability/open`` gate decides whether a display is
    /// the right thing to surface at all, so a VM with none lands on its library
    /// row. The display preference decides where that display lives: an inline
    /// one *is* part of the library window, so the library is what comes
    /// forward for it.
    func revealSurface(for instance: VMInstance) -> RevealSurface {
        guard accepts(.open, on: instance),
            instance.hostState.displayPreference != .inline
        else { return .library }
        return .displayWindow
    }

    /// What this VM's stop slot performs — the derivation every surface sharing
    /// that slot renders and dispatches from.
    ///
    /// An Ephemeral VM's discard is routed to a baseline revert, so the slot
    /// names that outcome; the plain discard is what a VM without a baseline
    /// gets.
    func stopAction(for instance: VMInstance) -> VMInstance.StopAction {
        guard isApplicable(.discardSavedState, to: instance) else { return .stop }
        return instance.ephemeralBaselineSnapshot == nil ? .discardSavedState : .revertToBaseline
    }

    /// The verb that brings a VM back up.
    enum BringUpVerb: Equatable {
        case start
        case resume
    }

    /// Which verb brings `instance` back up, or `nil` when its state admits
    /// neither.
    ///
    /// A VM holding a saved state is resumed: its memory is in the bundle's
    /// suspend slot, and a boot would discard it. A live-paused one is neither —
    /// its memory never left the host, so there is no bring-up owed.
    func bringUpVerb(for instance: VMInstance) -> BringUpVerb? {
        if isAvailable(.resume, on: instance), instance.holdsSuspendedSession { return .resume }
        return isAvailable(.start, on: instance) ? .start : nil
    }

    /// What a bring-up taken from a standing preference rather than a command
    /// may do with this VM, or `nil`.
    ///
    /// The launch pass acts on ``VMHostState/startsAutomaticallyOnLaunch``,
    /// so it begins no guest setup and raises no question: a VM with a macOS
    /// install or a Linux image download still to run is passed over, and so is
    /// one still owing its guest an account answer
    /// (``owesGuestAccountAnswer(_:)``). Both are decided here rather than left
    /// to the verb, because the pass has no window for what either would put on
    /// screen.
    func standingBringUp(for instance: VMInstance) -> BringUpVerb? {
        guard instance.configuration.pendingGuestSetup == nil,
            !owesGuestAccountAnswer(instance)
        else { return nil }
        return bringUpVerb(for: instance)
    }

    /// Where a VM stands on the macOS account it was set up with.
    enum GuestAccountState: Equatable {
        /// Nothing to create: the VM names no account, or this host's
        /// Virtualization can deliver none.
        case none
        /// The account is named and nobody has supplied its password.
        case owed(GuestAccountIntent)
        /// The account is named and answered for.
        case answered(GuestAccountIntent, GuestAccountPassword)
    }

    /// What `instance` still owes its guest about that account, and what has been
    /// supplied for it.
    ///
    /// The one spelling of the three facts every reader needs some part of: the
    /// VM names an account, this host's Virtualization can deliver one, and
    /// somebody has supplied the password. macOS reads the account on the first
    /// boot after restore and on no other, so a boot carrying none does not
    /// postpone it — it destroys it, which is why a start refuses
    /// ``GuestAccountState/owed(_:)`` rather than proceeding
    /// (``CommandError/guestAccountPasswordRequired(_:)``).
    func guestAccountState(of instance: VMInstance) -> GuestAccountState {
        guard let account = Self.deliverableGuestAccount(of: instance.configuration) else {
            return .none
        }
        guard let password = library.heldGuestAccountPassword(for: instance) else {
            return .owed(account)
        }
        return .answered(account, password)
    }

    /// The account a VM configured as `configuration` names for its guest, or
    /// `nil` when it names none or this host's Virtualization can deliver none.
    static func deliverableGuestAccount(of configuration: VMConfiguration) -> GuestAccountIntent? {
        guard MacOSGuestProvisioning.hostSupportsProvisioning else { return nil }
        return configuration.pendingGuestAccount
    }

    /// Whether `instance` has the account question outstanding — what a surface
    /// deciding whether to raise it reads.
    func owesGuestAccountAnswer(_ instance: VMInstance) -> Bool {
        guard case .owed = guestAccountState(of: instance) else { return false }
        return true
    }

    /// Whether the stop slot can be invoked now.
    ///
    /// The slot stands for two capabilities, and layers the baseline's own rule
    /// over them: a VM already resting on its baseline's saved state has nothing
    /// to revert, and a revert that would restore what is already there is an
    /// action with no outcome to offer.
    func isStopActionAvailable(on instance: VMInstance) -> Bool {
        guard !instance.isRestingAtEphemeralBaseline else { return false }
        return isAvailable(.stop, on: instance) || isAvailable(.discardSavedState, on: instance)
    }

    /// Whether a commit of `capability` would be taken once the VM's saved
    /// state is discarded — so work that follows a discard is known to be
    /// admitted before the irreversible step is taken, with every other
    /// blocker answering exactly as it will answer the verb.
    func acceptsAsIfSavedStateDiscarded(
        _ capability: VMCapability, on instance: VMInstance
    ) -> Bool {
        guard let request = capability.request(on: instance) else { return false }
        switch instance.activity.decideAsIfSavedStateDiscarded(request, posture: .commit) {
        case .admit, .join: return true
        case .refuse: return false
        }
    }

    /// Whether a commit of `capability` is taken now — what a verb's own guard
    /// asks, and what a refusal names as accepted.
    ///
    /// Wider than ``isAvailable(_:on:)`` only where the commit posture is: a
    /// Start of a VM holding a saved state restores it, and a Start or Resume
    /// during the bring-up it asks for joins it.
    func accepts(_ capability: VMCapability, on instance: VMInstance) -> Bool {
        switch decision(capability, on: instance, posture: .commit) {
        case .admit, .join: true
        case .refuse, nil: false
        }
    }
}
