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

    /// The name ``url`` gives the image, after every condition
    /// ``make(urlText:checksumText:)`` checked is checked again.
    ///
    /// Re-checked at use time because the value reaching here comes off a
    /// `config.json` a user can edit — the same reason `LinuxImageResolveService`
    /// re-admits a catalog entry before contacting its mirror.
    ///
    /// Nothing is named from this: the download lands on
    /// ``LinuxImageFilename/destination(for:)``.
    func admittedFilename() throws -> String {
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
        // A direct link to a named `.iso` is what holds a pasted URL to naming
        // an image rather than a landing page, and what gives the generated
        // destination a stem the user can recognize.
        guard let filename = SafeFilename.sanitized(url.lastPathComponent, requiring: "iso") else {
            throw LinuxImageURLError.notAnISOLink
        }
        return filename
    }

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
        _ = try image.admittedFilename()
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
