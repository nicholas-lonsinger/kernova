import Foundation

/// Abstraction for macOS guest installation.
@MainActor
protocol MacOSInstallProviding: Sendable {
    /// Installs macOS and answers with the restore image it ran from, for the
    /// caller to record on the VM.
    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage
}
