import Foundation

/// One paste's aggregate File Provider materialization progress (#643).
///
/// Rendered by the status item on the side where the bytes land — the host app
/// for a guest→host paste, the guest agent for a host→guest one — because the
/// only OS-side surface, Finder's copy dialog, has never been observed rendering
/// determinate progress for a third-party provider (docs/CLIPBOARD.md §13).
///
/// **One snapshot per paste, not per pull.** `bytesTransferred`/`totalBytes`
/// aggregate every file the paste materializes, whether the pulls run
/// sequentially (a flat multi-file paste) or concurrently (a folder's children),
/// so the readout is identical in both shapes. `itemsCompleted`/`itemCount`
/// count *top-level* entries — the files and folders the user copied — while
/// `currentItemName` names the individual file streaming right now, which for a
/// folder is one of its descendants.
public struct PasteMaterializationSnapshot: Equatable, Sendable {
    /// Display name of the machine the bytes are coming from — the VM's name on
    /// the host, "Mac" in the guest.
    public let sourceName: String
    /// The file currently streaming (a folder's descendant shows its own name),
    /// or `nil` when nothing is in flight between two items.
    public let currentItemName: String?
    /// Top-level items fully materialized so far.
    public let itemsCompleted: Int
    /// Top-level items in the paste (flat files + folder roots).
    public let itemCount: Int
    /// Bytes materialized across the whole paste.
    public let bytesTransferred: UInt64
    /// Bytes the whole paste will materialize, from the published manifest.
    public let totalBytes: UInt64
    /// Recent throughput, or `nil` before enough samples to estimate one.
    public let bytesPerSecond: Double?
    /// Estimated seconds until the paste finishes, or `nil` when it can't be
    /// estimated (no rate yet, or a zero-byte paste).
    public let secondsRemaining: Double?

    /// Creates a snapshot of a paste in flight.
    public init(
        sourceName: String, currentItemName: String?, itemsCompleted: Int, itemCount: Int,
        bytesTransferred: UInt64, totalBytes: UInt64, bytesPerSecond: Double?,
        secondsRemaining: Double?
    ) {
        self.sourceName = sourceName
        self.currentItemName = currentItemName
        self.itemsCompleted = itemsCompleted
        self.itemCount = itemCount
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = secondsRemaining
    }

    /// Progress as a `0...1` fraction, clamped (a zero/unknown total reads as 0).
    public var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }
}
