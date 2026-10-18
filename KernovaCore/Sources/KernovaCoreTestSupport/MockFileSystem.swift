import Foundation
import Synchronization

#if SWIFT_PACKAGE
import KernovaTestSupport
#endif

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
        /// What a held trash waits on; `nil` while no hold is set.
        var trashHold: DispatchSemaphore?
        /// Trashes that took the hold and have not yet been signalled.
        var unreleasedTrashes = 0
        /// Trashes still parked, signalled or not.
        var parkedTrashes = 0
    }

    private let state = Mutex(State())

    /// Fires after each recorded trash or remove, so a test can wait on a
    /// cleanup production runs from a detached task instead of polling for it.
    let recorded = AsyncGate()

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

    // MARK: - Trash Hold

    /// Fires once a `trashItem` call has parked, so a test can observe what
    /// holds while the trash is in flight.
    let trashParked = AsyncGate()

    var isTrashParked: Bool { state.withLock { $0.parkedTrashes > 0 } }

    /// Parks every later `trashItem` call until ``resumeTrash()``.
    ///
    /// The call blocks the thread it arrives on, because `trashItem` is
    /// synchronous — production trashes from a detached task, never from the
    /// main actor a test runs on.
    func holdTrash() {
        state.withLock { state in
            if state.trashHold == nil { state.trashHold = DispatchSemaphore(value: 0) }
        }
    }

    /// Releases every parked `trashItem` call.
    func resumeTrash() {
        let (hold, parked) = state.withLock { state in
            defer {
                state.trashHold = nil
                state.unreleasedTrashes = 0
            }
            return (state.trashHold, state.unreleasedTrashes)
        }
        for _ in 0..<parked { hold?.signal() }
    }

    private func waitOutTrashHold() {
        let hold = state.withLock { state -> DispatchSemaphore? in
            guard let hold = state.trashHold else { return nil }
            state.unreleasedTrashes += 1
            state.parkedTrashes += 1
            return hold
        }
        guard let hold else { return }
        trashParked.notify()
        hold.wait()
        state.withLock { $0.parkedTrashes -= 1 }
    }

    // MARK: - FileSystemOperating

    func fileExists(atPath _: String) -> Bool {
        true
    }

    func trashItem(at url: URL) throws {
        waitOutTrashHold()
        try state.withLock { state in
            if let error = state.trashError { throw error }
            state.trashedURLs.append(url)
        }
        recorded.notify()
    }

    func removeItem(at url: URL) throws {
        try state.withLock { state in
            if let error = state.removeError { throw error }
            state.removedURLs.append(url)
        }
        recorded.notify()
    }
}
