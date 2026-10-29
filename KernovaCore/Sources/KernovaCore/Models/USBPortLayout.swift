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

    /// Whether a state saved while exactly `devices` are attached restores:
    /// their ports are 1 through their count. A device this layout never saw
    /// attached sits nowhere it knows, so it does not.
    package func restores(_ devices: [UUID]) -> Bool {
        let held = devices.compactMap { ports[$0] }
        guard held.count == devices.count else { return false }
        return Set(held) == Set(held.indices.map { $0 + 1 })
    }
}
