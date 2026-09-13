import Foundation
import os

/// Starts the accessory listener and keeps each guest's record of what it
/// holds honest as accessories come and go.
///
/// **Nothing is routed automatically.** macOS answered *whether* — the user
/// assigned the accessory to Kernova in Apple's *Virtual Machine Accessories*
/// menu extra — and *which VM* is the user's answer too, given in Kernova's
/// USB Device menu or `kernova usb attach`. An assignment is held until then,
/// however many guests are running, because an accessory that arrives on its
/// own is as likely to be the echo of a detach the user just asked for as it
/// is a device they want passed through.
///
/// The one thing that does happen on its own is reconciliation. Detaching a
/// passthrough device resets the device, so the stick comes back as a new
/// IORegistry node: an assignment carrying the identity of something a guest
/// is still recorded as holding is proof that guest no longer holds it.
@MainActor
final class USBAccessoryCoordinator {
    private static let logger = Logger(subsystem: "app.kernova", category: "USBAccessoryCoordinator")

    private let roster: any VMInstanceRoster

    init?(lifecycle: VMLifecycleCoordinator, roster: any VMInstanceRoster) {
        guard let service = lifecycle.usbAccessoryService else { return nil }
        self.roster = roster

        service.onAccessoryAssigned = { [weak self] info in
            self?.reconcile(info)
        }
        service.startObserving()
    }

    /// Drops any guest's record of an accessory that has just re-enumerated,
    /// and logs the one that arrived.
    ///
    /// The match is on the durable identity, never on `registryID`: the whole
    /// point is that the returning device carries a new one. A guest whose
    /// device really did go away has usually been told so by VZ already, and
    /// this is what covers the case where it was not.
    private func reconcile(_ info: USBAccessoryInfo) {
        if let identity = info.identity {
            for instance in roster.instances {
                guard let sessionID = instance.liveSessionID else { continue }
                for stale in instance.liveUSBAccessories
                where stale.accessory.identity == identity {
                    instance.forgetAttachedAccessory(deviceID: stale.deviceID, for: sessionID)
                    Self.logger.notice(
                        "Dropped '\(instance.name, privacy: .public)' record of USB accessory \(stale.accessory.displayName, privacy: .public): the host has it again"
                    )
                }
            }
        }
        Self.logger.notice(
            "Holding USB accessory \(info.displayName, privacy: .public) for a deliberate attach")
    }
}
