import Foundation

/// One macOS restore image in the bundled catalog.
///
/// Identity is ``build``, not ``version``: Apple ships hardware-specific spins
/// under one version number (15.4 exists as both `24E246` and `24E248`), so a
/// version is not unique and cannot address an image.
struct RestoreImageCatalogEntry: Codable, Sendable, Identifiable, Equatable {
    /// Marketing version, two or three dot-separated components (`"26.6"`, `"12.0.1"`).
    var version: String
    /// Apple build identifier, unique across the catalog.
    var build: String
    var url: URL
    var sizeBytes: UInt64
    /// The `Last-Modified` Apple's CDN reports for ``url``, in RFC 1123 form.
    var lastModified: String
    /// Which pass of `Tools/regen-restore-image-catalog.swift` found this image.
    var source: String

    var id: String { build }

    /// Apple's own filename for the image, e.g. `UniversalMac_15.6.1_24G90_Restore.ipsw`.
    var suggestedFilename: String {
        RestoreImageFilename.destination(for: url)
    }

    /// ``lastModified`` parsed for display, or `nil` if Apple's header did not parse.
    var releaseDate: Date? {
        Self.rfc1123Formatter.date(from: lastModified)
    }

    /// `version` split into numeric components, zero-padded to three.
    ///
    /// A component that is not a number yields `nil` — the entry is then
    /// unusable for host comparison and the service drops it.
    var versionComponents: [Int]? {
        MacOSVersion(version)?.components
    }

    /// Whether this guest can run on the given host.
    ///
    /// An unparseable version answers `false`: the catalog service drops such
    /// entries at decode time, so no pickable entry reaches this.
    func isSupported(onHost host: OperatingSystemVersion) -> Bool {
        MacOSVersion(version)?.isSupported(onHost: host) ?? false
    }

    /// Newest first, comparing version components numerically so 26.10 sorts
    /// above 26.9.
    ///
    /// Equal versions fall back to `build` so the order is total.
    static func isDescending(_ lhs: Self, _ rhs: Self) -> Bool {
        let left = lhs.versionComponents ?? []
        let right = rhs.versionComponents ?? []
        for (leftPart, rightPart) in zip(left, right) where leftPart != rightPart {
            return leftPart > rightPart
        }
        if left.count != right.count { return left.count > right.count }
        return lhs.build > rhs.build
    }

    /// Whether the entry matches a picker search term, over version and build.
    func matches(searchTerm: String) -> Bool {
        let term = searchTerm.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return true }
        return version.localizedCaseInsensitiveContains(term)
            || build.localizedCaseInsensitiveContains(term)
    }

    /// Fixed-locale RFC 1123 parser for Apple's `Last-Modified` header.
    ///
    /// `en_US_POSIX` and an explicit GMT zone keep the parse independent of the
    /// user's locale and time zone, which is what HTTP dates require.
    private static let rfc1123Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

/// The bundled catalog document.
struct RestoreImageCatalog: Codable, Sendable, Equatable {
    /// Apple's device key the images were verified against.
    var device: String
    /// `yyyy-MM-dd` the catalog was generated, shown in the picker footer.
    var generatedAt: String
    var images: [RestoreImageCatalogEntry]
}
