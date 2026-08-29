import Foundation
import KernovaTestSupport

@testable import Kernova

/// Recording mock for `FileSystemOperating`.
///
/// Records trash/remove requests instead of touching the disk, so tests
/// exercising delete flows never deposit fixture files in the user's real
/// Trash (and don't need to create fixture files at all — assertions read
/// the recorded URLs). Errors are injectable per operation to drive the
/// missing-file-swallow and failure-alert paths. `fileExists` always reports
/// true, so existence-gated branches take their present-file path.
///
/// Lock-based because production trashes from `Task.detached`, so calls
/// arrive off the test's isolation.
final class MockFileSystem: FileSystemOperating, @unchecked Sendable {
    private struct State {
        var trashedURLs: [URL] = []
        var removedURLs: [URL] = []
        var trashError: (any Error)?
        var removeError: (any Error)?
    }

    private let lock = NSLock()
    private var state = State()

    /// Fires after each recorded trash or remove, so a test can wait on a
    /// cleanup production runs from a detached task instead of polling for it.
    let recorded = AsyncGate()

    /// URLs passed to `trashItem(at:)`, in call order.
    ///
    /// Not recorded when the injected `trashError` is thrown instead.
    var trashedURLs: [URL] { lock.withLock { state.trashedURLs } }

    /// URLs passed to `removeItem(at:)`, in call order.
    ///
    /// Not recorded when the injected `removeError` is thrown instead.
    var removedURLs: [URL] { lock.withLock { state.removedURLs } }

    // MARK: - Error Injection

    var trashError: (any Error)? {
        get { lock.withLock { state.trashError } }
        set { lock.withLock { state.trashError = newValue } }
    }

    var removeError: (any Error)? {
        get { lock.withLock { state.removeError } }
        set { lock.withLock { state.removeError = newValue } }
    }

    // MARK: - FileSystemOperating

    func fileExists(atPath _: String) -> Bool {
        true
    }

    func trashItem(at url: URL) throws {
        try lock.withLock {
            if let error = state.trashError { throw error }
            state.trashedURLs.append(url)
        }
        recorded.notify()
    }

    func removeItem(at url: URL) throws {
        try lock.withLock {
            if let error = state.removeError { throw error }
            state.removedURLs.append(url)
        }
        recorded.notify()
    }
}
