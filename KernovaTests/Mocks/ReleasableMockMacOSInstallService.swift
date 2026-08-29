import Foundation

@testable import Kernova

/// A mock `MacOSInstallProviding` whose `install` parks until the test releases
/// it and then *succeeds*, ignoring cancellation entirely.
///
/// The counterpart of ``SuspendingMockMacOSInstallService``, which ends in a
/// throw: this one reproduces the window where a cancel is accepted while the
/// pipeline is finishing, so the pipeline returns normally and nothing in it
/// ever reports the cancellation.
///
/// Signals `installStartedStream` once parked, so a test can act against a
/// known-running install instead of guessing whether the task has started.
@MainActor
final class ReleasableMockMacOSInstallService: MacOSInstallProviding {
    let installStartedStream: AsyncStream<Void>
    private let installStartedContinuation: AsyncStream<Void>.Continuation

    /// What the install reports the VM was set up from.
    var installedImage = InstalledImage.macOSRestoreImage(version: "26.5.2", build: "25F84")

    private var parked: CheckedContinuation<Void, Never>?
    private var releasedEarly = false

    init() {
        let stream = AsyncStream<Void>.makeStream()
        self.installStartedStream = stream.stream
        self.installStartedContinuation = stream.continuation
    }

    /// Lets the parked install run to completion.
    func release() {
        if let parked {
            self.parked = nil
            parked.resume()
        } else {
            releasedEarly = true
        }
    }

    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage {
        installStartedContinuation.yield(())
        installStartedContinuation.finish()
        if !releasedEarly {
            // Deliberately not `withTaskCancellationHandler`: parking through a
            // cancellation-blind continuation is what makes the install finish
            // successfully after the cancel lands.
            await withCheckedContinuation { continuation in
                parked = continuation
            }
        }
        // Mirrors `MockMacOSInstallService`: the real service leaves the VM
        // released and stopped before the caller chains its auto-boot.
        instance.resetToStopped()
        return installedImage
    }
}
