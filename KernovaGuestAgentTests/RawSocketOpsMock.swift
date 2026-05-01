import Foundation
import Darwin

/// Scripted mock for `RawSocketOps` that returns pre-canned `(rc, errno)`
/// tuples per call and records every call for assertion.
///
/// Pop-from-front semantics: each per-method `Results` array is consumed in
/// order. When the script is exhausted, the default result for that method is
/// returned so tests that don't care about a particular call don't have to
/// script it explicitly.
///
/// Per-method defaults (used when the corresponding `Results` array is empty):
/// - `socket`     → `(rc: 5, errno: 0)` — a valid-looking fd
/// - `fcntl`      → `(rc: 0, errno: 0)` — success, flags = 0
/// - `connect`    → `(rc: 0, errno: 0)` — immediate success
/// - `poll`       → `(rc: 1, errno: 0, revents: POLLOUT)` — readable/writable
/// - `getsockopt` → `(rc: 0, errno: 0, soError: 0)` — no deferred error
/// - `setsockopt` → `(rc: 0, errno: 0)` — success
/// - `close`      → `Void` (always recorded, never scripted)
final class RawSocketOpsMock: RawSocketOps, @unchecked Sendable {

    // MARK: - Recorded call shapes

    enum Call: Equatable {
        case socket(family: Int32, type: Int32, proto: Int32)
        case fcntl(fd: Int32, cmd: Int32, arg: Int32)
        case connect(fd: Int32, len: socklen_t)
        case poll(timeoutMs: Int32)
        case getsockopt(fd: Int32, level: Int32, option: Int32)
        case setsockopt(fd: Int32, level: Int32, option: Int32)
        case close(fd: Int32)
    }

    // MARK: - Result scripts

    struct GetsockoptResult {
        var rc: Int32
        var errno: Int32
        /// Value written into the caller-provided `value` pointer (treated as
        /// `Int32*`). Only written when `rc == 0`.
        var soError: Int32

        init(rc: Int32 = 0, errno: Int32 = 0, soError: Int32 = 0) {
            self.rc = rc
            self.errno = errno
            self.soError = soError
        }
    }

    struct PollResult {
        var rc: Int32
        var errno: Int32
        /// Value written back into `pollfd.revents` when `rc > 0`.
        var revents: Int16

        init(rc: Int32 = 1, errno: Int32 = 0, revents: Int16 = Int16(POLLOUT)) {
            self.rc = rc
            self.errno = errno
            self.revents = revents
        }
    }

    var socketResults:    [(rc: Int32, errno: Int32)] = []
    var fcntlResults:     [(rc: Int32, errno: Int32)] = []
    var connectResults:   [(rc: Int32, errno: Int32)] = []
    var pollResults:      [PollResult]                = []
    var getsockoptResults:[GetsockoptResult]           = []
    var setsockoptResults:[(rc: Int32, errno: Int32)] = []

    // MARK: - Call log

    private let lock = NSLock()
    private(set) var calls: [Call] = []

    // MARK: - RawSocketOps conformance

    func socket(_ family: Int32, _ type: Int32, _ proto: Int32) -> (rc: Int32, errno: Int32) {
        let result = lock.withLock {
            calls.append(.socket(family: family, type: type, proto: proto))
            return socketResults.isEmpty ? (rc: 5, errno: 0) : socketResults.removeFirst()
        }
        return result
    }

    func fcntl(_ fd: Int32, _ cmd: Int32, _ arg: Int32) -> (rc: Int32, errno: Int32) {
        let result = lock.withLock {
            calls.append(.fcntl(fd: fd, cmd: cmd, arg: arg))
            return fcntlResults.isEmpty ? (rc: 0, errno: 0) : fcntlResults.removeFirst()
        }
        return result
    }

    func connect(
        _ fd: Int32,
        _ addr: UnsafePointer<sockaddr>,
        _ len: socklen_t
    ) -> (rc: Int32, errno: Int32) {
        let result = lock.withLock {
            calls.append(.connect(fd: fd, len: len))
            return connectResults.isEmpty ? (rc: 0, errno: 0) : connectResults.removeFirst()
        }
        return result
    }

    func poll(
        _ fds: UnsafeMutablePointer<pollfd>,
        _ nfds: nfds_t,
        _ timeoutMs: Int32
    ) -> (rc: Int32, errno: Int32) {
        let result = lock.withLock {
            calls.append(.poll(timeoutMs: timeoutMs))
            return pollResults.isEmpty
                ? PollResult(rc: 1, errno: 0, revents: Int16(POLLOUT))
                : pollResults.removeFirst()
        }
        if result.rc > 0 {
            fds.pointee.revents = result.revents
        }
        return (result.rc, result.errno)
    }

    func getsockopt(
        _ fd: Int32,
        _ level: Int32,
        _ option: Int32,
        _ value: UnsafeMutableRawPointer,
        _ len: UnsafeMutablePointer<socklen_t>
    ) -> (rc: Int32, errno: Int32) {
        let result = lock.withLock {
            calls.append(.getsockopt(fd: fd, level: level, option: option))
            return getsockoptResults.isEmpty
                ? GetsockoptResult(rc: 0, errno: 0, soError: 0)
                : getsockoptResults.removeFirst()
        }
        if result.rc == 0 {
            value.storeBytes(of: result.soError, as: Int32.self)
        }
        return (result.rc, result.errno)
    }

    func setsockopt(
        _ fd: Int32,
        _ level: Int32,
        _ option: Int32,
        _ value: UnsafeRawPointer,
        _ len: socklen_t
    ) -> (rc: Int32, errno: Int32) {
        let result = lock.withLock {
            calls.append(.setsockopt(fd: fd, level: level, option: option))
            return setsockoptResults.isEmpty ? (rc: 0, errno: 0) : setsockoptResults.removeFirst()
        }
        return result
    }

    func close(_ fd: Int32) {
        lock.withLock { calls.append(.close(fd: fd)) }
    }

    // MARK: - Helpers

    /// Returns all recorded `.close` calls.
    var closedFds: [Int32] {
        lock.withLock {
            calls.compactMap {
                if case .close(let fd) = $0 { return fd }
                return nil
            }
        }
    }
}
