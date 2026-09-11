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
    case editPortForwarding
    case editConfiguration
    case editLiveConfiguration
    case switchNetworkMode
    case clone
    case rename
    case delete
    case cancelPreparing
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
        case .editPortForwarding: .editPortForwarding
        case .editConfiguration, .editLiveConfiguration, .switchNetworkMode: .setConfiguration
        case .clone: .clone
        case .rename: .rename
        case .delete: .delete
        case .cancelPreparing: .cancelPreparing
        case .showInFinder: .showInFinder
        case .toggleGuestAgentDisk: .guestAgentDisk
        case .startInRecovery, .togglePopOut, .toggleFullscreen, .showClipboard,
            .toggleSettingsPane:
            nil
        }
    }

    /// Whether this capability survives a create, clone or import still writing
    /// the VM's bundle: the in-memory reads, and the cancel that stops the write.
    ///
    /// A preparing row's bundle is built under a hidden staging path and
    /// published by rename when the write finishes, so nothing that reads
    /// ``VMInstance/bundleURL`` on disk — `showInFinder` — belongs here.
    ///
    /// Exhaustive rather than `default`, so a new capability has to choose a
    /// side.
    var survivesPreparing: Bool {
        switch self {
        case .info, .ipAddress, .snapshots, .reveal, .cancelPreparing:
            true
        case .start, .startInRecovery, .cancelGuestSetup, .stop, .restart, .forceStop,
            .discardSavedState, .pause, .resume, .suspend, .open, .takeSnapshot, .revertToSnapshot,
            .deleteSnapshot, .renameSnapshot, .setSnapshotNotes, .editStorageDisks,
            .editRemovableMedia, .editSharedDirectories, .editUSBAccessories,
            .editPortForwarding, .editConfiguration,
            .editLiveConfiguration, .switchNetworkMode, .clone, .rename, .delete, .showInFinder,
            .togglePopOut, .toggleFullscreen, .showClipboard, .toggleGuestAgentDisk,
            .toggleSettingsPane:
            false
        }
    }

    /// Whether this capability waits for an operation that is still settling.
    ///
    /// Each of these moves VM state or snapshot files and would race an
    /// operation that is still settling, so it reads as unavailable rather than
    /// erroring on click. A snapshot's name and note are metadata-only manifest
    /// writes no operation reads mid-flight, and are deliberately not on this
    /// list.
    ///
    /// Exhaustive rather than `default`, so a new capability has to choose a
    /// side.
    var waitsForSettle: Bool {
        switch self {
        case .takeSnapshot, .revertToSnapshot, .deleteSnapshot:
            true
        case .info, .ipAddress, .snapshots, .start, .startInRecovery, .cancelGuestSetup, .stop,
            .restart, .forceStop, .discardSavedState, .pause, .resume, .suspend, .open, .reveal,
            .renameSnapshot, .setSnapshotNotes, .editStorageDisks, .editRemovableMedia,
            .editSharedDirectories, .editUSBAccessories, .editPortForwarding, .editConfiguration,
            .editLiveConfiguration, .switchNetworkMode, .clone, .rename, .delete, .cancelPreparing,
            .showInFinder, .togglePopOut, .toggleFullscreen, .showClipboard, .toggleGuestAgentDisk,
            .toggleSettingsPane:
            false
        }
    }

    /// Whether this capability writes, trashes or overwrites the files an
    /// in-flight clone of this VM is still copying out of its bundle.
    ///
    /// Exhaustive rather than `default`, so a new capability has to choose a
    /// side. Removable media and shared directories are referenced by path,
    /// never copied, so a live edit of either does not touch anything the clone
    /// reads; cloning the same source again only reads it too. A start (or a
    /// start into Recovery) locks too: a booted guest writes `Disk.asif`,
    /// `AuxiliaryStorage`, `EFIVariableStore` and the additional disks the copy
    /// is reading, and a revert reached only by starting first (an Ephemeral
    /// baseline restore) is closed by this rather than needing its own guard.
    var locksWhileCloned: Bool {
        switch self {
        case .start, .startInRecovery, .editStorageDisks, .delete, .revertToSnapshot:
            true
        case .info, .ipAddress, .snapshots, .cancelGuestSetup, .stop,
            .restart, .forceStop, .discardSavedState, .pause, .resume, .suspend, .open, .reveal,
            .takeSnapshot, .deleteSnapshot, .renameSnapshot, .setSnapshotNotes,
            .editRemovableMedia, .editSharedDirectories, .editUSBAccessories, .editPortForwarding,
            .editConfiguration,
            .editLiveConfiguration, .switchNetworkMode, .clone, .rename, .cancelPreparing,
            .showInFinder, .togglePopOut, .toggleFullscreen, .showClipboard, .toggleGuestAgentDisk,
            .toggleSettingsPane:
            false
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

    /// Whether the VM's own state admits `capability` at all — the level a
    /// surface that *hides* an unavailable command reads.
    ///
    /// Transient blockers are deliberately absent: a VM that can be snapshotted
    /// still shows Take Snapshot while an operation settles, dimmed.
    /// Exhaustive rather than `default`, so a new capability has to be answered
    /// here as well as in ``isAvailable(_:on:)`` and ``accepts(_:on:)``.
    func isApplicable(_ capability: VMCapability, to instance: VMInstance) -> Bool {
        switch capability {
        case .info, .ipAddress, .snapshots, .reveal, .showInFinder,
            .deleteSnapshot, .renameSnapshot, .setSnapshotNotes:
            true
        case .start:
            instance.canStart
        case .startInRecovery:
            instance.canStartInRecovery
        case .cancelGuestSetup:
            instance.setupTask != nil
        case .stop, .restart:
            instance.canStop
        case .forceStop:
            instance.canForceStop
        case .discardSavedState:
            instance.isColdPaused
        case .pause:
            instance.canPause
        case .resume:
            instance.canResume
        case .suspend:
            instance.canSave
        case .open, .toggleSettingsPane:
            instance.hasActiveDisplay
        case .takeSnapshot:
            instance.canTakeSnapshot
        case .revertToSnapshot:
            instance.canRevertToSnapshot
        case .editStorageDisks:
            instance.canEditSettings
        case .editRemovableMedia:
            // Removable media is hot-pluggable, so a live guest takes an edit
            // the pinned device set of a stopped VM's saved state cannot.
            instance.canEditSettings || instance.hasLiveSession
        case .editSharedDirectories:
            // A VM's virtiofs device set is fixed at boot, so a share edit lands
            // only on a VM that can still be reconfigured.
            instance.canEditSettings
        case .editUSBAccessories:
            // Stricter than removable media twice over: a passthrough accessory
            // has no persisted entry to pre-configure, so it exists only on a
            // guest already running — and a build that cannot claim an
            // accessory at all must not name the verb among those a VM accepts.
            library.supportsUSBAccessories && instance.hasLiveSession
        case .editPortForwarding, .editConfiguration:
            instance.canEditSettings
        case .editLiveConfiguration:
            // The settings this gates are read at moments other than boot — the
            // Ephemeral flag at power-off, the clipboard flags and the display
            // policy by the running session — so no state pins them.
            true
        case .switchNetworkMode:
            // While the pane is read-only its Mode picker stays live as the
            // hot-swap surface: swapping the attachment needs a session and a
            // device to swap on. None-mode VMs have no device, and devices
            // cannot be added or removed at runtime.
            instance.canEditSettings
                || (instance.configuration.networkEnabled
                    && (instance.status == .running || instance.isLivePaused))
        case .clone:
            instance.canEditSettings
        case .rename:
            instance.canRename
        case .delete:
            instance.canDelete
        case .cancelPreparing:
            instance.isPreparing
        case .togglePopOut, .toggleFullscreen:
            instance.canUseExternalDisplay
        case .showClipboard:
            instance.canShowClipboard
        case .toggleGuestAgentDisk:
            instance.canManageGuestAgentDisk
        }
    }

    /// Whether `capability` can be invoked right now — applicable, with nothing
    /// transient in the way.
    ///
    /// The level every `isEnabled` and every menu- or toolbar-validation reads.
    /// Three things are layered over applicability: one uniform rule for a
    /// bundle a create, clone or import is still writing
    /// (``VMCapability/survivesPreparing``), the settle check for the commands
    /// an unsettled operation would reject (``VMCapability/waitsForSettle``),
    /// and the lock a clone still copying this VM's files out of its bundle
    /// places on the source (``VMCapability/locksWhileCloned``).
    func isAvailable(_ capability: VMCapability, on instance: VMInstance) -> Bool {
        isApplicable(capability, to: instance)
            && transientBlockersClear(capability, on: instance)
    }

    /// The three transient layers ``isAvailable(_:on:)`` and ``accepts(_:on:)``
    /// share: a bundle a create, clone or import is still writing
    /// (``VMCapability/survivesPreparing``), the clone still copying this VM's
    /// files out of its bundle (``VMCapability/locksWhileCloned``), and the
    /// settle check for the commands an unsettled operation would reject
    /// (``VMCapability/waitsForSettle``).
    ///
    /// Only the applicability term separates the two levels, so a capability
    /// whose commit is wider than its offer widens that term alone and cannot
    /// escape a blocker by being an exception.
    private func transientBlockersClear(
        _ capability: VMCapability, on instance: VMInstance
    ) -> Bool {
        guard capability.survivesPreparing || !instance.isPreparing else { return false }
        guard !(capability.locksWhileCloned && library.hasCloneInFlight(from: instance)) else {
            return false
        }
        return !(capability.waitsForSettle && library.isBusy(instance))
    }

    /// Whether `snapshot` may be deleted: the manifest has to be editable, and
    /// a VM's Ephemeral baseline is the restore point its every power-off needs.
    func canDeleteSnapshot(_ snapshot: VMSnapshot, on instance: VMInstance) -> Bool {
        isAvailable(.deleteSnapshot, on: instance) && !instance.isEphemeralBaseline(snapshot)
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

    /// Whether a commit of `capability` is taken now — what a verb's own guard
    /// asks, and what a refusal names as accepted.
    ///
    /// ``isAvailable(_:on:)`` over ``admitsCommit(_:on:)``: the transient
    /// blockers are the same, and only the state term is wider.
    func accepts(_ capability: VMCapability, on instance: VMInstance) -> Bool {
        admitsCommit(capability, on: instance)
            && transientBlockersClear(capability, on: instance)
    }

    /// Whether the VM's own state takes a *commit* of `capability` —
    /// ``isApplicable(_:to:)`` everywhere but the capabilities deliberately
    /// taken in a state they are not offered in.
    ///
    /// Exhaustive rather than `default`, so a new capability has to choose a
    /// side here too.
    private func admitsCommit(_ capability: VMCapability, on instance: VMInstance) -> Bool {
        switch capability {
        case .start:
            // A start committed against a VM already coming up is asking for the
            // state that bring-up is producing, so it joins it
            // (``VMCommandCore/start(_:recovery:presentation:)``) rather than
            // refusing a VM on its way to running. Both bring-up phases count:
            // a boot with a save file passes through `.starting` into
            // `.restoringSavedState` before its first await, so the restore is
            // the whole of what another caller can observe. Offering it is the
            // separate question ``isAvailable(_:on:)`` answers.
            switch instance.phase {
            case .starting, .restoringSavedState: return true
            default: return isApplicable(.start, to: instance)
            }
        case .resume:
            // The same join, for the one bring-up phase a resume of its own
            // stands in.
            if case .restoringSavedState = instance.phase { return true }
            return isApplicable(.resume, to: instance)
        case .rename:
            // Offering a rename and taking one are deliberately different
            // states. A rename rewrites the name and nothing a running
            // operation reads, so a name typed into a field editor that was
            // open when the VM started or began suspending is kept rather than
            // traded for an alert — only the revert that will assign a whole
            // configuration back over this one refuses
            // (``VMLifecyclePhase/renamePersists``).
            return instance.renamePersists
        case .info, .ipAddress, .snapshots, .startInRecovery, .cancelGuestSetup, .stop,
            .restart, .forceStop, .discardSavedState, .pause, .suspend, .open, .reveal,
            .takeSnapshot, .revertToSnapshot, .deleteSnapshot, .renameSnapshot, .setSnapshotNotes,
            .editStorageDisks, .editRemovableMedia, .editSharedDirectories, .editUSBAccessories,
            .editPortForwarding,
            .editConfiguration, .editLiveConfiguration, .switchNetworkMode, .clone, .delete,
            .cancelPreparing, .showInFinder, .togglePopOut, .toggleFullscreen, .showClipboard,
            .toggleGuestAgentDisk, .toggleSettingsPane:
            return isApplicable(capability, to: instance)
        }
    }
}
