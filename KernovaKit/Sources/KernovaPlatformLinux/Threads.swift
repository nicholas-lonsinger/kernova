#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A pthread mutex and the condition variable that waits on it, whose timed
/// waits run on CLOCK_MONOTONIC, so a change to the wall clock moves no
/// deadline.
final class Condition: @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)

    init() {
        pthread_mutex_init(mutex, nil)
        var attributes = pthread_condattr_t()
        pthread_condattr_init(&attributes)
        pthread_condattr_setclock(&attributes, CLOCK_MONOTONIC)
        pthread_cond_init(condition, &attributes)
        pthread_condattr_destroy(&attributes)
    }

    deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deallocate()
        mutex.deallocate()
    }

    func lock() {
        pthread_mutex_lock(mutex)
    }

    func unlock() {
        pthread_mutex_unlock(mutex)
    }

    func broadcast() {
        pthread_cond_broadcast(condition)
    }

    /// Waits, the mutex held, until woken.
    func wait() {
        pthread_cond_wait(condition, mutex)
    }

    /// Waits, the mutex held, until woken or `deadline`; false once the
    /// deadline has passed.
    func wait(until deadline: Deadline) -> Bool {
        var time = deadline.time
        return pthread_cond_timedwait(condition, mutex, &time) != ETIMEDOUT
    }
}

/// A point on CLOCK_MONOTONIC.
struct Deadline: Sendable {
    fileprivate let time: timespec

    /// `duration` from now.
    init(after duration: Duration) {
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        let (seconds, attoseconds) = duration.components
        var nanoseconds = Int(now.tv_nsec) + Int(attoseconds / 1_000_000_000)
        var wholeSeconds = Int(now.tv_sec) + Int(seconds)
        if nanoseconds >= 1_000_000_000 {
            nanoseconds -= 1_000_000_000
            wholeSeconds += 1
        }
        time = timespec(tv_sec: time_t(wholeSeconds), tv_nsec: Int(nanoseconds))
    }
}

/// The stack every thread `startThread(_:)` starts gets, whatever the libc's
/// default: glibc's is 8 MiB, musl's 128 KiB, and the reader runs handlers and
/// a decode nested up to `DBusLimits.maximumValueNesting` deep.
let threadStackSize = 1 << 20

/// Runs `body` on a new detached thread with a `threadStackSize` stack,
/// returning `pthread_create`'s error, 0 when the thread started.
func startThread(_ body: @escaping @Sendable () -> Void) -> Int32 {
    final class Body {
        let run: @Sendable () -> Void
        init(_ run: @escaping @Sendable () -> Void) { self.run = run }
    }
    let context = Unmanaged.passRetained(Body(body))
    var attributes = pthread_attr_t()
    pthread_attr_init(&attributes)
    defer { pthread_attr_destroy(&attributes) }
    pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED))
    pthread_attr_setstacksize(&attributes, threadStackSize)
    // Glibc spells `pthread_t` as an integer, Musl as a pointer.
    #if canImport(Glibc)
    var thread = pthread_t()
    #else
    var thread: pthread_t?
    #endif
    let error = pthread_create(
        &thread, &attributes,
        { context in
            guard let context else { return nil }
            Unmanaged<Body>.fromOpaque(context).takeRetainedValue().run()
            return nil
        }, context.toOpaque())
    if error != 0 {
        context.release()
    }
    return error
}

/// Whether the calling thread is `thread`.
func isCurrentThread(_ thread: pthread_t) -> Bool {
    pthread_equal(pthread_self(), thread) != 0
}
#endif
