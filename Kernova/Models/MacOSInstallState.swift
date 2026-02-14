import Foundation

/// Represents the current phase of a macOS installation.
enum MacOSInstallPhase: Sendable {
    case downloading(progress: Double, bytesWritten: Int64, totalBytes: Int64)
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
