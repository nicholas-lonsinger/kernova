import Foundation

/// Persisted intent to fetch a Linux installer image for a VM that has not yet
/// completed its initial boot.
///
/// Consulted by `VMLifecycleCoordinator.downloadLinuxImage(on:context:)` on
/// every Start while non-nil.
struct LinuxInstallContext: Codable, Sendable, Equatable {
    /// Where the installer image comes from, together with what that source
    /// needs to fetch it.
    enum Source: Sendable, Equatable {
        /// A distribution from the bundled catalog, embedded rather than
        /// referenced by id: the catalog is rewritten whenever the mirrors move,
        /// and a VM whose download is still pending must keep fetching the
        /// distribution the user chose.
        case catalogEntry(LinuxImageCatalogEntry)
        /// A URL the user supplied, with the digest they supplied for it.
        case customURL(CustomLinuxImage)
    }

    var source: Source

    /// Where to write the downloaded ISO, `nil` until a resolution names the
    /// file — which for a catalog entry is only at download time, the mirror
    /// being the one to say which point release it is serving.
    ///
    /// Always a name ``LinuxImageFilename`` derived, so there is never a file
    /// here the user put there and no replace-existing prompt to show.
    ///
    /// A sibling `.kernovadownload` bundle at this location holds in-progress
    /// download state and enables resume across app restarts.
    var downloadDestinationPath: String?

    var downloadDestinationURL: URL? {
        downloadDestinationPath.map { URL(fileURLWithPath: $0) }
    }

    /// What the setup UI calls the image being fetched.
    var imageDisplayName: String {
        switch source {
        case .catalogEntry(let entry): "\(entry.distribution) \(entry.version)"
        // The name in the link, not the name on disk: the destination carries a
        // uniqueness suffix the user never typed and would not recognize.
        case .customURL(let image): image.displayName
        }
    }

    /// Whether the download is checked against a digest once it lands, which is
    /// the Verify step the progress indicator draws.
    var hasVerifyStep: Bool {
        switch source {
        case .catalogEntry: true
        case .customURL(let image): image.sha256 != nil
        }
    }

    init(source: Source, downloadDestinationPath: String? = nil) {
        self.source = source
        self.downloadDestinationPath = downloadDestinationPath
    }

    // MARK: - Codable

    /// Which ``Source`` a persisted document carries, so the payload keys can
    /// sit flat beside it rather than nested under a synthesized case name.
    private enum SourceKind: String, Codable {
        case catalogEntry
        case customURL
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case entry
        case remoteURL
        case sha256
        case downloadDestinationPath
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch source {
        case .catalogEntry(let entry):
            try c.encode(SourceKind.catalogEntry, forKey: .source)
            try c.encode(entry, forKey: .entry)
        case .customURL(let image):
            try c.encode(SourceKind.customURL, forKey: .source)
            try c.encode(image.url, forKey: .remoteURL)
            try c.encodeIfPresent(image.sha256, forKey: .sha256)
        }
        try c.encodeIfPresent(downloadDestinationPath, forKey: .downloadDestinationPath)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(SourceKind.self, forKey: .source) {
        case .catalogEntry:
            source = .catalogEntry(try c.decode(LinuxImageCatalogEntry.self, forKey: .entry))
        case .customURL:
            source = .customURL(
                CustomLinuxImage(
                    url: try c.decode(URL.self, forKey: .remoteURL),
                    sha256: try c.decodeIfPresent(String.self, forKey: .sha256)))
        }
        downloadDestinationPath = try c.decodeIfPresent(
            String.self, forKey: .downloadDestinationPath)
    }
}
