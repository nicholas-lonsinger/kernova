import Foundation

/// The one installer image a source names right now.
///
/// What a catalog entry resolved to against its mirror's checksum manifest, or
/// what a user-supplied URL was found to serve — and, either way, what the
/// download is checked against.
struct ResolvedLinuxImage: Sendable, Equatable {
    /// Where the ISO is served from.
    var isoURL: URL
    /// The name the source gives the ISO, checked to be one visible path
    /// component.
    ///
    /// Shown, logged and named in a checksum failure — never written. What the
    /// bytes land on is ``destinationFilename``.
    var filename: String
    /// The digest to check the download against, as 64 lowercase hex
    /// characters, or `nil` when the source published none and there is nothing
    /// to verify.
    var sha256: String?
    /// The ISO's length in bytes, as the mirror reports it.
    var sizeBytes: UInt64

    /// The filename the download lands on, unique to ``isoURL`` on the terms
    /// ``LinuxImageFilename`` states.
    var destinationFilename: String {
        LinuxImageFilename.destination(for: isoURL)
    }
}
