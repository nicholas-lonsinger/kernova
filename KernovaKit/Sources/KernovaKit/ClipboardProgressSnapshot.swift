import Foundation

/// One clipboard operation's aggregate transfer progress — the single value every
/// Kernova progress surface renders (#643, #652).
///
/// **Aggregate per operation, never per file.** `bytesTransferred`/`totalBytes`
/// span every transfer the operation makes, whether they run sequentially (Finder
/// walking a flat multi-file paste) or concurrently (a folder's children), so a
/// bar built from this climbs once instead of refilling per file.
/// `filesCompleted`/`fileCount` count individual *files* — flat reps and a
/// folder's file nodes alike — while `currentItemName` names what is streaming
/// right now (a folder's children stream under the folder's own name).
///
/// Rendered on the side where the bytes land or leave: the host app's clipboard
/// window bar, its toolbar button's under-bar, and both status items' rings and
/// dropdown readouts.
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
    /// sibling filenames) — or `nil` when nothing is in flight between two files.
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
    /// Whether this is a File Provider paste — a manifest-backed materialization
    /// the user started with ⌘V on this machine.
    ///
    /// The only operation allowed to open a status-item dropdown by itself: it is
    /// the one with no surface of its own, since the window that would have shown
    /// a bar is Finder's, not ours. Every other flow starts from the clipboard
    /// window, which is already rendering this same snapshot.
    public let isPasteSession: Bool
    /// How long this operation has been running, for gates that need a floor the
    /// 300 ms reveal is far too short to provide (the dropdown auto-open).
    public let elapsedSeconds: TimeInterval

    /// Creates a snapshot of one clipboard operation in flight.
    public init(
        direction: Direction, peerName: String, currentItemName: String?, filesCompleted: Int,
        fileCount: Int, bytesTransferred: UInt64, totalBytes: UInt64, bytesPerSecond: Double?,
        secondsRemaining: Double?, isPasteSession: Bool, elapsedSeconds: TimeInterval
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
        self.isPasteSession = isPasteSession
        self.elapsedSeconds = elapsedSeconds
    }

    /// Progress as a `0...1` fraction, clamped (a zero/unknown total reads as 0).
    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }
}
