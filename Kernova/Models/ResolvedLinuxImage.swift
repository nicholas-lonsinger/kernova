import Foundation

/// The one installer image a source names right now.
///
/// What a catalog entry resolved to against its mirror's checksum manifest, or
/// what a user-supplied URL was found to serve — and, either way, what the
/// download is checked against.
struct ResolvedLinuxImage: Sendable, Equatable {
    /// Where the ISO is served from.
    var isoURL: URL
    /// The ISO's filename, checked to be one visible path component so it can
    /// be appended to a download directory.
    var filename: String
    /// The digest to check the download against, as 64 lowercase hex
    /// characters, or `nil` when the source published none and there is nothing
    /// to verify.
    var sha256: String?
    /// The ISO's length in bytes, as the mirror reports it.
    var sizeBytes: UInt64
}
