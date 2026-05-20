import Foundation

/// Persisted intent to install macOS into a VM that has not yet completed
/// its initial boot.
///
/// Stored on `VMConfiguration` and consulted by
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

    /// Where to write the downloaded IPSW (for `.downloadLatest`).
    ///
    /// A sibling `.kernovadownload` bundle at this location holds in-progress
    /// download state and enables resume across app restarts. Ignored when
    /// `source == .localFile`.
    var downloadDestinationPath: String?

    /// Path to an existing IPSW file on disk (for `.localFile`).
    ///
    /// Ignored when `source == .downloadLatest`.
    var localIPSWPath: String?

    /// `true` when the user confirmed "Download & Replace" in the wizard.
    ///
    /// Honored once by `VMLifecycleCoordinator.installMacOS`: the existing
    /// IPSW file and any `.kernovadownload` bundle are trashed, then this
    /// flag is cleared so subsequent retries (after a download succeeds and
    /// install fails) reuse the freshly-downloaded file rather than trashing
    /// it again.
    ///
    /// Optional in the persisted shape: contexts written before this field
    /// existed decode to `false`, matching the prior behavior.
    var requestedFreshDownload: Bool = false

    var downloadDestinationURL: URL? {
        downloadDestinationPath.map { URL(fileURLWithPath: $0) }
    }

    var localIPSWURL: URL? {
        localIPSWPath.map { URL(fileURLWithPath: $0) }
    }

    init(
        source: Source,
        downloadDestinationPath: String? = nil,
        localIPSWPath: String? = nil,
        requestedFreshDownload: Bool = false
    ) {
        self.source = source
        self.downloadDestinationPath = downloadDestinationPath
        self.localIPSWPath = localIPSWPath
        self.requestedFreshDownload = requestedFreshDownload
    }

    // Custom decoder so existing on-disk contexts (missing the new field)
    // decode cleanly with `requestedFreshDownload = false`.
    enum CodingKeys: String, CodingKey {
        case source
        case downloadDestinationPath
        case localIPSWPath
        case requestedFreshDownload
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decode(Source.self, forKey: .source)
        self.downloadDestinationPath = try c.decodeIfPresent(
            String.self, forKey: .downloadDestinationPath)
        self.localIPSWPath = try c.decodeIfPresent(String.self, forKey: .localIPSWPath)
        self.requestedFreshDownload =
            try c.decodeIfPresent(Bool.self, forKey: .requestedFreshDownload) ?? false
    }
}
