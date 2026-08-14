import Foundation
import KernovaKit
import Observation
import os

/// App-level aggregate of every live clipboard service's transfer readout.
///
/// A source of transfer progress whose currently-shown operation the user can
/// stop.
///
/// Adopted by the services that publish to `ClipboardProgressCenter`, so a
/// Cancel on the one aggregated readout reaches the VM whose transfer it shows
/// rather than whichever service happens to be asked.
@MainActor
protocol TransferCancelling: AnyObject {
    /// Cancels the operation this source is currently publishing progress for.
    ///
    /// Idempotent, and a no-op once that operation has finished.
    func requestCancelOfShownOperation()
}

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

    /// One source's latest readout, alongside the source itself so a Cancel on
    /// the aggregate can reach it.
    ///
    /// The reference is weak: a service that goes away without clearing its entry
    /// would otherwise be kept alive by the aggregate, and a stopped VM's transfer
    /// has nothing left to cancel anyway.
    private struct Entry {
        let snapshot: ClipboardProgressSnapshot
        weak var source: AnyObject?
    }

    /// The latest snapshot from each live service, keyed by its identity.
    ///
    /// Per service rather than a single slot, because two VMs can transfer at once
    /// and the readout must not flicker between them; a service drops its entry as
    /// it stops so a gone VM can't pin the ring.
    @ObservationIgnored
    private var progressBySource: [ObjectIdentifier: Entry] = [:]

    /// The source of the snapshot `materializationProgress` currently holds, so a
    /// Cancel routes to the VM whose transfer is on screen.
    @ObservationIgnored
    private var publishedSource: ObjectIdentifier?

    /// Records a service's latest readout and republishes the most significant one
    /// across every live VM.
    ///
    /// A `nil` snapshot drops `source` from the aggregate.
    func progressChanged(from source: AnyObject, _ snapshot: ClipboardProgressSnapshot?) {
        let key = ObjectIdentifier(source)
        if let snapshot {
            progressBySource[key] = Entry(snapshot: snapshot, source: source)
        } else {
            progressBySource.removeValue(forKey: key)
        }
        let winner = Self.mostSignificant(of: progressBySource)
        publishedSource = winner?.key
        materializationProgress = winner?.entry.snapshot
        let sources = progressBySource.count
        guard let readout = materializationProgress else {
            Self.logger.debug("Aggregate readout cleared (\(sources, privacy: .public) source(s))")
            return
        }
        Self.logger.debug(
            "Aggregate readout ← '\(readout.peerName, privacy: .public)' \(readout.bytesTransferred, privacy: .public)/\(readout.totalBytes, privacy: .public) bytes (\(sources, privacy: .public) source(s))"
        )
    }

    /// Cancels the operation behind the readout currently on screen.
    ///
    /// Routed to the publishing source rather than broadcast: another VM's
    /// transfer is running under its own readout, and stopping it would cancel
    /// something the user cannot even see.
    func cancelCurrent() {
        guard let key = publishedSource,
            let source = progressBySource[key]?.source as? any TransferCancelling
        else {
            Self.logger.debug("Cancel requested with no cancellable source publishing")
            return
        }
        source.requestCancelOfShownOperation()
    }

    /// The snapshot with the most bytes left to move, or `nil` when none is live.
    ///
    /// Ties break on the source's identity — arbitrary, but *stable*, which
    /// dictionary iteration order is not: two VMs whose readouts are level would
    /// otherwise swap the status item's headline between them.
    private static func mostSignificant(
        of entries: [ObjectIdentifier: Entry]
    ) -> (key: ObjectIdentifier, entry: Entry)? {
        func remaining(_ snapshot: ClipboardProgressSnapshot) -> UInt64 {
            snapshot.totalBytes - min(snapshot.bytesTransferred, snapshot.totalBytes)
        }
        return entries.max { lhs, rhs in
            let lhsRemaining = remaining(lhs.value.snapshot)
            let rhsRemaining = remaining(rhs.value.snapshot)
            if lhsRemaining != rhsRemaining { return lhsRemaining < rhsRemaining }
            return lhs.key < rhs.key
        }.map { (key: $0.key, entry: $0.value) }
    }
}
