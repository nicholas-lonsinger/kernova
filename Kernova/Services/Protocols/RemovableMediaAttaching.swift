import Foundation

/// Abstraction for runtime removable-media attach/detach operations.
@MainActor
protocol RemovableMediaAttaching: Sendable {
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
    ) async throws -> RemovableMediaDeviceInfo
    func detach(deviceInfo: RemovableMediaDeviceInfo, from instance: VMInstance) async throws
}
