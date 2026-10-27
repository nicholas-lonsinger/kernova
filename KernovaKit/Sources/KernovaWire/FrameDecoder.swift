#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Reads one direction of a connection: the preamble, then frames, from bytes
/// appended at any split.
///
/// `append(_:)` decodes as far as the bytes reach. Each header is validated as
/// soon as its 10th byte arrives, before any of its payload, so a hostile length
/// is refused without buffering it. Every control and MESSAGE payload, and raw
/// DATA under 64 KiB, is copied into storage of its own; a larger raw DATA
/// payload lying wholly inside one appended chunk is a slice of it. A payload
/// that spans appends is copied, as each one arrives, into storage sized for it,
/// so what the decoder holds is that payload, under 10 header bytes, and the
/// frames not yet returned.
///
/// Frames decoded before an error are returned first; then `nextFrame()` throws
/// the error, on every later call.
public struct FrameDecoder: Sendable {
    private struct Header: Sendable {
        var streamID: StreamID
        var type: FrameType
        var flags: FrameFlags
        var length: Int

        /// Whether a payload lying wholly inside one chunk is returned as a slice of it.
        var isSliceable: Bool {
            type == .data && !flags.contains(.message) && length >= 65_536
        }
    }

    private var preambleRead = false
    /// The bytes of a preamble or header not yet complete.
    private var partial: [UInt8] = []
    /// The validated header whose payload is still arriving, and the payload so far.
    private var header: Header?
    private var payload = Data()
    /// Decoded frames; those before `readyHead` were returned and are released.
    private var ready: [Frame] = []
    private var readyHead = 0
    private var readyPayloadByteCount = 0
    private var failure: FrameError?

    /// The bytes the decoder holds: a partial header, a partial payload, and the
    /// payloads of frames not yet returned.
    public var bufferedByteCount: Int { partial.count + payload.count + readyPayloadByteCount }

    /// Creates a decoder expecting the preamble first.
    public init() {}

    /// Decodes `bytes` as the transport delivered them. After an error, ignored.
    public mutating func append(_ bytes: Data) {
        var index = bytes.startIndex
        while index < bytes.endIndex, failure == nil {
            if let header {
                index = appendPayload(bytes, from: index, for: header)
            } else {
                index = appendHeaderBytes(bytes, from: index)
            }
        }
    }

    /// The next decoded frame, or nil when more bytes are needed.
    ///
    /// - Throws: The `FrameError` the preamble or a header showed, once every frame
    ///   decoded before it has been returned, and on every call after that.
    public mutating func nextFrame() throws(FrameError) -> Frame? {
        guard readyHead < ready.count else {
            if let failure { throw failure }
            return nil
        }
        let frame = ready[readyHead]
        // Released at once, so a returned payload is never pinned here.
        ready[readyHead] = Frame(streamID: .session, type: .data)
        readyHead += 1
        readyPayloadByteCount -= frame.payload.count
        if readyHead == ready.count {
            ready.removeAll(keepingCapacity: true)
            readyHead = 0
        }
        return frame
    }

    private mutating func appendHeaderBytes(_ bytes: Data, from index: Data.Index) -> Data.Index {
        let target = preambleRead ? WireConstants.headerByteCount : WireConstants.preamble.count
        let end = min(bytes.endIndex, index + (target - partial.count))
        partial.append(contentsOf: bytes[index..<end])
        guard partial.count == target else { return end }
        defer { partial.removeAll(keepingCapacity: true) }

        guard preambleRead else {
            if partial.elementsEqual(WireConstants.preamble) {
                preambleRead = true
            } else {
                fail(.badPreamble)
            }
            return end
        }
        func uint32(at offset: Int) -> UInt32 {
            partial[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        let typeByte = partial[4]
        let flagsByte = partial[5]
        let length = uint32(at: 6)
        switch Self.validate(typeByte: typeByte, flagsByte: flagsByte, length: length) {
        case .success(let type):
            let header = Header(
                streamID: StreamID(rawValue: uint32(at: 0)), type: type, flags: FrameFlags(rawValue: flagsByte),
                length: Int(length))
            if header.length == 0 {
                emit(header, payload: Data())
            } else {
                self.header = header
            }
        case .failure(let error):
            fail(error)
        }
        return end
    }

    private mutating func appendPayload(_ bytes: Data, from index: Data.Index, for header: Header) -> Data.Index {
        let available = bytes.endIndex - index
        if payload.isEmpty, available >= header.length {
            let end = index + header.length
            if header.isSliceable {
                emit(header, payload: bytes[index..<end])
            } else {
                var copy = Data(capacity: header.length)
                copy.append(bytes[index..<end])
                emit(header, payload: copy)
            }
            self.header = nil
            return end
        }
        if payload.isEmpty {
            payload = Data(capacity: header.length)
        }
        let end = index + min(available, header.length - payload.count)
        payload.append(bytes[index..<end])
        if payload.count == header.length {
            emit(header, payload: payload)
            payload = Data()
            self.header = nil
        }
        return end
    }

    private mutating func emit(_ header: Header, payload: Data) {
        ready.append(Frame(streamID: header.streamID, type: header.type, flags: header.flags, payload: payload))
        readyPayloadByteCount += payload.count
    }

    private mutating func fail(_ error: FrameError) {
        failure = error
        partial = []
        header = nil
        payload = Data()
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
}
