import Foundation

/// The one installer image a catalog entry names right now.
///
/// What the entry resolved to against the mirror's own checksum manifest, and
/// what the download is verified against.
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
