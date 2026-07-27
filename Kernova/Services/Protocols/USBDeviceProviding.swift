import Foundation

/// Abstraction for runtime USB device attach/detach operations.
@MainActor
protocol USBDeviceProviding: Sendable {
    /// Attaches a disk image as a USB mass storage device.
    ///
    /// `desiredUUID` overrides the auto-generated device UUID so the runtime
    /// device matches a persisted `RemovableMediaItem.id` for save-state restore
    /// matching; `nil` for ad-hoc attaches.
    func attach(
        diskImagePath: String,
        readOnly: Bool,
        desiredUUID: UUID?,
        to instance: VMInstance
    ) async throws -> USBDeviceInfo
    func detach(deviceInfo: USBDeviceInfo, from instance: VMInstance) async throws
}
