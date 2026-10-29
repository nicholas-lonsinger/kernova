import Foundation

/// Which saved states of one session's USB devices restore, by the model
/// docs/research/2026-10-28-vz-restore-needs-usb-ports-without-a-gap.md
/// fits to what VZ does: the devices a session starts with sit on ports 1
/// through n, each later attach takes the next port no device has had in the
/// session, and a state restores only when its devices fill the ports from 1
/// with no gap.
package struct USBPortLayout: Equatable, Sendable {
    private var ports: [UUID: Int] = [:]
    private var next = 1

    /// The layout of a session that starts with `devices` attached.
    package init(starting devices: [UUID]) {
        for device in devices { attached(device) }
    }

    /// Records `device` attached, on the next port.
    package mutating func attached(_ device: UUID) {
        ports[device] = next
        next += 1
    }

    /// The devices of `devices` above the first empty port, in port order:
    /// empty exactly when a state saved while `devices` alone are attached
    /// restores. A device this layout never saw attached sits nowhere it
    /// knows, so it counts as above.
    package func devicesAboveGap(_ devices: [UUID]) -> [UUID] {
        let placed = devices.compactMap { device in ports[device].map { (device, $0) } }.sorted { $0.1 < $1.1 }
        let unplaced = devices.filter { ports[$0] == nil }
        let gap = placed.enumerated().first { $0.element.1 != $0.offset + 1 }.map(\.offset) ?? placed.count
        return placed[gap...].map(\.0) + unplaced
    }
}
