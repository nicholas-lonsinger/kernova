import Foundation
import KernovaCommandModel

/// The devices Kernova's own policy gave a VM at its last cold boot, which a
/// restore of any state saved since then builds again.
///
/// A saved state restores only into the device set it was saved with
/// (`docs/research/2026-09-30-vz-restore-matches-machine-shape-and-device-set.md`).
/// A shape recorded before a device field existed decodes that field as
/// absent — off — because the release that recorded it never built the device.
package struct VMDeviceShape: Codable, Sendable, Equatable {
    /// Whether the VM has a virtio socket device.
    package var virtioSocketDevice: Bool

    /// The shape a cold boot gives every VM.
    package static let current = VMDeviceShape(virtioSocketDevice: true)

    /// The shape a configuration with no record states: the devices every
    /// build before the record gave a VM booting through `bootMode`, which
    /// put a socket device on a macOS guest alone.
    package static func unrecorded(bootMode: VMBootMode) -> VMDeviceShape {
        VMDeviceShape(virtioSocketDevice: bootMode == .macOS)
    }

    package init(virtioSocketDevice: Bool) {
        self.virtioSocketDevice = virtioSocketDevice
    }

    package init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.virtioSocketDevice = try c.decode(
            Bool.self, forKey: .virtioSocketDevice, absentMeans: false, in: decoder)
    }
}
