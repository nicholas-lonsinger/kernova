#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Reads one direction of a connection: the preamble, then frames, from bytes
/// appended at any split.
///
/// Each header is validated as soon as its 10 bytes are buffered, before any of
/// its payload is waited for, so a hostile length is refused without buffering
/// it. Every control and MESSAGE payload, and raw DATA under 64 KiB, is copied
/// into storage of its own; a larger raw DATA payload lying wholly inside one
/// appended chunk is a slice of it, and otherwise is assembled with one copy.
/// The first error is final: `nextFrame()` throws it again on every later call.
public struct FrameDecoder: Sendable {
    private struct Header: Sendable {
        var streamID: StreamID
        var type: FrameType
        var flags: FrameFlags
        var length: Int
    }

    private enum Phase: Sendable {
        case preamble
        case header
        case payload(Header)
        case failed(FrameError)
    }

    /// Raw DATA payloads at least this long may be returned as a slice.
    private static let sliceThreshold = 65_536

    /// Appended chunks; those before `head` are consumed and emptied.
    private var chunks: [Data] = []
    private var head = 0
    /// Bytes consumed from `chunks[head]`.
    private var offsetInHead = 0
    private var phase = Phase.preamble

    /// Bytes appended and not yet consumed by a returned frame or a validated header.
    public private(set) var bufferedByteCount = 0

    /// Creates a decoder expecting the preamble first.
    public init() {}

    /// Buffers bytes as the transport delivered them. After an error, ignored.
    public mutating func append(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        if case .failed = phase { return }
        chunks.append(bytes)
        bufferedByteCount += bytes.count
    }

    /// The next whole frame, or nil when more bytes are needed.
    ///
    /// - Throws: The `FrameError` the preamble or a header shows, the first time
    ///   and on every call after it.
    public mutating func nextFrame() throws(FrameError) -> Frame? {
        while true {
            switch phase {
            case .failed(let error):
                throw error
            case .preamble:
                guard bufferedByteCount >= WireConstants.preamble.count else { return nil }
                var received: [UInt8] = []
                for _ in 0..<WireConstants.preamble.count {
                    received.append(popByte())
                }
                guard received.elementsEqual(WireConstants.preamble) else { try fail(.badPreamble) }
                phase = .header
            case .header:
                guard bufferedByteCount >= WireConstants.headerByteCount else { return nil }
                let streamID = popUInt32()
                let typeByte = popByte()
                let flagsByte = popByte()
                let length = popUInt32()
                switch Self.validate(typeByte: typeByte, flagsByte: flagsByte, length: length) {
                case .success(let type):
                    phase = .payload(
                        Header(
                            streamID: StreamID(rawValue: streamID), type: type,
                            flags: FrameFlags(rawValue: flagsByte), length: Int(length)))
                case .failure(let error):
                    try fail(error)
                }
            case .payload(let header):
                guard bufferedByteCount >= header.length else { return nil }
                let isRawData = header.type == .data && !header.flags.contains(.message)
                let payload = popPayload(
                    count: header.length, sliceable: isRawData && header.length >= Self.sliceThreshold)
                phase = .header
                return Frame(streamID: header.streamID, type: header.type, flags: header.flags, payload: payload)
            }
        }
    }

    private mutating func fail(_ error: FrameError) throws(FrameError) -> Never {
        phase = .failed(error)
        chunks = []
        head = 0
        offsetInHead = 0
        bufferedByteCount = 0
        throw error
    }

    private static func validate(typeByte: UInt8, flagsByte: UInt8, length: UInt32) -> Result<FrameType, FrameError> {
        guard let type = FrameType(rawValue: typeByte) else { return .failure(.unknownType(typeByte)) }
        let definedFlags: FrameFlags = type == .data ? .message : []
        guard FrameFlags(rawValue: flagsByte).isSubset(of: definedFlags) else {
            return .failure(.undefinedFlags(type, flagsByte))
        }
        switch type {
        case .window, .ping:
            let fixed = type == .window ? WireConstants.windowPayloadByteCount : WireConstants.pingPayloadByteCount
            guard length == fixed else { return .failure(.wrongFixedLength(type, declared: length)) }
        case .data where !FrameFlags(rawValue: flagsByte).contains(.message):
            guard length <= WireConstants.maxRawDataPayload else {
                return .failure(.payloadTooLarge(type, declared: length))
            }
            guard length > 0 else { return .failure(.emptyRawData) }
        case .data, .open, .end, .reset:
            guard length <= WireConstants.maxControlPayload else {
                return .failure(.payloadTooLarge(type, declared: length))
            }
        }
        return .success(type)
    }

    // MARK: - Consuming buffered bytes

    /// Only called with at least one byte buffered.
    private mutating func popByte() -> UInt8 {
        let chunk = chunks[head]
        let byte = chunk[chunk.startIndex + offsetInHead]
        consume(1)
        return byte
    }

    private mutating func popUInt32() -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = value << 8 | UInt32(popByte())
        }
        return value
    }

    /// Only called with at least `count` bytes buffered.
    private mutating func popPayload(count: Int, sliceable: Bool) -> Data {
        guard count > 0 else { return Data() }
        let chunk = chunks[head]
        let start = chunk.startIndex + offsetInHead
        if sliceable, chunk.endIndex - start >= count {
            let slice = chunk[start..<(start + count)]
            consume(count)
            return slice
        }
        var payload = Data(capacity: count)
        var remaining = count
        while remaining > 0 {
            let current = chunks[head]
            let from = current.startIndex + offsetInHead
            let take = min(remaining, current.endIndex - from)
            payload.append(current[from..<(from + take)])
            consume(take)
            remaining -= take
        }
        return payload
    }

    /// Advances past `count` bytes of the head chunk, which holds at least that many.
    private mutating func consume(_ count: Int) {
        offsetInHead += count
        bufferedByteCount -= count
        guard offsetInHead == chunks[head].count else { return }
        // Emptied rather than kept, so a consumed chunk is never pinned by the buffer.
        chunks[head] = Data()
        head += 1
        offsetInHead = 0
        if head == chunks.count {
            chunks.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= chunks.count {
            chunks.removeFirst(head)
            head = 0
        }
    }
}
