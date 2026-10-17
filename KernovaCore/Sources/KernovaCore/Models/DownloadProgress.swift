import Foundation

/// Snapshot of a download's progress, delivered to a progress handler.
package struct DownloadProgress: Sendable, Equatable {
    package let bytesWritten: Int64
    package let totalBytes: Int64
    /// EWMA-smoothed download speed; zero before the first progress report.
    package let bytesPerSecond: Double

    package var fraction: Double {
        totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
    }

    static let zero = DownloadProgress(bytesWritten: 0, totalBytes: 0, bytesPerSecond: 0)
}
