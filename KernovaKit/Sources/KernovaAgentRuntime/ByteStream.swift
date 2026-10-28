#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import Dispatch
import KernovaAgentCore
import KernovaWire

/// Why a byte stream's call failed.
public enum ByteStreamError: Error, Sendable, Equatable {
    /// `shutdown()` ended the stream first.
    case shutDown
    /// The OS call failed with this error number (`errno` on POSIX).
    case system(Int32)
}

/// How a byte stream's read side ended.
public enum ByteStreamEnd: Sendable, Equatable {
    /// The far side ended its writes.
    case eof
    /// A read failed, or `shutdown()` ended the stream first.
    case failed(ByteStreamError)
}

/// What a byte stream delivers to its handler.
public enum ByteStreamEvent: Sendable, Equatable {
    /// Bytes read, 1 … `ByteStreamLimits.maxReceive` of them.
    case received(Data)
    /// The read side ended; nothing more is delivered.
    case ended(ByteStreamEnd)
}

/// The bounds every `ByteStream` holds to.
public enum ByteStreamLimits {
    /// The most bytes one `.received` carries. The frame decoder's slice bound
    /// (a slice pins at most four times its own size) rests on it.
    public static let maxReceive = 262_144
}

/// One connected transport, read and written by one driver.
public protocol ByteStream: Sendable {
    /// Begins delivering events on `queue`. Each `.received` carries 1 … 262,144 bytes (a longer read is split);
    /// after each, nothing more is delivered until `readMore()`.
    func start(on queue: DispatchQueue, _ handler: @escaping @Sendable (ByteStreamEvent) -> Void)
    /// Allows the next event after a `.received`.
    func readMore()
    /// At most one write outstanding; the completion runs on the start queue, never inside this call. A write
    /// error says only that writing failed: the read side keeps delivering what the far side sent.
    func write(_ chunks: [Data], _ completion: @escaping @Sendable (ByteStreamError?) -> Void)
    /// Ends both directions. A pending write completes with an error; `.ended` is delivered once if it was not;
    /// every thread the stream parks is woken, and once both have been delivered the stream releases its
    /// descriptor and threads itself. Idempotent, any thread.
    func shutdown()
}

/// Connects a peer to its host.
public protocol TransportDialer: Sendable {
    /// Dials once; the completion runs on any thread.
    func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void)
}
