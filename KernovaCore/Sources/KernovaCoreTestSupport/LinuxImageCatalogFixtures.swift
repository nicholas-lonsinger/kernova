import Foundation

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

@testable import KernovaCore

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
