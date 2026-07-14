import Foundation

/// Formatting utilities for display values.
enum DataFormatters {
    private nonisolated(unsafe) static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// Formats a byte count into a human-readable string (e.g., "4.2 GB").
    static func formatBytes(_ bytes: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(bytes))
    }

    /// Formats a byte count with fixed width for stable progress display (e.g., "861.900 MB").
    ///
    /// Uses `%7.3f` padding so the numeric part is always 7 characters wide, preventing
    /// horizontal jitter as values change during downloads.
    static func formatBytesFixedWidth(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000
        let tb = gb / 1_000

        let (value, unit): (Double, String)
        if tb >= 1 {
            (value, unit) = (tb, "TB")
        } else if gb >= 1 {
            (value, unit) = (gb, "GB")
        } else if mb >= 1 {
            (value, unit) = (mb, "MB")
        } else {
            (value, unit) = (kb, "KB")
        }
        return String(format: "%7.3f %@", value, unit)
            .replacingOccurrences(of: " ", with: "\u{2007}")
    }

    /// Formats a download speed in bytes/second into a human-readable string (e.g., "42.5 MB/s").
    ///
    /// Uses fixed-width formatting to prevent horizontal jitter during rapid updates.
    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1_000
        let mb = kb / 1_000
        let gb = mb / 1_000

        let (value, unit): (Double, String)
        if gb >= 1 {
            (value, unit) = (gb, "GB/s")
        } else if mb >= 1 {
            (value, unit) = (mb, "MB/s")
        } else {
            (value, unit) = (kb, "KB/s")
        }
        return String(format: "%5.1f %@", value, unit)
            .replacingOccurrences(of: " ", with: "\u{2007}")
    }

    /// Formats an ETA from remaining bytes and current speed into a fixed-width
    /// `H:MM:SS` clock (e.g. `"\u{2007}0:04:33"`, `"12:33:22"`).
    ///
    /// The hour field is one or two characters left-padded with a figure space
    /// (U+2007), and every other slot is a digit or a colon, so the rendered
    /// width is constant under a monospaced-digit font regardless of the value —
    /// the ETA never shifts the surrounding line as it crosses unit boundaries.
    /// Use ``etaUnknownPlaceholder`` for the same-width dash rendering when this
    /// returns `nil` but an ETA slot still needs to be shown.
    ///
    /// Returns `nil` if speed is negligible, the estimate exceeds 100 hours, or
    /// the result is non-finite.
    static func formatETA(remainingBytes: Int64, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 1_000 else { return nil }
        let seconds = Double(remainingBytes) / bytesPerSecond
        guard seconds.isFinite, seconds > 0, seconds < 360_000 else { return nil }
        // The < 360_000 guard bounds this below 100h; clamp so a value rounding
        // up at the boundary can't spill into a three-digit hour field.
        let total = min(Int(seconds.rounded()), 359_999)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        let paddedHours = String(format: "%2d", hours)
            .replacingOccurrences(of: " ", with: "\u{2007}")
        return "\(paddedHours):\(String(format: "%02d", minutes)):\(String(format: "%02d", secs))"
    }

    /// A same-width stand-in for an ETA (`"\u{2007}\u{2012}:\u{2012}\u{2012}:\u{2012}\u{2012}"`),
    /// shown while a speed is displayed but ``formatETA`` returns `nil`.
    ///
    /// Uses figure dashes (U+2012), which render at the same advance as a digit
    /// under the monospaced-digit font, so line 2 keeps a constant width whether
    /// or not an ETA estimate is currently available.
    static let etaUnknownPlaceholder = "\u{2007}\u{2012}:\u{2012}\u{2012}:\u{2012}\u{2012}"

    /// Formats a disk size in GB for display, using TB for sizes >= 1000 GB.
    ///
    /// The numeric part is right-justified to 3 characters using figure spaces
    /// (U+2007) so entries align in menus and pickers.
    ///
    /// Examples: `10` → `"\u{2007}10 GB"`, `100` → `"100 GB"`, `1500` → `"1.5 TB"`.
    static func formatDiskSize(_ sizeInGB: Int) -> String {
        let formatted: String
        if sizeInGB >= 1000 {
            let tb = Double(sizeInGB) / 1000
            formatted = String(format: "%3.1f TB", tb)
        } else {
            formatted = String(format: "%3d GB", sizeInGB)
        }
        return formatted.replacingOccurrences(of: " ", with: "\u{2007}")
    }

    /// Formats a CPU count for display.
    static func formatCPUCount(_ count: Int) -> String {
        count == 1 ? "1 core" : "\(count) cores"
    }

    /// Quotes each item with typographic double quotes and joins them with the
    /// locale's list conjunction.
    ///
    /// English: "A", "A and B", "A, B, and C" with the Oxford comma. Used to
    /// name the VMs that share a file in the delete confirmations.
    static func quotedList(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items.map { "\u{201C}\($0)\u{201D}" })
    }
}
