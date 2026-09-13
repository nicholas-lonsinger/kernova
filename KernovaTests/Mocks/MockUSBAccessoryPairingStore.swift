import Foundation

@testable import Kernova

/// In-memory stand-in for `USBAccessoryPairingStoring`, one set per bundle URL
/// and nothing written to disk.
///
/// Lock-based for the reason `MockVMSnapshotStore` is: the protocol is
/// `Sendable`, so a call can arrive off the test's isolation.
final class MockUSBAccessoryPairingStore: USBAccessoryPairingStoring, @unchecked Sendable {
    private struct State {
        var sets: [URL: USBAccessoryPairingSet] = [:]
        var saveCount = 0
        var saveError: (any Error)?
    }

    private let lock = NSLock()
    private var state = State()

    /// Seeds what a bundle answers with, standing in for a file already on
    /// disk when the library first reads it.
    func setPairings(_ pairings: USBAccessoryPairingSet, for bundleURL: URL) {
        lock.withLock { state.sets[bundleURL] = pairings }
    }

    /// What a bundle holds now, `nil` when nothing was ever written for it.
    func pairings(for bundleURL: URL) -> USBAccessoryPairingSet? {
        lock.withLock { state.sets[bundleURL] }
    }

    /// How many writes reached the store, so a test can prove a no-op mutation
    /// wrote nothing.
    var saveCount: Int { lock.withLock { state.saveCount } }

    /// Thrown by the next and every later `save`.
    var saveError: (any Error)? {
        get { lock.withLock { state.saveError } }
        set { lock.withLock { state.saveError = newValue } }
    }

    func load(bundleURL: URL) -> USBAccessoryPairingSet {
        lock.withLock { state.sets[bundleURL] ?? USBAccessoryPairingSet() }
    }

    func save(_ pairings: USBAccessoryPairingSet, bundleURL: URL) throws {
        try lock.withLock {
            state.saveCount += 1
            if let error = state.saveError { throw error }
            state.sets[bundleURL] = pairings
        }
    }
}
