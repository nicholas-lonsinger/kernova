import Foundation

/// What an installer image's SHA-256 was compared with — never how the bytes
/// arrived, since a file adopted from Downloads is held to the same digest a
/// fresh download is.
enum DigestSource: Sendable, Equatable {
    /// A row in the distribution's checksum list, read from this URL.
    case checksumList(URL)
    /// The checksum the user typed beside a pasted URL.
    case enteredByUser

    /// The source as a noun phrase, for composing into UI copy.
    ///
    /// Names the checksum list by its host: that host is the trust anchor, and
    /// it can differ from the host the image itself is served from.
    var phrase: String {
        switch self {
        case .checksumList(let url):
            "the checksum list on \(url.host() ?? url.absoluteString)"
        case .enteredByUser:
            "the checksum you entered"
        }
    }
}

/// The SHA-256 a source states for an installer image, before any bytes are
/// hashed.
struct ExpectedDigest: Sendable, Equatable {
    /// Lowercase hex.
    let sha256: String
    let source: DigestSource

    init(sha256: String, source: DigestSource) {
        self.sha256 = sha256.lowercased()
        self.source = source
    }

    /// The record of `actual` matching this digest, or `nil` when it does not.
    func match(_ actual: String, filename: String) -> InstallerImageDigest? {
        let actual = actual.lowercased()
        guard actual == sha256 else { return nil }
        return InstallerImageDigest(filename: filename, sha256: actual, matched: source)
    }
}

/// The SHA-256 an installer image hashed to, and what it matched.
///
/// Built in code only by ``ExpectedDigest/match(_:filename:)`` or
/// ``unchecked(filename:sha256:)``, so a record claiming a match came from an
/// equal expected digest; decoding restores one those built.
struct InstallerImageDigest: Sendable, Equatable {
    /// The name the source gave the image the digest belongs to.
    let filename: String
    /// Lowercase hex.
    let sha256: String
    /// What the digest matched, or `nil` when it was computed but compared with
    /// nothing.
    let matched: DigestSource?

    fileprivate init(filename: String, sha256: String, matched: DigestSource?) {
        self.filename = filename
        self.sha256 = sha256
        self.matched = matched
    }

    /// A digest computed with nothing to compare it with.
    static func unchecked(filename: String, sha256: String) -> InstallerImageDigest {
        InstallerImageDigest(filename: filename, sha256: sha256.lowercased(), matched: nil)
    }
}

// MARK: - Codable

/// Encodes into the encoder it is handed rather than a nested container, so an
/// enclosing record's keys and these sit flat side by side.
extension InstallerImageDigest: Codable {
    private enum CheckedAgainst: String, Codable {
        case checksumList
        case enteredChecksum
        case nothing
    }

    private enum CodingKeys: String, CodingKey {
        case filename
        case sha256
        case checkedAgainst
        case checksumListURL
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(filename, forKey: .filename)
        try c.encode(sha256, forKey: .sha256)
        switch matched {
        case .checksumList(let url):
            try c.encode(CheckedAgainst.checksumList, forKey: .checkedAgainst)
            try c.encode(url, forKey: .checksumListURL)
        case .enteredByUser:
            try c.encode(CheckedAgainst.enteredChecksum, forKey: .checkedAgainst)
        case nil:
            try c.encode(CheckedAgainst.nothing, forKey: .checkedAgainst)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sha256 = try c.decode(String.self, forKey: .sha256)
        guard ChecksumManifest.isSHA256(sha256) else {
            throw DecodingError.dataCorruptedError(
                forKey: .sha256, in: c, debugDescription: "Not a SHA-256 digest")
        }
        let matched: DigestSource? =
            switch try c.decode(CheckedAgainst.self, forKey: .checkedAgainst) {
            case .checksumList: .checksumList(try c.decode(URL.self, forKey: .checksumListURL))
            case .enteredChecksum: .enteredByUser
            case .nothing: nil
            }
        self.init(
            filename: try c.decode(String.self, forKey: .filename),
            sha256: sha256.lowercased(), matched: matched)
    }

    /// The digest `decoder` holds, or `nil` when it holds no `sha256` key at
    /// all.
    static func decodeIfPresent(from decoder: any Decoder) throws -> InstallerImageDigest? {
        guard try decoder.container(keyedBy: CodingKeys.self).contains(.sha256) else {
            return nil
        }
        return try InstallerImageDigest(from: decoder)
    }
}
