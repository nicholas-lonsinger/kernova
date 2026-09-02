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
    case takeSnapshot
    case revertToSnapshot
    case deleteSnapshot
    case renameSnapshot
    case setSnapshotNotes
    case editStorageDisks
    case editRemovableMedia
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
        case .takeSnapshot: .takeSnapshot
        case .revertToSnapshot: .revertToSnapshot
        case .deleteSnapshot: .deleteSnapshot
        case .renameSnapshot: .renameSnapshot
        case .setSnapshotNotes: .setSnapshotNotes
        case .editStorageDisks: .editStorageDisk
        case .editRemovableMedia: .editRemovableMedia
        case .clone: .clone
        case .rename: .rename
        case .delete: .delete
        case .cancelPreparing: .cancelPreparing
        case .toggleGuestAgentDisk: .guestAgentDisk
        case .startInRecovery, .showInFinder, .togglePopOut, .toggleFullscreen, .showClipboard,
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
        case .info, .ipAddress, .snapshots, .cancelPreparing:
            true
        case .start, .startInRecovery, .cancelGuestSetup, .stop, .restart, .forceStop,
            .discardSavedState, .pause, .resume, .suspend, .open, .takeSnapshot, .revertToSnapshot,
            .deleteSnapshot, .renameSnapshot, .setSnapshotNotes, .editStorageDisks,
            .editRemovableMedia, .clone, .rename, .delete, .showInFinder, .togglePopOut,
            .toggleFullscreen, .showClipboard, .toggleGuestAgentDisk, .toggleSettingsPane:
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
            .restart, .forceStop, .discardSavedState, .pause, .resume, .suspend, .open,
            .renameSnapshot, .setSnapshotNotes, .editStorageDisks, .editRemovableMedia, .clone,
            .rename, .delete, .cancelPreparing, .showInFinder, .togglePopOut, .toggleFullscreen,
            .showClipboard, .toggleGuestAgentDisk, .toggleSettingsPane:
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
        case .info, .ipAddress, .snapshots, .showInFinder,
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
    /// Two things are layered over applicability: one uniform rule for a bundle
    /// a create, clone or import is still writing (``VMCapability/survivesPreparing``),
    /// and the settle check for the commands an unsettled operation would
    /// reject (``VMCapability/waitsForSettle``).
    func isAvailable(_ capability: VMCapability, on instance: VMInstance) -> Bool {
        guard capability.survivesPreparing || !instance.isPreparing else { return false }
        guard isApplicable(capability, to: instance) else { return false }
        return !(capability.waitsForSettle && library.isBusy(instance))
    }

    /// Whether a commit of `capability` is taken now — what a verb's own guard
    /// asks, and what a refusal names as accepted.
    ///
    /// Identical to ``isAvailable(_:on:)`` everywhere but rename.
    func accepts(_ capability: VMCapability, on instance: VMInstance) -> Bool {
        switch capability {
        case .rename:
            // Offering a rename and taking one are deliberately different
            // states. A rename rewrites the name and nothing a running
            // operation reads, so a name typed into a field editor that was
            // open when the VM started or began suspending is kept rather than
            // traded for an alert — only the revert that will assign a whole
            // configuration back over this one refuses
            // (``VMLifecyclePhase/renamePersists``).
            return !instance.isPreparing && instance.renamePersists
        case .info, .ipAddress, .snapshots, .start, .startInRecovery, .cancelGuestSetup, .stop,
            .restart, .forceStop, .discardSavedState, .pause, .resume, .suspend, .open,
            .takeSnapshot, .revertToSnapshot, .deleteSnapshot, .renameSnapshot, .setSnapshotNotes,
            .editStorageDisks, .editRemovableMedia, .clone, .delete, .cancelPreparing,
            .showInFinder, .togglePopOut, .toggleFullscreen, .showClipboard, .toggleGuestAgentDisk,
            .toggleSettingsPane:
            return isAvailable(capability, on: instance)
        }
    }
}
