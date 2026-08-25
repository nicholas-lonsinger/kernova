import Foundation

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
    private(set) var cancelPreparingInstances: [VMInstance] = []
    private(set) var installerMountedNames: [String] = []
    private(set) var installerMountedPurposes: [GuestAgentInstallerPurpose] = []
    /// Parallel to `installerMountedNames`: how each request said the disk
    /// reaches the guest.
    private(set) var installerMountedDeliveries: [GuestAgentDiskDelivery] = []
    private(set) var creationWizardCount = 0
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
    func presentCancelPreparing(for instance: VMInstance) { cancelPreparingInstances.append(instance) }
    func presentInstallerMounted(
        vmName: String, purpose: GuestAgentInstallerPurpose, delivery: GuestAgentDiskDelivery
    ) {
        installerMountedNames.append(vmName)
        installerMountedPurposes.append(purpose)
        installerMountedDeliveries.append(delivery)
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
    var showCancelPreparingConfirmation: Bool { !cancelPreparingInstances.isEmpty }
    var preparingInstanceToCancel: VMInstance? { cancelPreparingInstances.last }
    var showInstallerMountedAlert: Bool { !installerMountedNames.isEmpty }
    var installerMountedVMName: String? { installerMountedNames.last }
    var installerMountedPurpose: GuestAgentInstallerPurpose? { installerMountedPurposes.last }
    var installerMountedDelivery: GuestAgentDiskDelivery? { installerMountedDeliveries.last }
    var showCreationWizard: Bool { creationWizardCount > 0 }

    /// Clears all recorded requests (mirrors resetting the former flags).
    func reset() {
        errors.removeAll()
        errorTitles.removeAll()
        startFailedAttachments.removeAll()
        startFailedAttachmentInstances.removeAll()
        deleteSheetInstances.removeAll()
        deleteSheetPermanentlyFlags.removeAll()
        takeSnapshotSheetInstances.removeAll()
        revertSnapshots.removeAll()
        revertSnapshotInstances.removeAll()
        deleteSnapshots.removeAll()
        deleteSnapshotInstances.removeAll()
        forceStopInstances.removeAll()
        recoveryBootInstances.removeAll()
        stopPausedInstances.removeAll()
        cancelPreparingInstances.removeAll()
        installerMountedNames.removeAll()
        installerMountedPurposes.removeAll()
        installerMountedDeliveries.removeAll()
        creationWizardCount = 0
        focusGuestDisplayInstances.removeAll()
    }
}
