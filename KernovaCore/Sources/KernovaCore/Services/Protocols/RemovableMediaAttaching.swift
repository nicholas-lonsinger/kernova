import Foundation

/// Abstraction for runtime removable-media attach/detach operations.
@MainActor
package protocol RemovableMediaAttaching: Sendable {
    /// Attaches a disk image as a USB mass storage device.
    ///
    /// `diskImagePath` is the device's identity, what the returned info and
    /// every log of it name; `file`, when supplied, is what is actually
    /// attached (a bookmark's resolution, a VM's installer-disk copy).
    ///
    /// `desiredUUID` overrides the auto-generated device UUID so the runtime
    /// device matches a persisted `RemovableMediaItem.id` for save-state restore
    /// matching; `nil` for ad-hoc attaches.
    func attach(
        diskImagePath: String,
        attaching file: URL?,
        readOnly: Bool,
        desiredUUID: UUID?,
        to instance: VMInstance
    ) async throws -> RemovableMediaDeviceInfo
    func detach(deviceInfo: RemovableMediaDeviceInfo, from instance: VMInstance) async throws
}

// MARK: - Errors

enum RemovableMediaDeviceError: LocalizedError {
    case noVirtualMachine
    case noUSBController
    case diskImageNotFound(String)
    case diskImageIsDirectory(String)
    case diskImageNotWritable(String)
    case deviceNotFound

    var errorDescription: String? {
        switch self {
        case .noVirtualMachine:
            "No virtual machine is running."
        case .noUSBController:
            "No USB controller is available. Restart the VM to enable USB device support."
        case .diskImageNotFound(let path):
            "Disk image not found at \(path)."
        case .diskImageIsDirectory(let path):
            "Path is a directory, not a file: \(path)."
        case .diskImageNotWritable(let path):
            "Disk image is not writable: \(path). Try attaching as read-only."
        case .deviceNotFound:
            "The USB device could not be found on the controller."
        }
    }
}
