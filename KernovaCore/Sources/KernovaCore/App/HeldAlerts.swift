import Foundation

/// The alerts waiting with no window the user can see to show them on — what
/// the status item reports.
@MainActor
@Observable
package final class HeldAlerts {
    /// One held alert, as the status item counts it.
    package enum Alert: Equatable {
        /// A report of VMs that did not start, naming them.
        case startReport(vmIDs: [UUID])
        /// Any other alert, about the VM `vmID` names or about no VM.
        case other(vmID: UUID?)
    }

    private(set) var alerts: [Alert] = []

    package init() {}

    /// Replaces what is held, leaving observers unwoken when nothing changed.
    package func update(_ alerts: [Alert]) {
        guard alerts != self.alerts else { return }
        self.alerts = alerts
    }

    /// How many VMs the held start reports name, counting only those
    /// `isListed` — the ones a report would still name when shown.
    package func undoneStartCount(listing isListed: (UUID) -> Bool) -> Int {
        alerts.reduce(0) { count, alert in
            guard case .startReport(let ids) = alert else { return count }
            return count + ids.count(where: isListed)
        }
    }

    /// How many held alerts are not start reports, counting one about a VM
    /// only while `isListed` holds for it — one about a VM that left the
    /// library is dropped when it would be shown.
    package func otherAlertCount(listing isListed: (UUID) -> Bool) -> Int {
        alerts.count { alert in
            guard case .other(let vmID) = alert else { return false }
            return vmID.map(isListed) ?? true
        }
    }
}
