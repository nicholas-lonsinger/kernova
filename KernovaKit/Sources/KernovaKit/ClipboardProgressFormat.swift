import Foundation

/// Display strings for the clipboard transfer readout.
public enum ClipboardProgressFormat {
    /// Headline naming the operation and the machine on the other end.
    ///
    /// `gesture` names what outbound bytes are for: under `.peerPaste` an app on
    /// the peer is blocked on them right now. Inbound reads the same for every
    /// gesture — a paste this side performs parks the thread that would repaint
    /// it, so one never shows a readout at all.
    ///
    /// The trailing ellipsis marks work still under way, matching the system's own
    /// "Copying…" progress titles — not the HIG's gathers-more-input ellipsis,
    /// which applies to commands.
    public static func headline(
        direction: ClipboardProgressSnapshot.Direction, peerName: String,
        gesture: ClipboardTransferGesture
    ) -> String {
        switch direction {
        case .inbound: return "Receiving from “\(peerName)”…"
        case .outbound:
            return gesture == .peerPaste
                ? "Pasting into “\(peerName)”…" : "Sending to “\(peerName)”…"
        }
    }

    /// Progress through the operation's files ("2 of 5" — a folder's file nodes
    /// count individually), or `nil` for a single-file transfer.
    public static func itemCounter(completed: Int, total: Int) -> String? {
        guard total > 1 else { return nil }
        // Counts the file currently streaming as the one in progress, so a
        // delivered count of 2 of 5 reads as "3 of 5".
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

    /// Bytes so far against the operation's total, with the current speed in
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
    /// operation actually finishes.
    public static func percent(fraction: Double) -> String {
        let clamped = min(1, max(0, fraction))
        return "\(Int(clamped * 100))%"
    }

    /// One-line summary for a status item's tooltip and the readout's
    /// accessibility value.
    public static func summary(_ snapshot: ClipboardProgressSnapshot) -> String {
        var parts = [
            headline(
                direction: snapshot.direction, peerName: snapshot.peerName,
                gesture: snapshot.gesture)
        ]
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

    /// Seconds as a log record spells them ("2.00 s"), or `unknown` where there
    /// is no estimate — never shown to a user, who gets `timeRemaining` instead.
    static func logSeconds(_ value: TimeInterval?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.2f s", value)
    }
}
