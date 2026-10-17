import Foundation

/// Abstraction for macOS guest installation.
@MainActor
protocol MacOSInstallProviding: Sendable {
    /// Installs macOS under the guest-setup bring-up `context` belongs to, and
    /// answers with the restore image it ran from, for the caller to record on
    /// the VM.
    ///
    /// Returns once the installer's VM has stopped and its session ended.
    func install(
        into instance: VMInstance,
        _ context: borrowing VMBringUpContext,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage
}

// MARK: - Errors

enum MacOSInstallError: LocalizedError {
    case unsupportedRestoreImage
    case unsupportedHardwareModel
    case restoreImageNotFound(path: String)
    case restoreImageNotAFile(path: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRestoreImage:
            "The restore image does not contain a supported macOS configuration."
        case .unsupportedHardwareModel:
            "The hardware model in the restore image is not supported on this machine."
        case .restoreImageNotFound(let path):
            "The restore image could not be found at \(path)."
        case .restoreImageNotAFile(let path):
            "The restore image at \(path) is a folder, not a file."
        }
    }
}
