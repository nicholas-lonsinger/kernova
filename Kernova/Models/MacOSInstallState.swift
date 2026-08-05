import Foundation

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
