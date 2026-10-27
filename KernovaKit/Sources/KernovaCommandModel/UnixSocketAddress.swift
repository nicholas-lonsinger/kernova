import Darwin
import Foundation

/// Builds the `sockaddr_un` an `AF_UNIX` bind or connect needs, and states the
/// `sun_path` capacity once for every caller.
///
/// `sockaddr_un.sun_path` is a fixed C array — 104 bytes on Darwin, including
/// the NUL terminator — so a path that does not fit cannot be represented at
/// all. Every caller refuses the same way rather than truncating.
public enum UnixSocketAddress {
    /// Largest path `sockaddr_un.sun_path` holds, including the NUL terminator.
    public static let maxPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

    /// Why a path cannot become an address.
    public enum Failure: Error, Sendable, Equatable {
        /// The NUL-terminated path needs `length` bytes and `sun_path` holds
        /// `max`.
        case pathTooLong(length: Int, max: Int)
    }

    /// The address `path` names.
    ///
    /// - Throws: ``Failure/pathTooLong(length:max:)`` when the NUL-terminated
    ///   path does not fit `sun_path`.
    public static func make(path: String) throws(Failure) -> sockaddr_un {
        let bytes = Array(path.utf8)
        let length = bytes.count + 1
        guard length <= maxPathLength else {
            throw .pathTooLong(length: length, max: maxPathLength)
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { rawPointer in
            rawPointer.withMemoryRebound(to: CChar.self, capacity: maxPathLength) { destination in
                for index in bytes.indices { destination[index] = CChar(bitPattern: bytes[index]) }
                destination[bytes.count] = 0
            }
        }
        return address
    }

    /// Runs `body` with `address` rebound to the `sockaddr` pointer and length
    /// the socket calls take.
    public static func withSockaddr<T>(
        _ address: inout sockaddr_un,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) -> T {
        withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
