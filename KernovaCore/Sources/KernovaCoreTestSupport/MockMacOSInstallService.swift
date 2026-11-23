import Foundation

@testable import KernovaCore

/// No-op mock for `MacOSInstallProviding`.
@MainActor
final class MockMacOSInstallService: MacOSInstallProviding {
    var installError: (any Error)?

    /// Reports the VM set up from a fixed restore image.
    func install(
        into instance: VMInstance,
        _ context: borrowing VMBringUpContext,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage {
        if let error = installError { throw error }
        // No installer session is bound, so there is none to stop: the setup
        // operation's ending rests the VM.
        return .macOSRestoreImage(version: "26.5.2", build: "25F84")
    }
}
