import Foundation
import KernovaKit

/// One macOS restore image in the bundled catalog.
///
/// Identity is ``build``, not ``version``: Apple ships hardware-specific spins
/// under one version number (15.4 exists as both `24E246` and `24E248`), so a
/// version is not unique and cannot address an image.
package struct RestoreImageCatalogEntry: Codable, Sendable, Identifiable, Equatable {
    /// Marketing version, two or three dot-separated components (`"26.6"`, `"12.0.1"`).
    package var version: String
    /// Apple build identifier, unique across the catalog.
    package var build: String
    var url: URL
    package var sizeBytes: UInt64
    /// The `Last-Modified` Apple's CDN reports for ``url``, in RFC 1123 form,
    /// or `nil` when it reported none — the generator omits the key then.
    var lastModified: String?
    /// Which pass of `Tools/regen-restore-image-catalog.swift` found this image.
    var source: String

    package var id: String { build }

    /// Apple's own filename for the image, e.g. `UniversalMac_15.6.1_24G90_Restore.ipsw`.
    package var suggestedFilename: String {
        RestoreImageFilename.destination(for: url)
    }

    /// ``lastModified`` parsed for display, or `nil` if it is absent or did not parse.
    package var releaseDate: Date? {
        lastModified.flatMap { Self.rfc1123Formatter.date(from: $0) }
    }

    /// ``version`` parsed, or `nil` when it does not parse — the entry is then
    /// unusable for host comparison and the service drops it.
    var parsedVersion: MacOSVersion? {
        MacOSVersion(version)
    }

    /// Whether this guest can run on the given host.
    ///
    /// An unparseable version answers `false`: the catalog service drops such
    /// entries at decode time, so no pickable entry reaches this.
    package func isSupported(onHost host: OperatingSystemVersion) -> Bool {
        parsedVersion?.isSupported(onHost: host) ?? false
    }

    /// Newest first, comparing versions numerically so 26.10 sorts above 26.9.
    ///
    /// A version that parses sorts above one that does not, and equal versions
    /// fall back to `build` so the order is total.
    static func isDescending(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.parsedVersion, rhs.parsedVersion) {
        case (let left?, let right?) where left != right: left > right
        case (.some, nil): true
        case (nil, .some): false
        default: lhs.build > rhs.build
        }
    }

    /// Whether the entry matches a picker search term, over version and build.
    package func matches(searchTerm: String) -> Bool {
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
