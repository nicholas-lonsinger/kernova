import Foundation

/// An installer ISO at a user-supplied URL: where to fetch it, and the digest
/// the user typed in to check it against.
///
/// ``sha256`` is what the download is verified against, exactly as a catalog
/// pick is verified against its mirror's manifest. It says nothing about where
/// the user got the digest — only that the bytes on disk match it.
struct CustomLinuxImage: Codable, Sendable, Equatable {
    /// Where the ISO is served from.
    var url: URL

    /// The digest to check the download against, as 64 lowercase hex
    /// characters, or `nil` when the user supplied none and the download is not
    /// verified.
    var sha256: String?

    /// The name ``url`` itself gives the image, or a stand-in when it gives
    /// none.
    ///
    /// Shown, never written: nothing on disk is named from this, so it does not
    /// have to be safe to append to a directory and does not throw.
    var displayName: String {
        SafeFilename.sanitized(url.lastPathComponent, requiring: "iso") ?? "the installer image"
    }

    /// The filename this image's download lands on, after every condition
    /// ``make(urlText:checksumText:)`` checked is checked again.
    ///
    /// Re-checked at use time because the value reaching here comes off a
    /// `config.json` a user can edit — the same reason `LinuxImageResolveService`
    /// re-admits a catalog entry before contacting its mirror.
    ///
    /// The name is unique to ``url`` rather than taken from it. A link ending
    /// in a name the user already has in Downloads would otherwise resolve to
    /// that file, which `DownloadService` adopts as the download in place of
    /// fetching anything — installing an image the user never chose when there
    /// is no digest, and trashing their file when there is one.
    func destinationFilename() throws -> String {
        if let sha256, !ChecksumManifest.isSHA256(sha256) {
            throw LinuxImageURLError.malformedChecksum
        }
        // Scheme before host, so a `file:` or `ftp:` link — neither of which
        // carries one — is refused for what it is rather than as unparseable.
        guard let scheme = url.scheme?.lowercased() else {
            throw LinuxImageURLError.malformedURL
        }
        // HTTPS only, whatever digest is supplied: App Transport Security
        // refuses a cleartext load to any public host before the request is
        // issued, so admitting one here would only defer the refusal into an
        // error that says nothing the user can act on.
        guard scheme == "https" else {
            throw LinuxImageURLError.insecureURL
        }
        guard url.host() != nil else {
            throw LinuxImageURLError.malformedURL
        }
        // A direct link to a named `.iso` is what makes the generated name
        // recognizable and the destination an ISO, which is what the
        // replace-existing guard in the download pipeline keys on.
        guard SafeFilename.sanitized(url.lastPathComponent, requiring: "iso") != nil else {
            throw LinuxImageURLError.notAnISOLink
        }
        return UniqueDownloadFilename.make(
            for: url, fileExtension: "iso", defaultStem: Self.defaultStem)
    }

    /// Stem of a generated filename when the URL's own last component yields none.
    private static let defaultStem = "LinuxImage"

    /// The image `urlText` and `checksumText` name, or the first reason they
    /// name none.
    ///
    /// Both arrive as typed, whitespace included. An empty `checksumText` is a
    /// deliberate "don't verify this", not a malformed digest.
    static func make(urlText: String, checksumText: String) throws -> CustomLinuxImage {
        let sha256 = try normalizedChecksum(checksumText)
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw LinuxImageURLError.malformedURL }
        let image = CustomLinuxImage(url: url, sha256: sha256)
        _ = try image.destinationFilename()
        return image
    }

    /// `text` as 64 lowercase hex characters, `nil` when it holds no digest at
    /// all, throwing when it holds something that is not one.
    static func normalizedChecksum(_ text: String) throws -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard ChecksumManifest.isSHA256(trimmed) else {
            throw LinuxImageURLError.malformedChecksum
        }
        return trimmed.lowercased()
    }
}
