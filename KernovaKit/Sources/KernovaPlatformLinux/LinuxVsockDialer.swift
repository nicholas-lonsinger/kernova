#if os(Linux)
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

import CKernovaShims
// Apple's Dispatch marks its source protocols `Sendable`; swift-corelibs-libdispatch does not.
@preconcurrency import Dispatch
import KernovaAgentCore
import KernovaAgentRuntime
import KernovaPlatformPOSIX
import KernovaWire

/// Dials the host over vsock: a non-blocking connect to the host's CID on the protocol's port, handed on
/// as a `POSIXByteStream` once it completes.
public struct LinuxVsockDialer: TransportDialer {
    /// `VMADDR_CID_HOST`: the host, as a guest addresses it.
    public static let hostCID: UInt32 = 2

    private let cid: UInt32
    private let port: UInt32
    private let queue = DispatchQueue(label: "app.kernova.vsock-dial")

    /// A dialer for `port` at `cid`.
    public init(cid: UInt32 = hostCID, port: UInt32 = WireConstants.vsockPort) {
        self.cid = cid
        self.port = port
    }

    /// Starts the connect and completes once it has: at once when the kernel refuses it, otherwise when
    /// the socket turns writable and `SO_ERROR` says how it ended. vsock bounds a connect's wait itself
    /// (`SO_VM_SOCKETS_CONNECT_TIMEOUT`, 2 s by default), ending it in `ETIMEDOUT`.
    public func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void) {
        var inProgress: Int32 = 0
        let descriptor = kernova_vsock_connect(cid, port, &inProgress)
        guard descriptor >= 0 else { return completion(.failure(Self.failure(errno: errno))) }
        guard inProgress != 0 else { return completion(Self.adopt(descriptor)) }
        let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { source.cancel() }
        // The descriptor is read and then closed or adopted only once the source no longer watches it.
        source.setCancelHandler {
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) != 0 { error = errno }
            guard error == 0 else {
                close(descriptor)
                return completion(.failure(Self.failure(errno: error)))
            }
            completion(Self.adopt(descriptor))
        }
        source.resume()
    }

    /// How a failed dial's error number reads: `EAFNOSUPPORT` (no vsock in the kernel) and `ENODEV` (no
    /// transport, as on a VM with no socket device) are permanent; anything else — `ECONNREFUSED` and
    /// `ECONNRESET` when the host has no listener yet or is at its connection cap — is worth retrying.
    public static func failure(errno: Int32) -> DialFailure {
        switch errno {
        case EAFNOSUPPORT, ENODEV: .permanent
        default: .transient
        }
    }

    private static func adopt(_ descriptor: Int32) -> Result<any ByteStream, DialFailure> {
        do throws(ByteStreamError) {
            return .success(try POSIXByteStream(adopting: descriptor))
        } catch {
            close(descriptor)
            return .failure(.transient)
        }
    }
}
#endif
