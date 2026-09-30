import Foundation

/// The installer image a VM was set up from, as the install that used it named
/// the image.
///
/// Written once by that install and never revised, so it stays what the VM
/// started life as however far the guest is upgraded afterwards. The live
/// counterpart is ``VMConfiguration/lastSeenGuestOSVersion``, which only a
/// running guest agent can answer for.
enum InstalledImage: Sendable, Equatable {
    /// A macOS restore image, by the marketing version and Apple build the
    /// image itself carries.
    case macOSRestoreImage(version: String, build: String)

    /// A Linux installer image from the bundled catalog, by the distribution
    /// and version the catalog names, and the digest the attached ISO hashed
    /// to — `nil` only in a record that predates digests being kept.
    ///
    /// Attaching an ISO is not a completed install — the distribution's own
    /// installer runs inside the guest, and can write another distribution or
    /// nothing at all — so this names the media the VM was set up with, and
    /// the settings row it feeds is labelled for the media too.
    case linuxCatalogImage(distribution: String, version: String, digest: InstallerImageDigest?)

    /// A Linux installer image fetched from a URL the user supplied, and the
    /// digest the attached ISO hashed to.
    case linuxURLImage(url: URL, digest: InstallerImageDigest)

    /// The record of an ISO fetched from `linuxSource` that hashed to `digest`.
    init(linuxSource: LinuxInstallContext.Source, digest: InstallerImageDigest) {
        switch linuxSource {
        case .catalogEntry(let entry):
            self = .linuxCatalogImage(
                distribution: entry.distribution, version: entry.version, digest: digest)
        case .customURL(let image):
            self = .linuxURLImage(url: image.url, digest: digest)
        }
    }

    /// What the settings card shows for the record.
    var displayName: String {
        switch self {
        case .macOSRestoreImage(let version, let build): "macOS \(version) (\(build))"
        case .linuxCatalogImage(let distribution, let version, _): "\(distribution) \(version)"
        case .linuxURLImage(_, let digest): digest.filename
        }
    }
}

// MARK: - Codable

extension InstalledImage: Codable {
    /// Which case a persisted record carries, so the payload keys sit flat
    /// beside it rather than nested under a synthesized case name.
    private enum Kind: String, Codable {
        case macOSRestoreImage
        case linuxCatalogImage
        case linuxURLImage
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case build
        case distribution
        case url
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .macOSRestoreImage(let version, let build):
            try c.encode(Kind.macOSRestoreImage, forKey: .kind)
            try c.encode(version, forKey: .version)
            try c.encode(build, forKey: .build)
        case .linuxCatalogImage(let distribution, let version, let digest):
            try c.encode(Kind.linuxCatalogImage, forKey: .kind)
            try c.encode(distribution, forKey: .distribution)
            try c.encode(version, forKey: .version)
            try digest?.encode(to: encoder)
        case .linuxURLImage(let url, let digest):
            try c.encode(Kind.linuxURLImage, forKey: .kind)
            try c.encode(url, forKey: .url)
            try digest.encode(to: encoder)
        }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .macOSRestoreImage:
            self = .macOSRestoreImage(
                version: try c.decode(String.self, forKey: .version),
                build: try c.decode(String.self, forKey: .build))
        case .linuxCatalogImage:
            self = .linuxCatalogImage(
                distribution: try c.decode(String.self, forKey: .distribution),
                version: try c.decode(String.self, forKey: .version),
                digest: try InstallerImageDigest.decodeIfPresent(from: decoder))
        case .linuxURLImage:
            self = .linuxURLImage(
                url: try c.decode(URL.self, forKey: .url),
                digest: try InstallerImageDigest(from: decoder))
        }
    }
}
