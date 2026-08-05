import Foundation

/// The one installer image a catalog entry names right now.
///
/// A catalog entry names a directory and a glob because a point release renames
/// the ISO in place; this is what that entry resolved to against the mirror's
/// own checksum manifest, and it is what the download verifies against.
struct ResolvedLinuxImage: Sendable, Equatable {
    /// Where the ISO is served from.
    var isoURL: URL
    /// The ISO's filename, checked to be one visible path component so it can
    /// be appended to a download directory.
    var filename: String
    /// The digest the manifest states for it, as 64 lowercase hex characters.
    var sha256: String
    /// The ISO's length in bytes, as the mirror reports it.
    var sizeBytes: UInt64
}
