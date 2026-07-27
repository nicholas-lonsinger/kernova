import Foundation

/// Persisted intent to install macOS into a VM that has not yet completed
/// its initial boot.
///
/// Consulted by `VMLifecycleCoordinator.installMacOS(on:context:)` on every
/// Start while non-nil.
struct MacOSInstallContext: Codable, Sendable, Equatable {
    enum Source: String, Codable, Sendable, Equatable {
        case downloadLatest
        case localFile
    }

    var source: Source

    /// Where to write the downloaded IPSW (for `.downloadLatest`).
    ///
    /// A sibling `.kernovadownload` bundle at this location holds in-progress
    /// download state and enables resume across app restarts.
    var downloadDestinationPath: String?

    /// Path to an existing IPSW file on disk (for `.localFile`).
    var localIPSWPath: String?

    /// App-scoped security bookmark for `localIPSWPath`, minted from the
    /// user's open-panel grant so the file stays readable on every Start
    /// until the install succeeds.
    ///
    /// `nil` when bookmark creation failed — the install then falls back to the
    /// raw path. `downloadDestinationPath` needs none: the destination is always
    /// the Downloads folder, covered by the downloads entitlement.
    var localIPSWBookmark: Data?

    /// `true` when the user confirmed "Download & Replace" in the wizard.
    ///
    /// Honored once: the existing IPSW file and any `.kernovadownload` bundle
    /// are trashed, then the flag is cleared so a retry after a failed install
    /// reuses the freshly-downloaded file rather than trashing it again.
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
        localIPSWBookmark: Data? = nil,
        requestedFreshDownload: Bool = false
    ) {
        self.source = source
        self.downloadDestinationPath = downloadDestinationPath
        self.localIPSWPath = localIPSWPath
        self.localIPSWBookmark = localIPSWBookmark
        self.requestedFreshDownload = requestedFreshDownload
    }

    // Custom decoder so a context missing these keys decodes with
    // `requestedFreshDownload = false` and a nil bookmark rather than failing.
    enum CodingKeys: String, CodingKey {
        case source
        case downloadDestinationPath
        case localIPSWPath
        case localIPSWBookmark
        case requestedFreshDownload
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.source = try c.decode(Source.self, forKey: .source)
        self.downloadDestinationPath = try c.decodeIfPresent(
            String.self, forKey: .downloadDestinationPath)
        self.localIPSWPath = try c.decodeIfPresent(String.self, forKey: .localIPSWPath)
        self.localIPSWBookmark = try c.decodeIfPresent(Data.self, forKey: .localIPSWBookmark)
        self.requestedFreshDownload =
            try c.decodeIfPresent(Bool.self, forKey: .requestedFreshDownload) ?? false
    }
}
