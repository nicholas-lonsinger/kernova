import Foundation
@testable import Kernova

/// A mock `MacOSInstallProviding` whose `install` parks until the surrounding
/// task is cancelled, then throws `terminalError` — `CancellationError()` for
/// the ordinary cancel path, or a distinct error to exercise the race where a
/// non-cancellation failure reaches the catch before the cancellation
/// propagates (e.g. a network failure arriving at roughly the same instant the
/// user clicked Cancel).
///
/// Signals `installStartedStream` once parked, so a test can act against a
/// known-running install instead of guessing whether the task has started.
@MainActor
final class SuspendingMockMacOSInstallService: MacOSInstallProviding {
    let installStartedStream: AsyncStream<Void>
    private let installStartedContinuation: AsyncStream<Void>.Continuation
    private let terminalError: any Error

    init(terminalError: any Error = CancellationError()) {
        let stream = AsyncStream<Void>.makeStream()
        self.installStartedStream = stream.stream
        self.installStartedContinuation = stream.continuation
        self.terminalError = terminalError
    }

    func install(
        into instance: VMInstance,
        restoreImageURL: URL,
        progressHandler: @MainActor @Sendable @escaping (Double) -> Void
    ) async throws -> InstalledImage {
        installStartedContinuation.yield(())
        installStartedContinuation.finish()
        // `try?` swallows the sleep's own `CancellationError` so `terminalError`
        // — which may not itself be a `CancellationError` — is what reaches the
        // caller.
        try? await Task.sleep(for: .seconds(60))
        throw terminalError
    }
}
