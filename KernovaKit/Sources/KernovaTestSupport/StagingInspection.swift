import Foundation
import KernovaSynchronization

/// A mutable cell a synchronous test closure records what it observed into
/// from a concurrency-checked context.
public final class Box<T> {
    private let cell: Locked<T>

    /// Creates a cell holding `value`.
    public init(_ value: T) { cell = Locked(value) }

    /// The current value; each read and each write takes the lock once, so a
    /// read-modify-write through it is two holds.
    public var value: T {
        get { cell.withLock { $0 } }
        set { cell.withLock { $0 = newValue } }
    }
}

extension Box: Sendable where T: Sendable {}

/// Every regular file anywhere under `directory` (recursive).
///
/// What a test asserts against to prove a transfer staged nothing it shouldn't
/// have — an intermediate archive, or a partial left behind by an abort.
public func materializedFiles(under directory: URL) -> [URL] {
    guard
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
        (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
    }
}
