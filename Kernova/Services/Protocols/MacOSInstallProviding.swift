import Foundation

/// Abstraction for macOS guest installation.
@MainActor
protocol MacOSInstallProviding: Sendable {
    /// Installs macOS under the guest-setup bring-up `context` belongs to, and
    /// answers with the restore image it ran from, for the caller to record on
    /// the VM.
    ///
    /// Returns once the installer's session has ended.
    func install(
        into instance: VMInstance,
        _ context: borrowing VMBringUpContext,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage
}
