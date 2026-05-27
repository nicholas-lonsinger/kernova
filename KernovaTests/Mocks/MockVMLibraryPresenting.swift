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
    private(set) var deleteConfirmationInstances: [VMInstance] = []
    private(set) var deleteSheetInstances: [VMInstance] = []
    private(set) var forceStopInstances: [VMInstance] = []
    private(set) var stopPausedInstances: [VMInstance] = []
    private(set) var cancelPreparingInstances: [VMInstance] = []
    private(set) var installerMountedNames: [String] = []
    private(set) var creationWizardCount = 0

    func presentError(_ message: String) { errors.append(message) }
    func presentDeleteConfirmation(for instance: VMInstance) { deleteConfirmationInstances.append(instance) }
    func presentDeleteSheet(for instance: VMInstance) { deleteSheetInstances.append(instance) }
    func presentForceStop(for instance: VMInstance) { forceStopInstances.append(instance) }
    func presentStopPaused(for instance: VMInstance) { stopPausedInstances.append(instance) }
    func presentCancelPreparing(for instance: VMInstance) { cancelPreparingInstances.append(instance) }
    func presentInstallerMounted(vmName: String) { installerMountedNames.append(vmName) }
    func presentCreationWizard() { creationWizardCount += 1 }

    // MARK: - Mirror accessors (read like the former VM flags)

    var showError: Bool { !errors.isEmpty }
    var errorMessage: String? { errors.last }
    var showDeleteConfirmation: Bool { !deleteConfirmationInstances.isEmpty }
    var showDeleteSheet: Bool { !deleteSheetInstances.isEmpty }
    var instanceToDelete: VMInstance? { deleteConfirmationInstances.last ?? deleteSheetInstances.last }
    var showForceStopConfirmation: Bool { !forceStopInstances.isEmpty }
    var instanceToForceStop: VMInstance? { forceStopInstances.last }
    var showStopPausedConfirmation: Bool { !stopPausedInstances.isEmpty }
    var instanceToStopPaused: VMInstance? { stopPausedInstances.last }
    var showCancelPreparingConfirmation: Bool { !cancelPreparingInstances.isEmpty }
    var preparingInstanceToCancel: VMInstance? { cancelPreparingInstances.last }
    var showInstallerMountedAlert: Bool { !installerMountedNames.isEmpty }
    var installerMountedVMName: String? { installerMountedNames.last }
    var showCreationWizard: Bool { creationWizardCount > 0 }

    /// Clears all recorded requests (mirrors resetting the former flags).
    func reset() {
        errors.removeAll()
        deleteConfirmationInstances.removeAll()
        deleteSheetInstances.removeAll()
        forceStopInstances.removeAll()
        stopPausedInstances.removeAll()
        cancelPreparingInstances.removeAll()
        installerMountedNames.removeAll()
        creationWizardCount = 0
    }
}
