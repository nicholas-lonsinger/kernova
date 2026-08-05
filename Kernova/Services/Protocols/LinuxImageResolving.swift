import Foundation

/// Why a catalog entry did not resolve to an image to download.
enum LinuxImageResolveError: LocalizedError, Equatable {
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
    /// Nothing about the answer is cached: the mirror renames the ISO on every
    /// point release, so a resolution is only as good as the moment it is used.
    func resolve(_ entry: LinuxImageCatalogEntry) async throws -> ResolvedLinuxImage
}
