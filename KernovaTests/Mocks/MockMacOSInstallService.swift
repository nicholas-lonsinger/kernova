import Foundation
@testable import Kernova

/// No-op mock for `MacOSInstallProviding`.
@MainActor
final class MockMacOSInstallService: MacOSInstallProviding {
    var installCallCount = 0
    var lastRestoreImageURL: URL?
    /// What a successful install reports the VM was set up from.
    var installedImage = InstalledImage.macOSRestoreImage(version: "26.5.2", build: "25F84")

    var installError: (any Error)?

    /// Runs as the install starts, before it reports anything — where a test
    /// reads what the VM holds while the install runs.
    var onInstall: (@MainActor () -> Void)?

    func install(
        into instance: VMInstance,
        _ context: borrowing VMBringUpContext,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage {
        installCallCount += 1
        lastRestoreImageURL = restoreImageURL
        onInstall?()
        if let error = installError { throw error }
        // No installer session is bound, so there is none to stop: the setup
        // operation's ending rests the VM.
        return installedImage
    }
}
