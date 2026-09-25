import Foundation
import KernovaKit

@testable import Kernova

/// Records presentation requests made by `VMLibraryViewModel` so tests can
/// assert which alert/sheet/wizard the view model asked for, without a real
/// window.
///
/// Exposes mirror accessors (`showError`, `instanceToDelete`, …) matching the
/// view model's former observed flags so existing assertions read naturally.
@MainActor
final class MockVMLibraryPresenting: VMLibraryPresenting {
    private(set) var errors: [String] = []
    /// Parallel to `errors`: the alert title each message was presented under.
    private(set) var errorTitles: [String] = []
    private(set) var startFailedAttachments: [StartFailedAttachment] = []
    private(set) var startFailedAttachmentInstances: [VMInstance] = []
    private(set) var deleteSheetInstances: [VMInstance] = []
    /// Parallel to `deleteSheetInstances`: whether each request asked for the
    /// immediate (bypass-Trash) variant.
    private(set) var deleteSheetPermanentlyFlags: [Bool] = []
    private(set) var takeSnapshotSheetInstances: [VMInstance] = []
    private(set) var revertSnapshots: [VMSnapshot] = []
    /// Parallel to `revertSnapshots`: the VM each request named.
    private(set) var revertSnapshotInstances: [VMInstance] = []
    private(set) var deleteSnapshots: [VMSnapshot] = []
    private(set) var deleteSnapshotInstances: [VMInstance] = []
    private(set) var forceStopInstances: [VMInstance] = []
    private(set) var recoveryBootInstances: [VMInstance] = []
    private(set) var stopPausedInstances: [VMInstance] = []
    private(set) var cancelPreparingArrivals: [VMArrival] = []
    private(set) var installerMountedNames: [String] = []
    private(set) var installerMountedPurposes: [GuestAgentInstallerPurpose] = []
    /// Parallel to `installerMountedNames`: how each request said the disk
    /// reaches the guest.
    private(set) var installerMountedDeliveries: [GuestAgentDiskDelivery] = []
    private(set) var creationWizardCount = 0
    /// Pairing prompts raised, each still unanswered until a test answers it.
    private(set) var usbPairingRequests: [USBAccessoryPairingRequest] = []
    /// Guest-account prompts raised, in order.
    private(set) var guestAccountPasswordRequests: [GuestAccountPasswordRequest] = []
    /// What this mock answers a guest-account prompt with, answered on the spot.
    ///
    /// The start that raises one suspends on the answer, so a recorded-and-left
    /// request would hang the call under test rather than fail it.
    var guestAccountPasswordAnswer: GuestAccountPasswordAnswer = .skip
    private(set) var focusGuestDisplayInstances: [VMInstance] = []

    func presentError(_ message: String, title: String) {
        errors.append(message)
        errorTitles.append(title)
    }
    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance) {
        startFailedAttachments.append(failure)
        startFailedAttachmentInstances.append(instance)
    }
    func presentDeleteSheet(for instance: VMInstance, permanently: Bool) {
        deleteSheetInstances.append(instance)
        deleteSheetPermanentlyFlags.append(permanently)
    }
    func presentTakeSnapshotSheet(for instance: VMInstance) {
        takeSnapshotSheetInstances.append(instance)
    }
    func presentRevertSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance) {
        revertSnapshots.append(snapshot)
        revertSnapshotInstances.append(instance)
    }
    func presentDeleteSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance) {
        deleteSnapshots.append(snapshot)
        deleteSnapshotInstances.append(instance)
    }
    func presentForceStop(for instance: VMInstance) { forceStopInstances.append(instance) }
    func presentRecoveryBoot(for instance: VMInstance) { recoveryBootInstances.append(instance) }
    func presentStopPaused(for instance: VMInstance) { stopPausedInstances.append(instance) }
    func presentCancelPreparing(for arrival: VMArrival) { cancelPreparingArrivals.append(arrival) }
    func presentInstallerMounted(
        vmName: String, purpose: GuestAgentInstallerPurpose, delivery: GuestAgentDiskDelivery
    ) {
        installerMountedNames.append(vmName)
        installerMountedPurposes.append(purpose)
        installerMountedDeliveries.append(delivery)
    }
    func presentUSBAccessoryPairing(_ request: USBAccessoryPairingRequest) {
        usbPairingRequests.append(request)
    }
    func presentGuestAccountPassword(_ request: GuestAccountPasswordRequest) {
        guestAccountPasswordRequests.append(request)
        request.answer(guestAccountPasswordAnswer)
    }
    func presentCreationWizard() { creationWizardCount += 1 }
    func focusGuestDisplay(for instance: VMInstance) {
        focusGuestDisplayInstances.append(instance)
    }

    // MARK: - Mirror accessors (read like the former VM flags)

    var showError: Bool { !errors.isEmpty }
    var errorMessage: String? { errors.last }
    var errorTitle: String? { errorTitles.last }
    var showDeleteSheet: Bool { !deleteSheetInstances.isEmpty }
    var instanceToDelete: VMInstance? { deleteSheetInstances.last }
    /// Whether the most recent delete-sheet request asked for immediate delete.
    var lastDeleteSheetPermanently: Bool? { deleteSheetPermanentlyFlags.last }
    var showForceStopConfirmation: Bool { !forceStopInstances.isEmpty }
    var instanceToForceStop: VMInstance? { forceStopInstances.last }
    var showRecoveryBootConfirmation: Bool { !recoveryBootInstances.isEmpty }
    var instanceToRecoveryBoot: VMInstance? { recoveryBootInstances.last }
    var showStopPausedConfirmation: Bool { !stopPausedInstances.isEmpty }
    var instanceToStopPaused: VMInstance? { stopPausedInstances.last }
    var showCancelPreparingConfirmation: Bool { !cancelPreparingArrivals.isEmpty }
    var arrivalToCancel: VMArrival? { cancelPreparingArrivals.last }
    var showInstallerMountedAlert: Bool { !installerMountedNames.isEmpty }
    var installerMountedVMName: String? { installerMountedNames.last }
    var installerMountedPurpose: GuestAgentInstallerPurpose? { installerMountedPurposes.last }
    var installerMountedDelivery: GuestAgentDiskDelivery? { installerMountedDeliveries.last }
    var showCreationWizard: Bool { creationWizardCount > 0 }
}
