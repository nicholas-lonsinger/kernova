import Foundation
import KernovaKit
import Observation

@testable import Kernova

/// Records presentation requests made by `VMLibraryViewModel` so tests can
/// assert which alert/sheet/wizard the view model asked for, without a real
/// window.
///
/// Exposes mirror accessors (`showError`, `instanceToDelete`, …) matching the
/// view model's former observed flags so existing assertions read naturally.
/// Observable, so a test waits on a presentation with `waitForChange`.
@MainActor
@Observable
final class MockVMLibraryPresenting: VMLibraryPresenting, LibraryWindowPresenting {
    private(set) var errors: [String] = []
    /// Parallel to `errors`: the alert title each message was presented under.
    private(set) var errorTitles: [String] = []
    /// Parallel to `errors`: what each alert was about.
    private(set) var errorSubjects: [AlertSubject] = []
    private(set) var startFailedAttachments: [StartFailedAttachment] = []
    private(set) var startFailedAttachmentInstances: [VMInstance] = []
    /// The VMs each start report named — an attachment failure, a message
    /// failure, or the launch account — in the order reported.
    private(set) var startReportVMIDs: [[UUID]] = []
    private(set) var deleteSheetInstances: [VMInstance] = []
    /// Parallel to `deleteSheetInstances`: whether each request asked for the
    /// immediate (bypass-Trash) variant.
    private(set) var deleteSheetPermanentlyFlags: [Bool] = []
    private(set) var takeSnapshotSheetInstances: [VMInstance] = []
    private(set) var takeSnapshotSheetPurposes: [TakeSnapshotPurpose] = []
    private(set) var revertSnapshots: [VMSnapshot] = []
    /// Parallel to `revertSnapshots`: the VM each request named.
    private(set) var revertSnapshotInstances: [VMInstance] = []
    private(set) var deleteSnapshots: [VMSnapshot] = []
    private(set) var deleteSnapshotInstances: [VMInstance] = []
    private(set) var forceStopInstances: [VMInstance] = []
    private(set) var recoveryBootInstances: [VMInstance] = []
    private(set) var pausedStopInstances: [VMInstance] = []
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
    var guestAccountPasswordAnswer: PresenterAnswer<GuestAccountPasswordAnswer> = .answered(.skip)
    private(set) var focusGuestDisplayInstances: [VMInstance] = []
    /// Confirmations a verb asked for, in order.
    private(set) var confirmationRequests: [ConfirmationRequest] = []
    /// What this mock answers a confirmation with, answered on the spot for the
    /// reason ``guestAccountPasswordAnswer`` is.
    var confirmationAnswer: PresenterAnswer<Bool> = .answered(false)
    /// Route questions a verb asked, in order.
    private(set) var stepRouteRequests: [StepRouteRequest] = []
    /// What this mock answers a route question with, answered on the spot for
    /// the reason ``guestAccountPasswordAnswer`` is; unasked by default, which
    /// leaves the refusal to the error path.
    var stepRouteAnswer: PresenterAnswer<StepRoute?> = .unasked
    /// The title of the route this mock chooses instead, when set — the routes
    /// a real refusal names are the core's to build.
    var choosesRouteTitled: String?

    func presentError(_ message: String, title: String, about subject: AlertSubject) {
        errors.append(message)
        errorTitles.append(title)
        errorSubjects.append(subject)
    }
    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance) {
        startFailedAttachments.append(failure)
        startFailedAttachmentInstances.append(instance)
        startReportVMIDs.append([instance.id])
    }
    /// Recorded as the error alert it is drawn as, and as a start report.
    func presentStartFailure(_ message: String, title: String, for instance: VMInstance) {
        presentError(message, title: title, about: .vm(instance))
        startReportVMIDs.append([instance.id])
    }
    /// Recorded as the error alert it is drawn as, and as a start report.
    func presentStartSummary(title: String, undone: [VMGroupActionResult]) {
        presentError(undone.undoneMessage(for: .start), title: title, about: .library)
        startReportVMIDs.append(undone.map(\.vm.id))
    }
    func presentDeleteSheet(for instance: VMInstance, permanently: Bool) {
        deleteSheetInstances.append(instance)
        deleteSheetPermanentlyFlags.append(permanently)
    }
    func presentTakeSnapshotSheet(for instance: VMInstance, purpose: TakeSnapshotPurpose) {
        takeSnapshotSheetInstances.append(instance)
        takeSnapshotSheetPurposes.append(purpose)
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
    func presentStopPaused(for instance: VMInstance) { pausedStopInstances.append(instance) }
    func presentCancelPreparing(for arrival: VMArrival) { cancelPreparingArrivals.append(arrival) }
    func presentInstallerMounted(
        for instance: VMInstance, purpose: GuestAgentInstallerPurpose,
        delivery: GuestAgentDiskDelivery
    ) {
        installerMountedNames.append(instance.name)
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
    func presentConfirmationRequest(_ request: ConfirmationRequest) {
        confirmationRequests.append(request)
        request.answer(confirmationAnswer)
    }
    func presentStepRoutes(_ request: StepRouteRequest) {
        stepRouteRequests.append(request)
        if let choosesRouteTitled {
            request.answer(.answered(request.requirement.routes.first { $0.title == choosesRouteTitled }))
        } else {
            request.answer(stepRouteAnswer)
        }
    }
    func presentCreationWizard() { creationWizardCount += 1 }
    func focusGuestDisplay(for instance: VMInstance) {
        focusGuestDisplayInstances.append(instance)
    }

    // MARK: - Mirror accessors (read like the former VM flags)

    var showError: Bool { !errors.isEmpty }
    var errorMessage: String? { errors.last }
    var errorTitle: String? { errorTitles.last }
    var errorSubject: AlertSubject? { errorSubjects.last }
    var showDeleteSheet: Bool { !deleteSheetInstances.isEmpty }
    var instanceToDelete: VMInstance? { deleteSheetInstances.last }
    /// Whether the most recent delete-sheet request asked for immediate delete.
    var lastDeleteSheetPermanently: Bool? { deleteSheetPermanentlyFlags.last }
    var showForceStopConfirmation: Bool { !forceStopInstances.isEmpty }
    var instanceToForceStop: VMInstance? { forceStopInstances.last }
    var showRecoveryBootConfirmation: Bool { !recoveryBootInstances.isEmpty }
    var instanceToRecoveryBoot: VMInstance? { recoveryBootInstances.last }
    var showStopPausedConfirmation: Bool { !pausedStopInstances.isEmpty }
    var instanceToStopPaused: VMInstance? { pausedStopInstances.last }
    var showCancelPreparingConfirmation: Bool { !cancelPreparingArrivals.isEmpty }
    var arrivalToCancel: VMArrival? { cancelPreparingArrivals.last }
    var showInstallerMountedAlert: Bool { !installerMountedNames.isEmpty }
    var installerMountedVMName: String? { installerMountedNames.last }
    var installerMountedPurpose: GuestAgentInstallerPurpose? { installerMountedPurposes.last }
    var installerMountedDelivery: GuestAgentDiskDelivery? { installerMountedDeliveries.last }
    var showCreationWizard: Bool { creationWizardCount > 0 }
}

extension AlertSubject {
    /// The VM this subject names, `nil` for the library.
    var vm: VMInstance? {
        if case .vm(let instance) = self { instance } else { nil }
    }

    var isLibrary: Bool {
        if case .library = self { true } else { false }
    }
}
