import Foundation

/// Persisted intent to fetch a Linux installer image for a VM that has not yet
/// completed its initial boot.
struct LinuxInstallContext: Codable, Sendable, Equatable {
    /// The catalog entry as it read when the user picked it.
    ///
    /// Embedded rather than referenced by id: the bundled catalog is rewritten
    /// whenever the mirrors move, and a VM whose download is still pending must
    /// keep fetching the distribution the user chose.
    var entry: LinuxImageCatalogEntry

    /// Where to write the downloaded ISO, `nil` until a resolution names the
    /// file.
    ///
    /// A sibling `.kernovadownload` bundle at this location holds in-progress
    /// download state and enables resume across app restarts.
    var downloadDestinationPath: String?

    /// `true` when the user confirmed replacing the image already at the
    /// destination.
    ///
    /// Honored once: the existing ISO and any `.kernovadownload` bundle are
    /// trashed, then the flag is cleared so a retry after a failed attempt
    /// reuses the freshly-downloaded file rather than trashing it again.
    var requestedFreshDownload: Bool = false

    var downloadDestinationURL: URL? {
        downloadDestinationPath.map { URL(fileURLWithPath: $0) }
    }

    init(
        entry: LinuxImageCatalogEntry,
        downloadDestinationPath: String? = nil,
        requestedFreshDownload: Bool = false
    ) {
        self.entry = entry
        self.downloadDestinationPath = downloadDestinationPath
        self.requestedFreshDownload = requestedFreshDownload
    }
}
