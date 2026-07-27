import Foundation

/// Snapshot of download progress reported by the IPSW download delegate.
struct DownloadProgress: Sendable {
    let bytesWritten: Int64
    let totalBytes: Int64
    /// EWMA-smoothed download speed; zero before the first progress report.
    let bytesPerSecond: Double

    var fraction: Double {
        totalBytes > 0 ? Double(bytesWritten) / Double(totalBytes) : 0
    }

    static let zero = DownloadProgress(bytesWritten: 0, totalBytes: 0, bytesPerSecond: 0)
}

/// Represents the current phase of a macOS installation.
enum MacOSInstallPhase: Sendable {
    case downloading(DownloadProgress)
    case installing(progress: Double)
}

/// Tracks the full state of a multi-step macOS installation.
struct MacOSInstallState: Sendable {
    /// Whether the install includes a download step (false for local IPSW).
    let hasDownloadStep: Bool
    var currentPhase: MacOSInstallPhase
    var downloadCompleted: Bool = false
}
