import Foundation
import Synchronization

@testable import KernovaCore

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
final class MockFileSystem: FileSystemOperating {
    private struct State {
        var trashedURLs: [URL] = []
        var removedURLs: [URL] = []
        var trashError: (any Error)?
        var removeError: (any Error)?
    }

    private let state = Mutex(State())

    /// URLs passed to `trashItem(at:)`, in call order.
    ///
    /// Not recorded when the error ``setTrashError(_:)`` injected is thrown instead.
    var trashedURLs: [URL] { state.withLock { $0.trashedURLs } }

    /// URLs passed to `removeItem(at:)`, in call order.
    ///
    /// Not recorded when the error ``setRemoveError(_:)`` injected is thrown instead.
    var removedURLs: [URL] { state.withLock { $0.removedURLs } }

    // MARK: - Error Injection

    /// Sets the error every later `trashItem` throws; `nil` clears it.
    func setTrashError(_ error: (any Error)?) {
        state.withLock { $0.trashError = error }
    }

    /// Sets the error every later `removeItem` throws; `nil` clears it.
    func setRemoveError(_ error: (any Error)?) {
        state.withLock { $0.removeError = error }
    }

    // MARK: - FileSystemOperating

    func fileExists(atPath _: String) -> Bool {
        true
    }

    func trashItem(at url: URL) throws {
        try state.withLock { state in
            if let error = state.trashError { throw error }
            state.trashedURLs.append(url)
        }
    }

    func removeItem(at url: URL) throws {
        try state.withLock { state in
            if let error = state.removeError { throw error }
            state.removedURLs.append(url)
        }
    }
}
