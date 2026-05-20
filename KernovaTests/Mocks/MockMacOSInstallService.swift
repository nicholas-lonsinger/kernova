import Foundation
@testable import Kernova

/// No-op mock for `MacOSInstallProviding`.
@MainActor
final class MockMacOSInstallService: MacOSInstallProviding {
    var installCallCount = 0

    #if arch(arm64)
    var installError: (any Error)?

    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws {
        installCallCount += 1
        if let error = installError { throw error }
        // Mirror the real `MacOSInstallService` post-install state: install
        // complete, ready to boot. The real service intentionally leaves
        // `instance.virtualMachine` set so `VirtualizationService.start`
        // can boot it in-place without re-locking auxiliary storage; the
        // mock has no VZ instance to attach, so the field stays nil and
        // callers that need the hand-off path must wire a VM separately.
        instance.status = .stopped
    }
    #endif
}
