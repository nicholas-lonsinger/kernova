import Foundation
@testable import Kernova

/// A mock `MacOSInstallProviding` whose `install` parks until the surrounding
/// task is cancelled, then lets the resulting `CancellationError` propagate —
/// the ordinary cancel path.
///
/// Signals `installStartedStream` once parked, so a test can act against a
/// known-running install instead of guessing whether the task has started.
@MainActor
final class SuspendingMockMacOSInstallService: MacOSInstallProviding {
    let installStartedStream: AsyncStream<Void>
    private let installStartedContinuation: AsyncStream<Void>.Continuation

    init() {
        let stream = AsyncStream<Void>.makeStream()
        self.installStartedStream = stream.stream
        self.installStartedContinuation = stream.continuation
    }

    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage {
        installStartedContinuation.yield(())
        installStartedContinuation.finish()
        try await Task.sleep(for: .seconds(60))
        throw CancellationError()
    }
}
