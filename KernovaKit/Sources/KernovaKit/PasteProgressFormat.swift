import Foundation

/// Display strings for the paste materialization readout (#643).
///
/// Shared by the host app and the guest agent so both directions word the same
/// transfer identically, and free of AppKit so the wording is unit-testable
/// without a status item — the same pure-mapper convention as
/// `ClipboardFileProviderReminder` and `AgentMenuText`.
public enum PasteProgressFormat {
    /// Headline naming where the bytes are coming from — the VM's name on the
    /// host, "Mac" in the guest.
    ///
    /// Trailing ellipsis because it describes work still under way, the same as
    /// the system's own "Copying…" progress titles. (Not the HIG's
    /// gathers-more-input ellipsis, which applies to commands.)
    public static func headline(sourceName: String) -> String {
        "Pasting from “\(sourceName)”…"
    }

    /// Progress through the paste's files ("2 of 5" — a folder's file nodes
    /// count individually), or `nil` for a single-file paste, where the file's
    /// own name already says everything a counter would.
    public static func itemCounter(completed: Int, total: Int) -> String? {
        guard total > 1 else { return nil }
        // A count that has been delivered but not yet incremented past the file
        // currently streaming reads better as "3 of 5" than "2 of 5" — the user
        // counts the file on screen as the one in progress.
        let position = min(completed + 1, total)
        return "\(position) of \(total)"
    }

    /// Throughput ("1.2 GB/s"), or `nil` before an estimate exists.
    public static func speed(bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: Int(bytesPerSecond.rounded())), countStyle: .file)
        return "\(bytes)/s"
    }

    /// Bytes so far against the paste's total, with the current speed in
    /// parentheses ("47.6 MB of 3.03 GB (7.8 MB/s)") — Safari's download-list
    /// phrasing.
    ///
    /// Drops the parenthetical before a speed estimate exists.
    public static func byteProgress(
        bytesTransferred: UInt64, totalBytes: UInt64, bytesPerSecond: Double?
    ) -> String {
        let transferred = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytesTransferred), countStyle: .file)
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: totalBytes), countStyle: .file)
        var line = "\(transferred) of \(total)"
        if let speed = speed(bytesPerSecond: bytesPerSecond) {
            line += " (\(speed))"
        }
        return line
    }

    /// Time remaining in Safari's download phrasing ("6 minutes, 27 seconds
    /// remaining"), or `nil` when it can't be estimated.
    ///
    /// Under an hour the seconds are always spelled out — the ticking figure is
    /// what makes the countdown read as live. Above an hour the seconds would be
    /// noise, so the line coarsens to hours and minutes.
    public static func timeRemaining(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        func unit(_ count: Int, _ name: String) -> String {
            "\(count) \(name)\(count == 1 ? "" : "s")"
        }
        let total = max(1, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        var parts: [String] = []
        if hours > 0 {
            parts.append(unit(hours, "hour"))
            if minutes > 0 { parts.append(unit(minutes, "minute")) }
        } else if minutes > 0 {
            parts.append(unit(minutes, "minute"))
            parts.append(unit(total % 60, "second"))
        } else {
            parts.append(unit(total, "second"))
        }
        return parts.joined(separator: ", ") + " remaining"
    }

    /// Percent complete ("42%"), floored so it never reads 100 % before the
    /// paste actually finishes.
    public static func percent(fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        return "\(Int(clamped * 100))%"
    }

    /// One-line summary for the status item's tooltip and the readout's
    /// accessibility value.
    public static func summary(_ snapshot: PasteMaterializationSnapshot) -> String {
        var parts = [headline(sourceName: snapshot.sourceName)]
        parts.append(percent(fraction: snapshot.fractionComplete))
        if let counter = itemCounter(
            completed: snapshot.filesCompleted, total: snapshot.fileCount)
        {
            parts.append(counter)
        } else if let name = snapshot.currentItemName {
            parts.append(name)
        }
        return parts.joined(separator: " — ")
    }
}
