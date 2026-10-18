import Foundation

/// A value reachable only inside a lock hold.
///
/// `withLock` is the one access path, so no read or write can happen outside
/// the lock, and being synchronous it keeps every hold out of an `await`.
/// `Synchronization.Mutex`'s shape for code that deploys below macOS 15.
public final class Locked<Value> {
    private let lock = NSLock()
    private var value: Value

    /// Creates a lock holding `initialValue`.
    public init(_ initialValue: Value) {
        self.value = initialValue
    }

    /// Runs `body` with exclusive access to the value, and returns what it
    /// returns or rethrows what it throws.
    ///
    /// The lock is not reentrant: `body` calling `withLock` on the same box
    /// deadlocks.
    public func withLock<Result, E: Error>(_ body: (inout Value) throws(E) -> Result) throws(E) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}

/// Sound because the value is touched only under `lock`, and a `Sendable`
/// value is all that can be stored or handed out: a non-`Sendable` value makes
/// the box itself non-`Sendable`, so it cannot be shared to begin with.
extension Locked: @unchecked Sendable where Value: Sendable {}
