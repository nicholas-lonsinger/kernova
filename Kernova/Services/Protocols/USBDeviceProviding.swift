import Foundation

/// Abstraction for runtime USB device attach/detach operations.
@MainActor
protocol USBDeviceProviding: Sendable {
    func attach(diskImagePath: String, readOnly: Bool, to instance: VMInstance) async throws -> USBDeviceInfo
    func detach(deviceInfo: USBDeviceInfo, from instance: VMInstance) async throws
}
