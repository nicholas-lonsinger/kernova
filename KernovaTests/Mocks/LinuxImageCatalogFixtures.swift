import Foundation

@testable import Kernova

/// The catalog entry `context` carries, or `nil` when it carries another
/// source.
func catalogEntry(of context: LinuxInstallContext?) -> LinuxImageCatalogEntry? {
    guard let context, case .catalogEntry(let entry) = context.source else { return nil }
    return entry
}

/// The user-supplied image `context` carries, or `nil` when it carries another
/// source.
func customImage(of context: LinuxInstallContext?) -> CustomLinuxImage? {
    guard let context, case .customURL(let image) = context.source else { return nil }
    return image
}

/// Builds a user-supplied image, defaulted so a test only names what it cares
/// about.
func makeCustomLinuxImage(
    urlString: String = "https://mirror.example/alpine-3.22-aarch64.iso",
    sha256: String? = String(repeating: "a", count: 64)
) -> CustomLinuxImage {
    CustomLinuxImage(
        url: URL(string: urlString) ?? URL(fileURLWithPath: "/"), sha256: sha256)
}

/// Builds a Linux catalog entry, defaulted so a test only names what it cares
/// about.
func makeLinuxCatalogEntry(
    id: String = "debian-13",
    distribution: String = "Debian",
    version: String = "13",
    directoryURLString: String = "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/",
    isoPattern: String = "debian-13.*-arm64-netinst.iso",
    manifestDirectoryURLString: String? = nil,
    checksumManifest: String = "SHA256SUMS",
    approxSizeBytes: UInt64 = 735_358_976
) -> LinuxImageCatalogEntry {
    LinuxImageCatalogEntry(
        id: id,
        distribution: distribution,
        version: version,
        directoryURL: URL(string: directoryURLString) ?? URL(fileURLWithPath: "/"),
        isoPattern: isoPattern,
        manifestDirectoryURL: manifestDirectoryURLString.map {
            URL(string: $0) ?? URL(fileURLWithPath: "/")
        },
        checksumManifest: checksumManifest,
        approxSizeBytes: approxSizeBytes
    )
}
