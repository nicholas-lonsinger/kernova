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
    /// and version the catalog names.
    ///
    /// Attaching an ISO is not a completed install — the distribution's own
    /// installer runs inside the guest, and can write another distribution or
    /// nothing at all — so this names the media the VM was set up with, and
    /// the settings row it feeds is labelled for the media too.
    case linuxCatalogImage(distribution: String, version: String)

    /// The record a pending Linux download supports: a catalog entry publishes
    /// a distribution and version to record, a user-supplied URL publishes
    /// neither.
    init?(linuxSource: LinuxInstallContext.Source) {
        switch linuxSource {
        case .catalogEntry(let entry):
            self = .linuxCatalogImage(distribution: entry.distribution, version: entry.version)
        case .customURL:
            return nil
        }
    }

    /// What the settings card shows for the record.
    var displayName: String {
        switch self {
        case .macOSRestoreImage(let version, let build): "macOS \(version) (\(build))"
        case .linuxCatalogImage(let distribution, let version): "\(distribution) \(version)"
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
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case version
        case build
        case distribution
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .macOSRestoreImage(let version, let build):
            try c.encode(Kind.macOSRestoreImage, forKey: .kind)
            try c.encode(version, forKey: .version)
            try c.encode(build, forKey: .build)
        case .linuxCatalogImage(let distribution, let version):
            try c.encode(Kind.linuxCatalogImage, forKey: .kind)
            try c.encode(distribution, forKey: .distribution)
            try c.encode(version, forKey: .version)
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
                version: try c.decode(String.self, forKey: .version))
        }
    }
}
