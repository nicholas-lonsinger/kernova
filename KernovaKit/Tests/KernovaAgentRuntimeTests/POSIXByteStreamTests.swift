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

import Dispatch
import KernovaAgentRuntime
import KernovaPlatformPOSIX
import KernovaSynchronization
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

    /// Writes all of `bytes`, blocking.
    static func send(_ descriptor: Int32, _ bytes: Data) {
        var offset = 0
        while offset < bytes.count {
            let sent = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress! + offset, bytes.count - offset) }
            guard sent > 0 else { return }
            offset += sent
        }
    }

    /// Reads, blocking, exactly `total` bytes in reads of varying size.
    static func read(_ descriptor: Int32, total: Int) -> Data {
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 7_919)
        var step = 0
        while bytes.count < total {
            step += 1
            let want = min(total - bytes.count, 1 + (step * 1_009) % buffer.count)
            let count = buffer.withUnsafeMutableBytes { recv(descriptor, $0.baseAddress, want, 0) }
            guard count > 0 else { return bytes }
            bytes.append(contentsOf: buffer[0..<count])
        }
        return bytes
    }
}

/// The suites that open descriptors, run one test at a time so no test reuses a number another just closed.
@Suite("Sockets", .serialized)
enum SocketTests {}
#endif
