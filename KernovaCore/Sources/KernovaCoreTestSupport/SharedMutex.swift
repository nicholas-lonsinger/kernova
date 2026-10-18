import Synchronization

/// A `Mutex` an escaping closure can capture.
///
/// `Mutex` is noncopyable, so a closure that outlives the scope declaring one
/// cannot capture it; this class gives it a shareable reference with the same
/// single access path.
public final class SharedMutex<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    /// Creates a lock holding `initialValue`.
    public init(_ initialValue: Value) {
        mutex = Mutex(initialValue)
    }

    /// Runs `body` with exclusive access to the value, and returns what it
    /// returns or rethrows what it throws.
    public func withLock<Result: Sendable, E: Error>(_ body: (inout Value) throws(E) -> Result) throws(E) -> Result {
        try mutex.withLock { (value: inout Value) throws(E) -> Result in try body(&value) }
    }
}
