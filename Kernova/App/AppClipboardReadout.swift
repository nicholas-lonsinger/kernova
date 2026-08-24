import Foundation
import KernovaKit

/// The one clipboard readout the app-level surfaces render across every VM, and
/// the routing behind the Cancel it carries.
///
/// Computed from the instances rather than kept in a registry: the report is a
/// per-VM value, so nothing has to be registered or unregistered as services
/// come and go (docs/CLIPBOARD.md §13).
@MainActor
enum AppClipboardReadout {
    /// The report the single app-level bar shows for `instances`: the
    /// top-ranked running transfer, else the most recent finished report that
    /// still has a bar to dwell on, else nothing.
    static func report(for instances: [VMInstance]) -> ClipboardTransferReport {
        if let top = topRunning(in: instances) {
            return .running(top.snapshot, since: top.since)
        }
        return dwelling(in: instances) ?? .idle
    }

    /// Stops the operation the readout on screen was rendered for, returning
    /// whether a VM claimed it.
    ///
    /// The identity comes off that readout, so the click reaches it through
    /// whichever VM owns it — never whatever happens to be newest by the time
    /// it lands.
    static func cancel(_ id: ClipboardTransferOperationID, in instances: [VMInstance]) -> Bool {
        for instance in instances where instance.clipboardTransfers.cancel(id) { return true }
        return false
    }

    /// The running readout the single bar shows, across every VM.
    ///
    /// Ranked the way each VM's own reporter ranks its operations — the gesture
    /// someone is waiting on first, then recency — so one VM's drop cannot take
    /// the bar off another's blocked paste.
    private static func topRunning(in instances: [VMInstance]) -> (
        snapshot: ClipboardProgressSnapshot, since: Date
    )? {
        instances
            .compactMap { instance -> (snapshot: ClipboardProgressSnapshot, since: Date)? in
                guard case .running(let snapshot, let since) = instance.clipboardTransferReport
                else { return nil }
                return (snapshot, since)
            }
            .max {
                ($0.snapshot.gesture.readoutRank, $0.since)
                    < ($1.snapshot.gesture.readoutRank, $1.since)
            }
    }

    /// The finished report still worth leaving a bar up for, or `nil`.
    ///
    /// A refusal has no bar — its surfaces are the notice popover and the
    /// dropdown's per-VM line.
    private static func dwelling(in instances: [VMInstance]) -> ClipboardTransferReport? {
        instances
            .compactMap { instance -> ClipboardTransferFinish? in
                guard case .finished(let finish) = instance.clipboardTransferReport,
                    finish.finalSnapshot != nil
                else { return nil }
                return finish
            }
            .max { $0.date < $1.date }
            .map { .finished($0) }
    }
}
