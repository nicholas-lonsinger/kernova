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

/// Why a user-supplied installer image URL was refused.
///
/// Separate from ``LinuxImageResolveError`` because every case there states
/// something about a mirror and its manifest, and none of that exists here: a
/// pasted URL is refused on what the user typed and what the server answered.
enum LinuxImageURLError: LocalizedError, Equatable {
    /// The text is not a URL naming a host.
    case malformedURL
    /// The URL's scheme is neither `http` nor `https`.
    case unsupportedScheme
    /// A plain-`http` URL with no digest behind it.
    case insecureURL
    /// The URL does not end in a filename that can be saved as an ISO.
    case notAnISOLink
    /// The supplied digest is not 64 hex characters.
    case malformedChecksum
    /// The server answered, but not with the file.
    case unreachable(statusCode: Int)
    /// The server would not say how large the file is.
    case sizeUnavailable
    /// The request did not complete.
    case transportFailed(description: String)

    var errorDescription: String? {
        switch self {
        case .malformedURL:
            "That isn't a valid URL. Paste the full link, starting with https://"
        case .unsupportedScheme:
            "Installer images can only be downloaded over https:// or http://"
        case .insecureURL:
            "Without a SHA-256 checksum, the link has to start with https://"
        case .notAnISOLink:
            "That link doesn't end in the name of an .iso file."
        case .malformedChecksum:
            "That isn't a SHA-256 checksum. It should be 64 hexadecimal characters."
        case .unreachable(let statusCode):
            "Nothing is hosted at that URL (HTTP \(statusCode)). Check the link and try again."
        case .sizeUnavailable:
            "That server didn't report the file's size. Try a direct link to the .iso file."
        case .transportFailed(let description):
            "Couldn't reach that URL: \(description)"
        }
    }
}

extension LinuxImageURLError {
    /// States a size read that did not complete in pasted-URL terms.
    init(_ error: RemoteFileSizeError) {
        switch error {
        case .insecureURL: self = .insecureURL
        case .unreachable(let statusCode): self = .unreachable(statusCode: statusCode)
        // A server that ignores `Range` leaves the size unread just as surely as
        // one that states none, and the user's move is the same either way.
        case .unknownSize, .rangeRequestsUnsupported: self = .sizeUnavailable
        case .transportFailed(let description): self = .transportFailed(description: description)
        }
    }
}

/// Abstraction for turning a Linux installer image source into the image to
/// download.
protocol LinuxImageResolving: Sendable {
    /// The ISO `entry` names right now, with the digest to verify it against.
    ///
    /// Nothing about the answer is cached — see ``LinuxImageCatalogEntry``.
    func resolve(_ entry: LinuxImageCatalogEntry) async throws -> ResolvedLinuxImage

    /// The ISO at `image`'s URL, with the digest the user supplied for it —
    /// which is `nil` when they supplied none and nothing will be verified.
    ///
    /// A fixed URL names one file, so this resolves nothing about *which* image
    /// to fetch. What it establishes is that the URL is admissible and live, and
    /// how large the file is, which is the ceiling the transfer is held to.
    func resolve(_ image: CustomLinuxImage) async throws -> ResolvedLinuxImage
}
