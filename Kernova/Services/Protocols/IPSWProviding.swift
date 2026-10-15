import Foundation

/// Looks up the macOS restore image (IPSW) a new guest installs by default.
protocol IPSWProviding: Sendable {
    /// The newest restore image Apple offers that this host can install.
    func fetchLatestRestoreImage() async throws -> LatestRestoreImage
}
