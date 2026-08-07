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

    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage {
        installCallCount += 1
        lastRestoreImageURL = restoreImageURL
        if let error = installError { throw error }
        // Mirror the real `MacOSInstallService` post-install state: VM
        // released (via `guestDidStop` → `resetToStopped` in production
        // after `waitForVMStopped`; simulated directly here) and status
        // `.stopped` so the caller's auto-boot runs the normal cold-boot
        // path with no stale refs.
        instance.resetToStopped()
        return installedImage
    }
}
