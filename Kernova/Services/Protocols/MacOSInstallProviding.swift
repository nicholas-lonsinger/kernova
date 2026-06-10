import Foundation

/// Abstraction for macOS guest installation.
@MainActor
protocol MacOSInstallProviding: Sendable {
    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws
}
