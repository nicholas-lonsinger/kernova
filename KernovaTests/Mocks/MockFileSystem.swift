import Foundation

@testable import Kernova

/// Recording mock for `FileSystemOperating`.
///
/// Records trash/remove requests instead of touching the disk, so tests
/// exercising delete flows never deposit fixture files in the user's real
/// Trash (and don't need to create fixture files at all — assertions read
/// the recorded URLs). Errors are injectable per operation to drive the
/// missing-file-swallow and failure-alert paths; `fileExistsResult` serves
/// existence-gated branches like the coordinator's fresh-download cleanup.
///
/// Lock-based because production trashes from `Task.detached`, so calls
/// arrive off the test's isolation.
final class MockFileSystem: FileSystemOperating, @unchecked Sendable {
    private struct State {
        var trashedURLs: [URL] = []
        var removedURLs: [URL] = []
        var trashError: (any Error)?
        var removeError: (any Error)?
        var fileExistsResult = true
    }

    private let lock = NSLock()
    private var state = State()

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

    var fileExistsResult: Bool {
        get { lock.withLock { state.fileExistsResult } }
        set { lock.withLock { state.fileExistsResult = newValue } }
    }

    // MARK: - FileSystemOperating

    func fileExists(atPath path: String) -> Bool {
        lock.withLock { state.fileExistsResult }
    }

    func trashItem(at url: URL) throws {
        try lock.withLock {
            if let error = state.trashError { throw error }
            state.trashedURLs.append(url)
        }
    }

    func removeItem(at url: URL) throws {
        try lock.withLock {
            if let error = state.removeError { throw error }
            state.removedURLs.append(url)
        }
    }
}
