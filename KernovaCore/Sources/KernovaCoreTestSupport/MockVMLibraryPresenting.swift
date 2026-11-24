import Foundation
import KernovaCommandModel
import Observation

@testable import KernovaCore

/// Records presentation requests made by `VMLibraryViewModel` so tests can
/// assert which alert/sheet/wizard the view model asked for, without a real
/// window.
///
/// Exposes mirror accessors (`showError`, `instanceToForceStop`, …) matching the
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
    /// Parallel to `errors`: where each alert's Open Settings button leads,
    /// `nil` for an alert offering none.
    private(set) var errorSettingsDestinations: [SettingsDestination?] = []
    private(set) var startFailedAttachments: [StartFailedAttachment] = []
    private(set) var revertSnapshots: [VMSnapshot] = []
    private(set) var deleteSnapshots: [VMSnapshot] = []
    private(set) var forceStopInstances: [VMInstance] = []
    /// Confirmations a verb asked for, in order.
    private(set) var confirmationRequests: [ConfirmationRequest] = []
    /// What this mock answers a confirmation with, answered on the spot.
    ///
    /// The verb that raises one suspends on the answer, so a recorded-and-left
    /// request would hang the call under test rather than fail it.
    var confirmationAnswer: PresenterAnswer<ConfirmationAnswer> = .answered(.decline)

    func presentError(_ message: String, title: String, about subject: AlertSubject) {
        record(message, title: title, about: subject, openingSettingsAt: nil)
    }
    func presentError(
        _ message: String, title: String, about subject: AlertSubject,
        openingSettingsAt destination: SettingsDestination
    ) {
        record(message, title: title, about: subject, openingSettingsAt: destination)
    }
    private func record(
        _ message: String, title: String, about subject: AlertSubject,
        openingSettingsAt destination: SettingsDestination?
    ) {
        errors.append(message)
        errorTitles.append(title)
        errorSubjects.append(subject)
        errorSettingsDestinations.append(destination)
    }
    func presentStartFailedAttachment(_ failure: StartFailedAttachment, for instance: VMInstance) {
        startFailedAttachments.append(failure)
    }
    /// Recorded as the error alert it is drawn as.
    func presentStartFailure(_ message: String, title: String, for instance: VMInstance) {
        presentError(message, title: title, about: .vm(instance))
    }
    /// Recorded as the error alert it is drawn as.
    func presentStartSummary(title: String, undone: [VMGroupActionResult]) {
        presentError(undone.undoneMessage(for: .start, in: .app), title: title, about: .library)
    }
    func presentDeleteSheet(for instance: VMInstance, permanently: Bool) {}
    func presentTakeSnapshotSheet(for instance: VMInstance, purpose: TakeSnapshotPurpose) {}
    func presentRevertSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance) {
        revertSnapshots.append(snapshot)
    }
    func presentDeleteSnapshot(_ snapshot: VMSnapshot, for instance: VMInstance) {
        deleteSnapshots.append(snapshot)
    }
    func presentForceStop(for instance: VMInstance) { forceStopInstances.append(instance) }
    func presentRecoveryBoot(for instance: VMInstance) {}
    func presentStopPaused(for instance: VMInstance) {}
    func presentCancelPreparing(for arrival: VMArrival) {}
    func presentInstallerMounted(
        for instance: VMInstance, purpose: GuestAgentInstallerPurpose,
        delivery: GuestAgentDiskDelivery
    ) {}
    func presentLinuxAgentInstallChoice(for instance: VMInstance, initial: LinuxAgentInstallChoice) {}
    func presentUSBAccessoryPairing(_ request: USBAccessoryPairingRequest) {}
    /// Skips the account, answered on the spot for the reason
    /// ``confirmationAnswer`` is.
    func presentGuestAccountPassword(_ request: GuestAccountPasswordRequest) {
        request.answer(.answered(.skip))
    }
    func presentConfirmationRequest(_ request: ConfirmationRequest) {
        confirmationRequests.append(request)
        request.answer(confirmationAnswer)
    }
    /// Unasked, which leaves the refusal to the error path.
    func presentStepRoutes(_ request: StepRouteRequest) {
        request.answer(.unasked)
    }
    func presentCreationWizard() {}
    func focusGuestDisplay(for instance: VMInstance) {}

    // MARK: - Mirror accessors (read like the former VM flags)

    var showError: Bool { !errors.isEmpty }
    var errorMessage: String? { errors.last }
    var errorTitle: String? { errorTitles.last }
    var errorSubject: AlertSubject? { errorSubjects.last }
    var errorSettingsDestination: SettingsDestination? { errorSettingsDestinations.last ?? nil }
    var showForceStopConfirmation: Bool { !forceStopInstances.isEmpty }
    var instanceToForceStop: VMInstance? { forceStopInstances.last }
}

extension AlertSubject {
    /// The VM this subject names, `nil` for the library.
    var vm: VMInstance? {
        switch self {
        case .vm(let instance), .session(let instance, _): instance
        case .library: nil
        }
    }

    var isLibrary: Bool {
        if case .library = self { true } else { false }
    }
}
