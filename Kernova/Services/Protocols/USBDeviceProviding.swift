import Foundation

/// Abstraction for runtime USB device attach/detach operations.
@MainActor
protocol USBDeviceProviding: Sendable {
    /// Attaches a disk image as a USB mass storage device.
    ///
    /// `desiredUUID` overrides the auto-generated `VZUSBDeviceConfiguration.uuid`
    /// so the runtime device's identity matches a persisted value (e.g.
    /// `VMConfiguration.discImageDeviceUUID`). Pass `nil` for callers that
    /// don't care (e.g. the guest agent installer).
    func attach(
        diskImagePath: String,
        readOnly: Bool,
        desiredUUID: UUID?,
        to instance: VMInstance
    ) async throws -> USBDeviceInfo
    func detach(deviceInfo: USBDeviceInfo, from instance: VMInstance) async throws
}
