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

    /// Formats an ETA from remaining bytes and current speed into a human-readable string.
    /// Returns `nil` if speed is negligible, the estimate exceeds 100 hours, or the result is non-finite.
    static func formatETA(remainingBytes: Int64, bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 1_000 else { return nil }
        let seconds = Double(remainingBytes) / bytesPerSecond
        guard seconds.isFinite, seconds > 0, seconds < 360_000 else { return nil }
        return formatDuration(seconds)
    }

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

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// Formats a duration in seconds into a human-readable string.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        durationFormatter.string(from: seconds) ?? "\(Int(seconds))s"
    }
}
