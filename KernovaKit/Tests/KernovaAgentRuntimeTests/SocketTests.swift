#if canImport(Darwin) || os(Linux)
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentRuntime
import Testing

/// A raw socket pair: the stream adopts one end and the test drives the other with blocking calls.
enum RawSocket {
    /// A connected pair; `sendBuffer` sizes the first end's send buffer.
    static func pair(sendBuffer: Int32? = nil) throws -> (stream: Int32, far: Int32) {
        var descriptors: [Int32] = [0, 0]
        // Glibc imports SOCK_STREAM as an enum case; Darwin and Musl as an Int32.
        #if canImport(Glibc)
        let paired = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &descriptors)
        #else
        let paired = socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors)
        #endif
        guard paired == 0 else { throw ByteStreamError.system(errno) }
        if var size = sendBuffer {
            _ = setsockopt(descriptors[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        }
        return (descriptors[0], descriptors[1])
    }
}

/// The suites that open descriptors, run one test at a time so no test reuses a number another just closed.
@Suite("Sockets", .serialized)
enum SocketTests {}
#endif
