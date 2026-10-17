import Foundation
import KernovaKit

/// Why the guest-agent installer disk was attached, so the post-mount alert can
/// point the user at the right next step.
package enum GuestAgentInstallerPurpose: Equatable {
    /// The agent is absent or behind the bundled version — a fresh install,
    /// update, or reinstall. The user runs `install.command`.
    case install
    /// The agent is already installed (`.current`) or present-but-unresponsive
    /// — the user re-mounted the disk to reinstall *or* run `uninstall.command`.
    case manage
}

/// What a snapshot taken from the Take Snapshot sheet is for.
package enum TakeSnapshotPurpose: Equatable, Sendable {
    /// A restore point and nothing more.
    case restorePoint
    /// Turning Ephemeral Mode on for a VM with no snapshot: the capture becomes
    /// its baseline.
    case ephemeralBaseline
}

/// A bring-up that failed because one attachment — a storage disk, a
/// removable medium, or a shared folder — couldn't be used, where removing
/// that entry (detach only — the file or folder is untouched) is a valid way to
/// get the VM running again.
///
/// Never built for a bundle-internal storage disk: no verb re-creates an
/// internal entry — ``VMCommandCore/attachStorageDisks(_:paths:)`` adds external
/// paths and ``VMCommandCore/createStorageDisk(_:sizeInGB:)`` writes a new file
/// under a new identity — so removing one cannot be undone, whatever the user
/// does with the file afterwards.
package struct StartFailedAttachment: Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        case storageDisk
        case removableMedia
        case sharedDirectory
    }

    /// What was wrong with the attachment, for the sentences the alert adds
    /// about getting it working again.
    ///
    /// The file-system reasons are what `PathValidation` could see rather than
    /// what is actually wrong, so none names a cause: ``notFound`` comes from a
    /// `fileExists` miss, which a deleted item and an unmounted volume reach
    /// alike, and ``notWritable`` and ``notReadable`` from `FileManager`'s
    /// `isWritableFile(atPath:)` and `isReadableFile(atPath:)`, each equally
    /// false for a permission the item lacks, a read-only volume or a locked
    /// item (writing), and an access the sandbox denies. Copy about any of them
    /// names a condition the user can check instead.
    package enum Reason: Equatable, Sendable {
        case notFound
        /// A disk image's path names a folder.
        case pathIsDirectory
        /// A shared folder's path names something other than a folder.
        case notADirectory
        /// A shared folder the VM cannot read.
        case notReadable
        case notWritable
        /// The file is there and `VZDiskImageStorageDeviceAttachment` refused
        /// it; its own description carries what little is known.
        case attachRefused
    }

    /// The bring-up the user asked for — ``VMVerb/start`` or ``VMVerb/resume``
    /// — which is what the alert heads itself with. The recovery itself always
    /// ends in a start: it discards the saved state a resume would have
    /// restored.
    package let verb: VMVerb
    package let kind: Kind
    package let reason: Reason
    /// The failing item's ID in the VM's configuration, so the removal targets
    /// exactly the entry that failed even if the list changed since.
    let id: UUID
    package let label: String
    /// The builder error's own description — what was found, and where.
    package let message: String
}

/// What the user decided about the account their macOS guest still owes a
/// password.
///
/// The two answers a verb takes, plus the one only a sheet has: walking away.
/// Cancelling is not a third thing to tell the core — it is the absence of a
/// re-issued start.
package enum GuestAccountPasswordAnswer: Equatable, CustomStringConvertible {
    /// Create the account, with this password.
    case password(String)
    /// Create no account, leaving macOS to ask for one in Setup Assistant.
    case skip
    /// Don't start at all.
    case cancelled

    /// Redacts the password, so interpolating an answer into a log line or a
    /// debugger dump cannot spill it.
    package var description: String {
        switch self {
        case .password: "password(<redacted>)"
        case .skip: "skip"
        case .cancelled: "cancelled"
        }
    }
}

/// How a question the view model puts to the presenter comes back.
package enum PresenterAnswer<Answer> {
    /// The user answered.
    case answered(Answer)
    /// The question was never answered — there was nowhere to show it, or the
    /// window it was shown in went away — so the refusal that raised it stands.
    case unasked
}

extension PresenterAnswer: Equatable where Answer: Equatable {}
extension PresenterAnswer: Sendable where Answer: Sendable {}

/// The one thing a macOS guest still needs to create the account its VM was set
/// up with: the password no bundle carries.
///
/// The answer writes nothing itself — the door hands it to the verb that holds
/// it, and starts again.
package struct GuestAccountPasswordRequest {
    /// What the core is asking about: the VM, the account, and the words.
    package let prompt: GuestAccountPrompt
    /// Answers the prompt: a password, a boot without the account, or no start.
    package let answer: @MainActor (PresenterAnswer<GuestAccountPasswordAnswer>) -> Void
}

/// What an alert is about.
package enum AlertSubject {
    /// One VM.
    case vm(VMInstance)
    /// The library as a whole — an arrival, a bundle on disk, or several VMs.
    case library
}

/// A confirmation a verb the user started refused without, put to the user
/// while that verb waits for the answer.
package struct ConfirmationRequest {
    /// The VM the verb that raised the prompt acts on.
    package let instance: VMInstance
    /// What the core is asking, in its own words.
    package let prompt: ConfirmationPrompt
    /// Answers the prompt: `true` to go ahead, `false` to walk away.
    package let answer: @MainActor (PresenterAnswer<Bool>) -> Void
}

/// The routes a refusal a verb the user started raised names, put to the
/// user while that verb waits for the answer.
package struct StepRouteRequest {
    /// The VM the verb that raised the refusal acts on.
    package let instance: VMInstance
    /// What the core refused with, in its own words.
    package let requirement: StepRequirement
    /// The verb a route ending in ``StepRoute/Ending/refusedVerb`` asks
    /// again, as its button names it after the route's title; `nil` names the
    /// route alone. A route ending in a start names the start.
    package let verbTitle: String?
    /// Answers the request: the route chosen, or `nil` to walk away.
    package let answer: @MainActor (PresenterAnswer<StepRoute?>) -> Void
}

/// The alerts and sheets the view model raises, each shown on the window the
/// user is working in for what it is about.
///
/// A request with nowhere to show yet waits; a question a suspended verb
/// waits on is answered unasked instead, as each method says.
@MainActor
package protocol VMLibraryPresenting: AnyObject {
    /// Show an error alert about `subject`, headed `title` with `message` —
    /// as one about no VM when `subject` names a VM the library no longer
    /// lists, such as the one a delete just removed.
    func presentError(_ message: String, title: String, about subject: AlertSubject)
    /// Show the start-failed alert for an attachment that couldn't be opened,
    /// offering to remove it from the configuration and start again.
    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance)
    /// Show a start of `instance` that failed with only a message to give.
    func presentStartFailure(_ message: String, title: String, for instance: VMInstance)
    /// Show the launch pass's one account of the `undone` VMs it did not start.
    /// A VM that leaves the library before the account is shown drops out of
    /// it.
    func presentStartSummary(title: String, undone: [VMGroupActionResult])
    /// Show the unified delete sheet: the VM's in-bundle disks plus any external
    /// files, each individually selectable for deletion. `permanently` selects
    /// the immediate (bypass-Trash) variant.
    func presentDeleteSheet(for instance: VMInstance, permanently: Bool)
    /// Show the sheet that names and annotates a new snapshot taken for
    /// `purpose`.
    func presentTakeSnapshotSheet(for instance: VMInstance, purpose: TakeSnapshotPurpose)
    /// Show the revert confirmation for one snapshot.
    func presentRevertSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance)
    /// Show the delete confirmation for one snapshot.
    func presentDeleteSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance)
    /// Show the force-stop / discard-saved-state confirmation.
    func presentForceStop(for instance: VMInstance)
    /// Show the confirmation for booting a macOS guest into macOS Recovery.
    func presentRecoveryBoot(for instance: VMInstance)
    /// Show the stop-paused confirmation (resume-and-shut-down vs. force stop).
    func presentStopPaused(for instance: VMInstance)
    /// Show the cancel-preparing (create/clone/import) confirmation.
    func presentCancelPreparing(for arrival: VMArrival)
    /// Show the "guest agent disk attached, here are the next steps" alert
    /// about `instance`, worded for `purpose` (install vs. install-or-uninstall)
    /// and for how `delivery` put the disk in front of the guest.
    func presentInstallerMounted(
        for instance: VMInstance, purpose: GuestAgentInstallerPurpose,
        delivery: GuestAgentDiskDelivery)
    /// Ask which running guest a newly assigned USB accessory should be passed
    /// through to.
    ///
    /// The request's `answer` is called exactly once — with `nil` when there is
    /// no window to ask in, which leaves the accessory with the host and the
    /// USB Device menu as where it is placed.
    func presentUSBAccessoryPairing(_ request: USBAccessoryPairingRequest)
    /// Ask for the password a macOS guest still needs to create the account its
    /// VM was set up with.
    ///
    /// The request's `answer` is called exactly once — the start that raised it
    /// is suspended until it arrives — with ``PresenterAnswer/unasked`` when
    /// there is nowhere to ask right now.
    func presentGuestAccountPassword(_ request: GuestAccountPasswordRequest)
    /// Ask the user to confirm what a verb they started refused without.
    ///
    /// The request's `answer` is called exactly once — the verb that raised it
    /// is suspended until it arrives — with ``PresenterAnswer/unasked`` when
    /// there is nowhere to ask right now.
    func presentConfirmationRequest(_ request: ConfirmationRequest)
    /// Ask the user which route through a refusal a verb they started raised
    /// to take.
    ///
    /// The request's `answer` is called exactly once — the verb that raised it
    /// is suspended until it arrives — with ``PresenterAnswer/unasked`` when
    /// there is nowhere to ask right now.
    func presentStepRoutes(_ request: StepRouteRequest)
}

/// What the library window does for the view model beyond alerts: the
/// creation wizard and its inline guest display.
@MainActor
package protocol LibraryWindowPresenting: AnyObject {
    /// Present the VM creation wizard sheet.
    func presentCreationWizard()
    /// Move keyboard focus into `instance`'s inline guest display, called at
    /// the moment a user action routes the display there (start, resume, pop
    /// in). If the display is not up yet, the request holds until it appears —
    /// but expires the instant focus moves anywhere else, so it never steals
    /// focus later.
    func focusGuestDisplay(for instance: VMInstance)
}
