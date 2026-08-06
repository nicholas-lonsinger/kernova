import Foundation

/// Why a catalog entry did not resolve to an image to download.
enum LinuxImageResolveError: LocalizedError, Equatable {
    /// The entry's directory is not an HTTPS URL.
    case insecureDirectory(url: URL)
    /// The entry's ISO pattern is not a wildcard `.iso` filename.
    case invalidISOPattern(pattern: String)
    /// The entry's checksum manifest does not name a file in the directory.
    case invalidManifestName(manifest: String)
    /// The checksum manifest was not served. `statusCode` is `nil` when nothing
    /// HTTP came back at all.
    case manifestUnreachable(manifest: String, statusCode: Int?)
    /// The manifest's body ran past the size a manifest can honestly be.
    case manifestTooLarge(manifest: String)
    /// The manifest was served but stated no checksum at all.
    case manifestUnparseable(manifest: String)
    /// Nothing the manifest lists matches the entry's ISO pattern.
    case noMatchingImage(pattern: String)
    /// The matched filename is not a name that can be saved.
    case unusableFilename(String)
    /// The mirror would not say how large the ISO is.
    case sizeUnavailable(filename: String)

    var errorDescription: String? {
        switch self {
        case .insecureDirectory(let url):
            "The saved image source isn't an HTTPS address ('\(url.absoluteString)')."
        case .invalidISOPattern(let pattern):
            "The saved image source doesn't name an ISO to look for ('\(pattern)')."
        case .invalidManifestName(let manifest):
            "The saved image source doesn't name a checksum list to read ('\(manifest)')."
        case .manifestUnreachable(let manifest, let statusCode?):
            "The mirror didn't serve this distribution's checksum list, \(manifest) (HTTP \(statusCode))."
        case .manifestUnreachable(let manifest, nil):
            "Couldn't reach this distribution's checksum list, \(manifest). Check your connection and try again."
        case .manifestTooLarge(let manifest):
            "The mirror answered with far more than a checksum list can hold, so \(manifest) wasn't read."
        case .manifestUnparseable(let manifest):
            "The mirror's \(manifest) listed no checksums, so this image can't be verified."
        case .noMatchingImage(let pattern):
            "The mirror no longer lists an image named like '\(pattern)'."
        case .unusableFilename(let filename):
            "The mirror listed this image under a name that can't be saved ('\(filename)')."
        case .sizeUnavailable(let filename):
            "The mirror didn't report how large '\(filename)' is."
        }
    }
}

/// Abstraction for turning a Linux catalog entry into the image to download.
protocol LinuxImageResolving: Sendable {
    /// The ISO `entry` names right now, with the digest to verify it against.
    ///
    /// Nothing about the answer is cached — see ``LinuxImageCatalogEntry``.
    func resolve(_ entry: LinuxImageCatalogEntry) async throws -> ResolvedLinuxImage
}
