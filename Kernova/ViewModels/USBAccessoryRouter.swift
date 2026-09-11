import Foundation
import os

/// Decides which guest a newly assigned USB accessory goes to.
///
/// macOS already answered *whether* — the user assigned the accessory to
/// Kernova in Apple's *Virtual Machine Accessories* menu extra, and this
/// process is handed only what they assigned. All that is left is *which VM*,
/// and the answer is deliberately narrow: one obvious candidate is taken, and
/// anything else is held for the user to place.
///
/// Nothing here is remembered. An accessory's `registryID` is an IORegistry ID
/// that a replug reassigns, and identical dongles share a VID:PID, so any
/// remembered mapping would eventually route hardware into the wrong guest —
/// and macOS already owns the layer that remembers.
@MainActor
final class USBAccessoryRouter {
    private static let logger = Logger(subsystem: "app.kernova", category: "USBAccessoryRouter")

    private let lifecycle: VMLifecycleCoordinator
    private let roster: any VMInstanceRoster

    init?(lifecycle: VMLifecycleCoordinator, roster: any VMInstanceRoster) {
        guard let service = lifecycle.usbAccessoryService else { return nil }
        self.lifecycle = lifecycle
        self.roster = roster

        service.onAccessoryAssigned = { [weak self] info in
            self?.route(info)
        }
        service.onAccessoryWithdrawn = { [weak self] registryID in
            self?.forget(registryID)
        }
        service.startObserving()
    }

    /// Drops every guest's record of the accessory `registryID` names.
    ///
    /// macOS can take an assignment back without VZ reporting anything — a
    /// fast user switch withdraws them all — so this is what keeps a VM's
    /// attachment list from outliving the accessory behind it.
    private func forget(_ registryID: UInt64) {
        for instance in roster.instances {
            guard let sessionID = instance.liveSessionID else { continue }
            for attached in instance.liveUSBAccessories
            where attached.accessory.registryID == registryID {
                instance.forgetAttachedAccessory(deviceID: attached.deviceID, for: sessionID)
                Self.logger.notice(
                    "Dropped withdrawn USB accessory \(attached.accessory.displayName, privacy: .public) from '\(instance.name, privacy: .public)'"
                )
            }
        }
    }

    /// The VMs an accessory could be attached to right now.
    private var candidates: [VMInstance] {
        roster.instances.filter { instance in
            instance.attachableSessionID != nil && instance.session?.hasUSBController == true
        }
    }

    /// Attaches `info` when exactly one guest could take it, and otherwise
    /// leaves it available for the user to place.
    private func route(_ info: USBAccessoryInfo) {
        let candidates = candidates
        guard candidates.count == 1, let instance = candidates.first,
            let sessionID = instance.attachableSessionID
        else {
            Self.logger.notice(
                "Holding USB accessory \(info.displayName, privacy: .public): \(candidates.count) running VM(s) could take it"
            )
            return
        }

        Task {
            do {
                try await lifecycle.attachUSBAccessory(
                    info.registryID, to: instance, for: sessionID)
            } catch {
                Self.logger.error(
                    "Could not attach USB accessory \(info.displayName, privacy: .public) to '\(instance.name, privacy: .public)': \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}
