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

    /// Progress through the paste's top-level items ("2 of 5 items"), or `nil`
    /// for a single-item paste, where the file's own name already says
    /// everything a counter would.
    public static func itemCounter(completed: Int, total: Int) -> String? {
        guard total > 1 else { return nil }
        // A count that has been delivered but not yet incremented past the item
        // currently streaming reads better as "3 of 5" than "2 of 5" — the user
        // counts the file on screen as the one in progress.
        let position = min(completed + 1, total)
        return "\(position) of \(total) items"
    }

    /// Throughput ("1.2 GB/s"), or `nil` before an estimate exists.
    public static func speed(bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: Int(bytesPerSecond.rounded())), countStyle: .file)
        return "\(bytes)/s"
    }

    /// Time remaining in the system's own coarse phrasing, or `nil` when it
    /// can't be estimated.
    ///
    /// Deliberately vague: a chunked transfer's instantaneous rate is noisy
    /// enough that a precise-looking figure would be a lie, and a countdown that
    /// jitters between "38 seconds" and "2 minutes" reads as broken. Coarse
    /// buckets change far less often, so the estimate stays believable.
    public static func timeRemaining(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        if seconds < 10 { return "A few seconds remaining" }
        if seconds < 60 { return "About \(Int(seconds.rounded())) seconds remaining" }
        if seconds < 90 { return "About a minute remaining" }
        if seconds < 3600 {
            return "About \(Int((seconds / 60).rounded())) minutes remaining"
        }
        let hours = Int((seconds / 3600).rounded())
        return hours <= 1 ? "About an hour remaining" : "About \(hours) hours remaining"
    }

    /// Percent complete ("42%"), floored so it never reads 100 % before the
    /// paste actually finishes.
    public static func percent(fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        return "\(Int(clamped * 100))%"
    }

    /// Speed and time remaining as one line, dropping whichever half isn't
    /// available yet ("1.2 GB/s · About 30 seconds remaining").
    ///
    /// Returns `nil` before either half exists, so the caller can leave the row
    /// empty rather than render a bare separator.
    public static func detail(bytesPerSecond: Double?, secondsRemaining: Double?) -> String? {
        let parts = [speed(bytesPerSecond: bytesPerSecond), timeRemaining(seconds: secondsRemaining)]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One-line summary for the status item's tooltip and the readout's
    /// accessibility value.
    public static func summary(_ snapshot: PasteMaterializationSnapshot) -> String {
        var parts = [headline(sourceName: snapshot.sourceName)]
        parts.append(percent(fraction: snapshot.fractionComplete))
        if let counter = itemCounter(
            completed: snapshot.itemsCompleted, total: snapshot.itemCount)
        {
            parts.append(counter)
        } else if let name = snapshot.currentItemName {
            parts.append(name)
        }
        return parts.joined(separator: " — ")
    }
}
