#if canImport(Darwin)
import os
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WinSDK)
import WinSDK
#endif

/// A value reachable only inside a lock hold.
///
/// `withLock` is the one access path, so no read or write can happen outside
/// the lock, and being synchronous it keeps every hold out of an `await`.
/// `Synchronization.Mutex`'s shape for code that deploys below macOS 15.
public final class Locked<Value> {
    private let lock = PlatformLock()
    private var value: Value

    /// Creates a lock holding `initialValue`.
    public init(_ initialValue: Value) {
        self.value = initialValue
    }

    /// Runs `body` with exclusive access to the value, and returns what it
    /// returns or rethrows what it throws.
    ///
    /// The lock is not reentrant: `body` calling `withLock` on the same box
    /// deadlocks, or on Apple platforms traps.
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

/// The platform's own non-recursive mutex, at a fixed address as each one
/// requires: `os_unfair_lock`, `pthread_mutex_t`, or `SRWLOCK`.
private final class PlatformLock {
    #if canImport(Darwin)
    private let mutex = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    #elseif canImport(WinSDK)
    private let mutex = UnsafeMutablePointer<SRWLOCK>.allocate(capacity: 1)
    #else
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    #endif

    init() {
        #if canImport(Darwin)
        mutex.initialize(to: os_unfair_lock())
        #elseif canImport(WinSDK)
        InitializeSRWLock(mutex)
        #else
        pthread_mutex_init(mutex, nil)
        #endif
    }

    deinit {
        #if !canImport(Darwin) && !canImport(WinSDK)
        pthread_mutex_destroy(mutex)
        #endif
        mutex.deallocate()
    }

    func lock() {
        #if canImport(Darwin)
        os_unfair_lock_lock(mutex)
        #elseif canImport(WinSDK)
        AcquireSRWLockExclusive(mutex)
        #else
        pthread_mutex_lock(mutex)
        #endif
    }

    func unlock() {
        #if canImport(Darwin)
        os_unfair_lock_unlock(mutex)
        #elseif canImport(WinSDK)
        ReleaseSRWLockExclusive(mutex)
        #else
        pthread_mutex_unlock(mutex)
        #endif
    }
}
