#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import KernovaDBus

/// The byte stream a `DBusBusConnection` runs over: blocking reads on the
/// connection's own reader thread, whole writes on its writer thread.
public protocol DBusTransport: AnyObject, Sendable {
    /// Blocks until bytes arrive and copies them into `buffer`; 0 means the
    /// stream ended.
    func read(into buffer: UnsafeMutableRawBufferPointer) throws(DBusTransportError) -> Int
    /// Blocks until every byte of `bytes` is written.
    func write(_ bytes: [UInt8]) throws(DBusTransportError)
    /// Ends the stream both ways, waking a blocked `read`.
    func shutdown()
}

/// Why a transport could not connect, read or write.
public enum DBusTransportError: Error, Hashable, Sendable {
    /// `socket(2)` failed with `errno`.
    case socketFailed(errno: Int32)
    /// `connect(2)` failed with `errno`.
    case connectFailed(errno: Int32)
    /// A socket name longer than `sockaddr_un` holds.
    case socketNameTooLong
    /// `read(2)` failed with `errno`.
    case readFailed(errno: Int32)
    /// `send(2)` failed with `errno`.
    case writeFailed(errno: Int32)
}

/// A connected AF_UNIX stream socket.
public final class UnixSocketTransport: DBusTransport {
    private let descriptor: Int32

    /// Connects to `socket`.
    public init(connectingTo target: DBusAddress.UnixSocket) throws(DBusTransportError) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let name: [UInt8]
        switch target {
        case .path(let path): name = Array(path.utf8)
        // The abstract namespace is named by a leading NUL.
        case .abstract(let abstract): name = [0] + Array(abstract.utf8)
        }
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        // A path is NUL-terminated within `sun_path`; an abstract name is
        // exactly its bytes.
        guard name.count < capacity else { throw .socketNameTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: name)
        }
        let length = socklen_t(MemoryLayout<sa_family_t>.size + name.count)

        #if canImport(Glibc)
        let type = Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue)
        #else
        let type = SOCK_STREAM | SOCK_CLOEXEC
        #endif
        let descriptor = socket(AF_UNIX, type, 0)
        guard descriptor >= 0 else { throw .socketFailed(errno: errno) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) }
        }
        guard connected == 0 else {
            let error = errno
            close(descriptor)
            throw .connectFailed(errno: error)
        }
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Blocks until bytes arrive; 0 means the peer closed.
    public func read(into buffer: UnsafeMutableRawBufferPointer) throws(DBusTransportError) -> Int {
        while true {
            let count = recv(descriptor, buffer.baseAddress, buffer.count, 0)
            if count >= 0 { return count }
            guard errno == EINTR else { throw .readFailed(errno: errno) }
        }
    }

    /// Blocks until every byte is written. MSG_NOSIGNAL turns a closed peer
    /// into EPIPE here rather than a SIGPIPE that ends the process.
    public func write(_ bytes: [UInt8]) throws(DBusTransportError) {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                send(descriptor, raw.baseAddress.map { $0 + offset }, raw.count - offset, Int32(MSG_NOSIGNAL))
            }
            if count >= 0 {
                offset += count
            } else if errno != EINTR {
                throw .writeFailed(errno: errno)
            }
        }
    }

    /// Shuts the socket down both ways; the descriptor closes on deinit.
    public func shutdown() {
        shutdownBothWays(descriptor)
    }
}

/// `shutdown(2)`, which `UnixSocketTransport.shutdown()` shadows.
private func shutdownBothWays(_ descriptor: Int32) {
    #if canImport(Glibc)
    _ = Glibc.shutdown(descriptor, Int32(SHUT_RDWR))
    #else
    _ = Musl.shutdown(descriptor, Int32(SHUT_RDWR))
    #endif
}
#endif
