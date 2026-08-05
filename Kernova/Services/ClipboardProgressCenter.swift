import Foundation
import KernovaKit
import Observation
import os

/// App-level aggregate of every live clipboard service's transfer readout.
///
/// Clipboard services are per-VM, but the menu-bar status item renders one
/// readout, so each service pushes its snapshot here and this republishes the
/// most significant of them — a consumer never has to reason about individual
/// transfers or about which VM they belong to.
@MainActor
@Observable
final class ClipboardProgressCenter {
    /// The process-wide center every clipboard service publishes to by default.
    static let shared = ClipboardProgressCenter()

    private static let logger = Logger(
        subsystem: "app.kernova", category: "ClipboardProgressCenter")

    /// The clipboard operation currently worth showing across every live VM, or
    /// `nil` when none is.
    private(set) var materializationProgress: ClipboardProgressSnapshot?

    /// The latest snapshot from each live service, keyed by its identity.
    ///
    /// Per service rather than a single slot, because two VMs can transfer at once
    /// and the readout must not flicker between them; a service drops its entry as
    /// it stops so a gone VM can't pin the ring.
    @ObservationIgnored
    private var progressBySource: [ObjectIdentifier: ClipboardProgressSnapshot] = [:]

    /// Records a service's latest readout and republishes the most significant one
    /// across every live VM.
    ///
    /// A `nil` snapshot drops `source` from the aggregate.
    func progressChanged(from source: AnyObject, _ snapshot: ClipboardProgressSnapshot?) {
        let key = ObjectIdentifier(source)
        if let snapshot {
            progressBySource[key] = snapshot
        } else {
            progressBySource.removeValue(forKey: key)
        }
        materializationProgress = Self.mostSignificant(of: progressBySource)
        let sources = progressBySource.count
        guard let readout = materializationProgress else {
            Self.logger.debug("Aggregate readout cleared (\(sources, privacy: .public) source(s))")
            return
        }
        Self.logger.debug(
            "Aggregate readout ← '\(readout.peerName, privacy: .public)' \(readout.bytesTransferred, privacy: .public)/\(readout.totalBytes, privacy: .public) bytes (\(sources, privacy: .public) source(s))"
        )
    }

    /// The snapshot with the most bytes left to move, or `nil` when none is live.
    ///
    /// Ties break on the source's identity — arbitrary, but *stable*, which
    /// dictionary iteration order is not: two VMs whose readouts are level would
    /// otherwise swap the status item's headline between them.
    private static func mostSignificant(
        of snapshots: [ObjectIdentifier: ClipboardProgressSnapshot]
    ) -> ClipboardProgressSnapshot? {
        func remaining(_ snapshot: ClipboardProgressSnapshot) -> UInt64 {
            snapshot.totalBytes - min(snapshot.bytesTransferred, snapshot.totalBytes)
        }
        return snapshots.max { lhs, rhs in
            let lhsRemaining = remaining(lhs.value)
            let rhsRemaining = remaining(rhs.value)
            if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
            return lhs.key < rhs.key
        }?.value
    }
}
