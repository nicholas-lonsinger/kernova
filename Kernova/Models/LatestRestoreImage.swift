import Foundation

/// The newest restore image Apple offers that this host can install, as
/// Virtualization reports it.
///
/// The install re-resolves the latest image when it starts, so what a wizard
/// step shows from this is a preview of that answer, not a pin on it.
struct LatestRestoreImage: Sendable, Equatable {
    var url: URL
    /// Marketing version, e.g. `"26.5.2"`.
    var version: String
    /// Apple build identifier, e.g. `"25F84"`.
    var build: String

    /// The filename the download lands on, derived from ``url``.
    var suggestedFilename: String {
        RestoreImageFilename.destination(for: url)
    }
}
