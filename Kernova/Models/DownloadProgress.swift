import Foundation

/// Snapshot of a download's progress, delivered to a progress handler.
struct DownloadProgress: Sendable, Equatable {
    let bytesWritten: Int64
    let totalBytes: Int64
    /// EWMA-smoothed download speed; zero before the first progress report.
    let bytesPerSecond: Double

    var fraction: Double {
        totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
    }

    static let zero = DownloadProgress(bytesWritten: 0, totalBytes: 0, bytesPerSecond: 0)
}
