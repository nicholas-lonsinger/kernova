import Foundation

// MARK: - Wire Format Constants

/// SPICE agent protocol constants from spice-protocol/spice/vd_agent.h.
///
/// All multi-byte integers on the wire are **little-endian**.
enum SpiceConstants {
    /// Protocol version stamped in every `VDAgentMessage`.
    static let agentProtocol: UInt32 = 1

    /// Destination port for host → guest messages (`VDP_SERVER_PORT`).
    /// The guest agent reads from this port.
    static let serverPort: UInt32 = 2

    /// Destination port for guest → host messages (`VDP_CLIENT_PORT`).
    /// The host reads from this port.
    static let clientPort: UInt32 = 1
}

// MARK: - VDI Chunk Header

/// The outer framing layer for all SPICE agent communication.
///
/// Every read/write on the virtio serial port is wrapped in this 8-byte header:
/// ```
/// ┌──────────┬──────────┬────────────────────┐
/// │ port (4) │ size (4) │ payload (variable)  │
/// └──────────┴──────────┴────────────────────┘
/// ```
struct VDIChunkHeader: Sendable {
    static let size = 8

    let port: UInt32
    let dataSize: UInt32

    func serialize() -> Data {
        var data = Data(capacity: Self.size)
        data.appendLittleEndian(port)
        data.appendLittleEndian(dataSize)
        return data
    }

    static func deserialize(from data: Data) -> VDIChunkHeader? {
        guard data.count >= size,
              let port = data.readLittleEndianUInt32(at: 0),
              let dataSize = data.readLittleEndianUInt32(at: 4) else { return nil }
        return VDIChunkHeader(port: port, dataSize: dataSize)
    }
}

// MARK: - VDAgent Message Header

/// The inner message header inside a VDI chunk payload.
///
/// ```
/// ┌──────────────┬────────────┬────────────────┬────────────┬────────────────────┐
/// │ protocol (4) │ type (4)   │ opaque (8)     │ size (4)   │ data (variable)    │
/// └──────────────┴────────────┴────────────────┴────────────┴────────────────────┘
/// ```
struct VDAgentMessageHeader: Sendable {
    static let size = 20

    let type: SpiceAgentMessageType
    let opaque: UInt64
    let dataSize: UInt32

    func serialize() -> Data {
        var data = Data(capacity: Self.size)
        data.appendLittleEndian(SpiceConstants.agentProtocol)
        data.appendLittleEndian(type.rawValue)
        data.appendLittleEndian(opaque)
        data.appendLittleEndian(dataSize)
        return data
    }

    static func deserialize(from data: Data) -> VDAgentMessageHeader? {
        guard data.count >= size,
              let typeRaw = data.readLittleEndianUInt32(at: 4),
              let opaque = data.readLittleEndianUInt64(at: 8),
              let dataSize = data.readLittleEndianUInt32(at: 16),
              let type = SpiceAgentMessageType(rawValue: typeRaw) else { return nil }
        return VDAgentMessageHeader(type: type, opaque: opaque, dataSize: dataSize)
    }
}

// MARK: - Message Types

/// SPICE agent message types (from `VD_AGENT_*` enum).
enum SpiceAgentMessageType: UInt32, Sendable {
    case mouseState             = 1
    case monitorsConfig         = 2
    case reply                  = 3
    case clipboard              = 4
    case displayConfig          = 5
    case announceCapabilities   = 6
    case clipboardGrab          = 7
    case clipboardRequest       = 8
    case clipboardRelease       = 9
}

// MARK: - Clipboard Types

/// Data format identifiers for clipboard content.
enum SpiceClipboardType: UInt32, Sendable {
    case none     = 0
    case utf8Text = 1
    case png      = 2
    case bmp      = 3
    case tiff     = 4
    case jpg      = 5
}

// MARK: - Capability Bits

/// Capability bit positions for `VD_AGENT_CAP_*`.
enum SpiceAgentCapability: Int, Sendable {
    case mouseState                 = 0
    case monitorsConfig             = 1
    case reply                      = 2
    case clipboard                  = 3
    case displayConfig              = 4
    case clipboardByDemand          = 5
    case clipboardSelection         = 6
    case sparseMonitorsConfig       = 7
    case guestLineendLF             = 8
    case guestLineendCRLF           = 9
    case maxClipboard               = 10
    case clipboardNoReleaseOnRegrab = 16
    case clipboardGrabSerial        = 17
}

// MARK: - Message Builders

/// Builds complete wire-ready messages (VDI chunk header + VDAgent message header + data).
///
/// Shared between the host app and guest agent. The `port` parameter defaults to
/// `serverPort` for host-side callers; guest-side code passes `clientPort` explicitly.
enum SpiceMessageBuilder {

    /// Builds an `ANNOUNCE_CAPABILITIES` message advertising clipboard support.
    static func buildAnnounceCapabilities(request: Bool, port: UInt32 = SpiceConstants.serverPort) -> Data {
        // Capabilities payload: request (uint32) + caps array (1 × uint32)
        var caps: UInt32 = 0
        setCapability(&caps, .clipboard)
        setCapability(&caps, .clipboardByDemand)

        var payload = Data(capacity: 8)
        payload.appendLittleEndian(request ? UInt32(1) : UInt32(0))
        payload.appendLittleEndian(caps)

        return wrapMessage(type: .announceCapabilities, payload: payload, port: port)
    }

    /// Builds a `CLIPBOARD_GRAB` message announcing available clipboard types.
    ///
    /// Without `VD_AGENT_CAP_CLIPBOARD_SELECTION`, the grab payload is simply
    /// an array of `uint32_t` type values.
    static func buildClipboardGrab(types: [SpiceClipboardType], port: UInt32 = SpiceConstants.serverPort) -> Data {
        var payload = Data(capacity: types.count * 4)
        for type in types {
            payload.appendLittleEndian(type.rawValue)
        }
        return wrapMessage(type: .clipboardGrab, payload: payload, port: port)
    }

    /// Builds a `CLIPBOARD_REQUEST` message asking the peer for clipboard data.
    static func buildClipboardRequest(type: SpiceClipboardType, port: UInt32 = SpiceConstants.serverPort) -> Data {
        var payload = Data(capacity: 4)
        payload.appendLittleEndian(type.rawValue)
        return wrapMessage(type: .clipboardRequest, payload: payload, port: port)
    }

    /// Builds a `CLIPBOARD` message delivering clipboard data to the peer.
    static func buildClipboardData(type: SpiceClipboardType, data clipboardData: Data, port: UInt32 = SpiceConstants.serverPort) -> Data {
        var payload = Data(capacity: 4 + clipboardData.count)
        payload.appendLittleEndian(type.rawValue)
        payload.append(clipboardData)
        return wrapMessage(type: .clipboard, payload: payload, port: port)
    }

    /// Builds a `CLIPBOARD_RELEASE` message.
    static func buildClipboardRelease(port: UInt32 = SpiceConstants.serverPort) -> Data {
        wrapMessage(type: .clipboardRelease, payload: Data(), port: port)
    }

    // MARK: - Private

    private static func wrapMessage(type: SpiceAgentMessageType, payload: Data, port: UInt32) -> Data {
        let header = VDAgentMessageHeader(
            type: type,
            opaque: 0,
            dataSize: UInt32(payload.count)
        )

        let chunkPayload = header.serialize() + payload
        let chunk = VDIChunkHeader(
            port: port,
            dataSize: UInt32(chunkPayload.count)
        )

        return chunk.serialize() + chunkPayload
    }

    private static func setCapability(_ caps: inout UInt32, _ cap: SpiceAgentCapability) {
        caps |= 1 << UInt32(cap.rawValue)
    }

    /// Checks whether a capability bit is set in a capabilities array.
    static func hasCapability(_ caps: [UInt32], _ cap: SpiceAgentCapability) -> Bool {
        let wordIndex = cap.rawValue / 32
        let bitIndex = cap.rawValue % 32
        guard wordIndex < caps.count else { return false }
        return (caps[wordIndex] & (1 << UInt32(bitIndex))) != 0
    }
}

// MARK: - Message Parser

/// Parsed representation of an inbound SPICE agent message.
enum SpiceAgentParsedMessage: Sendable {
    case announceCapabilities(request: Bool, caps: [UInt32])
    case clipboardGrab(types: [SpiceClipboardType])
    case clipboardRequest(type: SpiceClipboardType)
    case clipboardData(type: SpiceClipboardType, data: Data)
    case clipboardRelease
    case other(type: SpiceAgentMessageType)
    /// Inner header could not be parsed (unknown type, truncated payload, etc.).
    case malformedChunk
}

/// Incremental parser for the SPICE agent protocol stream.
///
/// Handles byte-stream fragmentation: a single pipe read may deliver partial
/// VDI chunks, and multiple complete chunks may arrive in a single read.
/// Each VDI chunk is expected to contain a complete VDAgent message.
struct SpiceAgentParser: Sendable {

    private var buffer = Data()

    /// Maximum buffer size before the parser resets (guards against malformed streams).
    private static let maxBufferSize = 1_048_576  // 1 MB

    /// Maximum chunk data size we'll accept (rejects corrupt headers claiming huge sizes).
    private static let maxChunkDataSize: UInt32 = 1_048_576  // 1 MB

    /// `true` when the buffer was reset due to overflow or corruption.
    /// Consumers should check this after each `feed()` call to log appropriately.
    private(set) var didReset = false

    /// Feed raw bytes from the pipe into the parser.
    /// Returns zero or more fully parsed messages.
    mutating func feed(_ data: Data) -> [SpiceAgentParsedMessage] {
        buffer.append(data)
        didReset = false

        // Guard against unbounded growth from malformed streams
        if buffer.count > Self.maxBufferSize {
            buffer.removeAll()
            didReset = true
            return []
        }

        var messages: [SpiceAgentParsedMessage] = []

        while let message = tryParseNext() {
            messages.append(message)
        }

        return messages
    }

    /// Attempts to parse one complete message from the buffer.
    /// Consumes the bytes on success, leaves the buffer unchanged when incomplete,
    /// or resets it entirely when corruption is detected.
    private mutating func tryParseNext() -> SpiceAgentParsedMessage? {
        // Need at least a VDI chunk header
        guard buffer.count >= VDIChunkHeader.size else { return nil }

        guard let chunkHeader = VDIChunkHeader.deserialize(from: buffer) else { return nil }

        // Reject corrupt chunk headers claiming unreasonable sizes
        guard chunkHeader.dataSize <= Self.maxChunkDataSize else {
            buffer.removeAll()
            didReset = true
            return nil
        }

        let totalChunkSize = VDIChunkHeader.size + Int(chunkHeader.dataSize)
        guard buffer.count >= totalChunkSize else { return nil }

        // Consume the chunk from the buffer (trim in-place to avoid full copy)
        let chunkPayload = buffer.subdata(in: VDIChunkHeader.size..<totalChunkSize)
        buffer.removeSubrange(0..<totalChunkSize)

        // Parse the agent message header from the chunk payload.
        // If the inner header is malformed or has an unknown type, skip the chunk
        // but continue parsing — don't halt the loop.
        guard chunkPayload.count >= VDAgentMessageHeader.size,
              let msgHeader = VDAgentMessageHeader.deserialize(from: chunkPayload) else {
            return .malformedChunk
        }

        let msgData = chunkPayload.count > VDAgentMessageHeader.size
            ? chunkPayload.subdata(in: VDAgentMessageHeader.size..<chunkPayload.count)
            : Data()

        return parseMessageBody(type: msgHeader.type, data: msgData)
    }

    private func parseMessageBody(
        type: SpiceAgentMessageType,
        data: Data
    ) -> SpiceAgentParsedMessage {
        switch type {
        case .announceCapabilities:
            return parseAnnounceCapabilities(data)
        case .clipboardGrab:
            return parseClipboardGrab(data)
        case .clipboardRequest:
            return parseClipboardRequest(data)
        case .clipboard:
            return parseClipboardData(data)
        case .clipboardRelease:
            return .clipboardRelease
        default:
            return .other(type: type)
        }
    }

    private func parseAnnounceCapabilities(_ data: Data) -> SpiceAgentParsedMessage {
        guard let request = data.readLittleEndianUInt32(at: 0) else {
            return .announceCapabilities(request: false, caps: [])
        }
        var caps: [UInt32] = []
        var offset = 4
        while let value = data.readLittleEndianUInt32(at: offset) {
            caps.append(value)
            offset += 4
        }
        return .announceCapabilities(request: request != 0, caps: caps)
    }

    private func parseClipboardGrab(_ data: Data) -> SpiceAgentParsedMessage {
        var types: [SpiceClipboardType] = []
        var offset = 0
        while let raw = data.readLittleEndianUInt32(at: offset) {
            if let type = SpiceClipboardType(rawValue: raw) {
                types.append(type)
            }
            offset += 4
        }
        return .clipboardGrab(types: types)
    }

    private func parseClipboardRequest(_ data: Data) -> SpiceAgentParsedMessage {
        guard let raw = data.readLittleEndianUInt32(at: 0) else {
            return .clipboardRequest(type: .none)
        }
        let type = SpiceClipboardType(rawValue: raw) ?? .none
        return .clipboardRequest(type: type)
    }

    private func parseClipboardData(_ data: Data) -> SpiceAgentParsedMessage {
        guard let raw = data.readLittleEndianUInt32(at: 0) else {
            return .clipboardData(type: .none, data: Data())
        }
        let type = SpiceClipboardType(rawValue: raw) ?? .none
        let clipData = data.count > 4 ? data.subdata(in: 4..<data.count) : Data()
        return .clipboardData(type: type, data: clipData)
    }
}

// MARK: - Data Helpers

extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt64) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32? {
        guard offset + 4 <= count else { return nil }
        return withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }

    func readLittleEndianUInt64(at offset: Int) -> UInt64? {
        guard offset + 8 <= count else { return nil }
        return withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian
        }
    }
}
