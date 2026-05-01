import Foundation
import Darwin

/// Wraps the BSD socket syscalls used by `VsockGuestClient.openVsockToHost`
/// so tests can inject failures at each layer of the non-blocking-connect
/// dance without depending on Darwin's thread-local `errno` or real
/// `AF_VSOCK` kernel support.
///
/// Each method returns both the `rc` and the captured `errno` as a tuple —
/// Darwin's thread-local `errno` is unmockable, and the production code
/// already pairs every rc with an immediate `let err = errno` read.
protocol RawSocketOps: Sendable {
    func socket(_ family: Int32, _ type: Int32, _ proto: Int32) -> (rc: Int32, errno: Int32)
    func fcntl(_ fd: Int32, _ cmd: Int32, _ arg: Int32) -> (rc: Int32, errno: Int32)
    func connect(
        _ fd: Int32,
        _ addr: UnsafePointer<sockaddr>,
        _ len: socklen_t
    ) -> (rc: Int32, errno: Int32)
    func poll(
        _ fds: UnsafeMutablePointer<pollfd>,
        _ nfds: nfds_t,
        _ timeoutMs: Int32
    ) -> (rc: Int32, errno: Int32)
    func getsockopt(
        _ fd: Int32,
        _ level: Int32,
        _ option: Int32,
        _ value: UnsafeMutableRawPointer,
        _ len: UnsafeMutablePointer<socklen_t>
    ) -> (rc: Int32, errno: Int32)
    func setsockopt(
        _ fd: Int32,
        _ level: Int32,
        _ option: Int32,
        _ value: UnsafeRawPointer,
        _ len: socklen_t
    ) -> (rc: Int32, errno: Int32)
    func close(_ fd: Int32)
}

/// Production implementation that delegates to real Darwin syscalls.
struct DarwinRawSocketOps: RawSocketOps {
    func socket(_ family: Int32, _ type: Int32, _ proto: Int32) -> (rc: Int32, errno: Int32) {
        let rc = Darwin.socket(family, type, proto)
        return (rc, Darwin.errno)
    }

    func fcntl(_ fd: Int32, _ cmd: Int32, _ arg: Int32) -> (rc: Int32, errno: Int32) {
        let rc = Darwin.fcntl(fd, cmd, arg)
        return (rc, Darwin.errno)
    }

    func connect(
        _ fd: Int32,
        _ addr: UnsafePointer<sockaddr>,
        _ len: socklen_t
    ) -> (rc: Int32, errno: Int32) {
        let rc = Darwin.connect(fd, addr, len)
        return (rc, Darwin.errno)
    }

    func poll(
        _ fds: UnsafeMutablePointer<pollfd>,
        _ nfds: nfds_t,
        _ timeoutMs: Int32
    ) -> (rc: Int32, errno: Int32) {
        let rc = Darwin.poll(fds, nfds, timeoutMs)
        return (rc, Darwin.errno)
    }

    func getsockopt(
        _ fd: Int32,
        _ level: Int32,
        _ option: Int32,
        _ value: UnsafeMutableRawPointer,
        _ len: UnsafeMutablePointer<socklen_t>
    ) -> (rc: Int32, errno: Int32) {
        let rc = Darwin.getsockopt(fd, level, option, value, len)
        return (rc, Darwin.errno)
    }

    func setsockopt(
        _ fd: Int32,
        _ level: Int32,
        _ option: Int32,
        _ value: UnsafeRawPointer,
        _ len: socklen_t
    ) -> (rc: Int32, errno: Int32) {
        let rc = Darwin.setsockopt(fd, level, option, value, len)
        return (rc, Darwin.errno)
    }

    func close(_ fd: Int32) {
        Darwin.close(fd)
    }
}
