import Foundation

/// Metadata for a USB mass storage device attached at runtime via XHCI.
///
/// This is a runtime-only type — not persisted to disk. USB devices are
/// transient and detach automatically when the VM stops.
struct USBDeviceInfo: Identifiable, Sendable, Equatable {
    let id: UUID
    let path: String
    let readOnly: Bool
    let attachedAt: Date

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    init(id: UUID = UUID(), path: String, readOnly: Bool, attachedAt: Date = Date()) {
        self.id = id
        self.path = path
        self.readOnly = readOnly
        self.attachedAt = attachedAt
    }
}
