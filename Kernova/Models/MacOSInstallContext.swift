import Foundation

/// Persisted intent to install macOS into a VM that has not yet completed
/// its initial boot. Stored on `VMConfiguration` and consulted by
/// `VMLifecycleCoordinator.installMacOS(on:context:)` on every Start while
/// non-nil. Cleared exactly once, after a successful install.
///
/// The wizard's `IPSWSource` enum is a runtime-only type; this mirrored
/// `Codable` representation keeps the model layer free of wizard knowledge
/// while surviving bundle persistence.
struct MacOSInstallContext: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable, Equatable {
        case downloadLatest
        case localFile
    }

    var source: Source

    /// Where to write the downloaded IPSW (for `.downloadLatest`). The
    /// `<path>.resumedata` sidecar at this location enables download resume
    /// across app restarts. Ignored when `source == .localFile`.
    var downloadDestinationPath: String?

    /// Path to an existing IPSW file on disk (for `.localFile`). Ignored
    /// when `source == .downloadLatest`.
    var localIPSWPath: String?

    var downloadDestinationURL: URL? {
        downloadDestinationPath.map { URL(fileURLWithPath: $0) }
    }

    var localIPSWURL: URL? {
        localIPSWPath.map { URL(fileURLWithPath: $0) }
    }
}
