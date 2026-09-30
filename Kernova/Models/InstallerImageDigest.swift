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
    var phrase: String {
        switch self {
        case .checksumList(let url): "the checksum list on \(Self.host(of: url))"
        case .enteredByUser: "the checksum you entered"
        }
    }

    /// The source as a standalone value, for a row or a summary line.
    var title: String {
        switch self {
        case .checksumList(let url): "Checksum list on \(Self.host(of: url))"
        case .enteredByUser: "Checksum you entered"
        }
    }

    /// The host copy names a checksum list by: that host is the trust anchor,
    /// and it can differ from the host the image itself is served from.
    private static func host(of checksumList: URL) -> String {
        checksumList.host() ?? checksumList.absoluteString
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

// MARK: - Display

/// What a Verification value reads when nothing was, or will be, checked.
private let notVerified = "Not verified"

extension InstallerImageDigest {
    /// The settings card's Verification value: what the digest matched, or that
    /// it was compared with nothing.
    var verificationSummary: String {
        matched.map { "Matched \($0.phrase)" } ?? notVerified
    }
}

/// How the wizard describes a pick's check before the image is downloaded. The
/// check runs only once the image is downloaded, so neither form claims a
/// result.
extension DigestSource {
    /// A download badge's secondary line.
    var pendingCheckLine: String { "Checked after download against \(phrase)" }
}

/// The wizard's forms for a pick that may have nothing to check against.
extension DigestSource? {
    /// A download badge's secondary line.
    var pendingCheckLine: String { self?.pendingCheckLine ?? notVerified }

    /// The Review step's Verification value.
    var pendingCheckTitle: String { self?.title ?? notVerified }
}

// MARK: - Codable

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
}
