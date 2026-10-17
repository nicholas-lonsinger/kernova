import Foundation

/// The one installer image a source names right now: what a catalog entry
/// resolved to against its mirror's checksum manifest, or what a user-supplied
/// URL was found to serve.
///
/// Carries no digest: what the download is checked against belongs to the
/// source, which builds it in ``LinuxInstallContext/Source/resolve(using:)``.
package struct ResolvedLinuxImage: Sendable, Equatable {
    /// Where the ISO is served from.
    var isoURL: URL
    /// The name the source gives the ISO, checked to be one visible path
    /// component.
    ///
    /// Never a path on disk: the bytes land on ``destinationFilename``.
    package var filename: String
    /// The ISO's length in bytes, as the mirror reports it.
    package var sizeBytes: UInt64

    /// The filename the download lands on, unique to ``isoURL`` on the terms
    /// ``LinuxImageFilename`` states.
    package var destinationFilename: String {
        LinuxImageFilename.destination(for: isoURL)
    }
}

/// A catalog entry's image, with the SHA-256 its checksum manifest lists for
/// it.
package struct ResolvedCatalogImage: Sendable, Equatable {
    var image: ResolvedLinuxImage
    /// The manifest row's digest, as the manifest spells it.
    var sha256: String
}
