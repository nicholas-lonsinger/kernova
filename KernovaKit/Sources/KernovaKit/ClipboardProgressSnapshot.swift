import Foundation

/// One clipboard operation's aggregate transfer progress — the single value every
/// Kernova progress surface renders.
///
/// **Aggregate per operation, never per file.** `bytesTransferred`/`totalBytes`
/// span every transfer the operation makes, sequential or concurrent, so a bar
/// built from this climbs once instead of refilling per file.
public struct ClipboardProgressSnapshot: Equatable, Sendable {
    /// Which way the bytes are moving, from the rendering side's point of view.
    public enum Direction: Equatable, Sendable {
        /// Arriving here — a paste materializing, a preview fetch, a Copy to Mac.
        case inbound
        /// Leaving here — serving a peer's pull of content this side offered.
        case outbound
    }

    /// Which way the bytes are moving.
    public let direction: Direction
    /// Display name of the machine on the other end — the VM's name on the host,
    /// "Mac" in the guest.
    public let peerName: String
    /// What is currently streaming — a flat file by its own name, a folder's
    /// children by the *folder's* name (concurrent children would flicker through
    /// sibling filenames) — or `nil` when nothing is in flight.
    public let currentItemName: String?
    /// Files fully transferred so far.
    public let filesCompleted: Int
    /// Files the operation expects to transfer.
    public let fileCount: Int
    /// Bytes moved across the whole operation.
    public let bytesTransferred: UInt64
    /// Bytes the whole operation expects to move.
    public let totalBytes: UInt64
    /// Recent throughput, or `nil` before enough samples to estimate one.
    public let bytesPerSecond: Double?
    /// Estimated seconds until the operation finishes, or `nil` when it can't be
    /// estimated (no rate yet, or nothing left to move).
    public let secondsRemaining: Double?
    /// The user action this operation serves, which decides its headline and
    /// whether its readout may open a status-item dropdown by itself.
    public let gesture: ClipboardTransferGesture
    /// How long this operation has been running.
    public let elapsedSeconds: TimeInterval
    /// Whether the user can stop this operation — what puts a Cancel affordance
    /// on the readout. A surface must not offer one otherwise: the transfers
    /// behind an operation with nothing to cancel would keep running.
    public let isCancellable: Bool
    /// Which operation this readout measures, so a Cancel on it stops that one
    /// and not whichever transfer happens to be newest when the click lands.
    public let operationID: ClipboardTransferOperationID
    /// How many further operations for this peer are live behind this readout —
    /// waiting their turn, or running where only one can be shown.
    ///
    /// Filled in by the reporter, which is the only thing that sees them all.
    public let pendingBehind: Int

    /// Creates a snapshot of one clipboard operation in flight.
    public init(
        direction: Direction, peerName: String, currentItemName: String?, filesCompleted: Int,
        fileCount: Int, bytesTransferred: UInt64, totalBytes: UInt64, bytesPerSecond: Double?,
        secondsRemaining: Double?, gesture: ClipboardTransferGesture,
        elapsedSeconds: TimeInterval, isCancellable: Bool = false,
        operationID: ClipboardTransferOperationID = .unattached,
        pendingBehind: Int = 0
    ) {
        self.direction = direction
        self.peerName = peerName
        self.currentItemName = currentItemName
        self.filesCompleted = filesCompleted
        self.fileCount = fileCount
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = secondsRemaining
        self.gesture = gesture
        self.elapsedSeconds = elapsedSeconds
        self.isCancellable = isCancellable
        self.operationID = operationID
        self.pendingBehind = pendingBehind
    }

    /// Progress as a `0...1` fraction, clamped (a zero/unknown total reads as 0).
    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }

    /// The same readout with ``pendingBehind`` set, for the reporter to stamp
    /// what the operation itself cannot see.
    public func withPendingBehind(_ count: Int) -> ClipboardProgressSnapshot {
        guard count != pendingBehind else { return self }
        return ClipboardProgressSnapshot(
            direction: direction, peerName: peerName, currentItemName: currentItemName,
            filesCompleted: filesCompleted, fileCount: fileCount,
            bytesTransferred: bytesTransferred, totalBytes: totalBytes,
            bytesPerSecond: bytesPerSecond, secondsRemaining: secondsRemaining, gesture: gesture,
            elapsedSeconds: elapsedSeconds, isCancellable: isCancellable, operationID: operationID,
            pendingBehind: count)
    }
}
