import Foundation

/// Snapshot of download progress reported by the IPSW download delegate.
struct DownloadProgress: Sendable {
    let fraction: Double
    let bytesWritten: Int64
    let totalBytes: Int64
    let bytesPerSecond: Double
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
    /// The current active phase.
    var currentPhase: MacOSInstallPhase
    /// Whether the download phase has completed.
    var downloadCompleted: Bool = false
}
