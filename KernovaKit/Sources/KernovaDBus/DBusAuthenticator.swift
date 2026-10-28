/// The client side of SASL EXTERNAL, the one mechanism this implementation
/// offers: it asserts the process's uid, which the server checks against the
/// socket's peer credentials.
struct DBusAuthenticator: Sendable {
    /// The longest line accepted from the server; the replies this side can
    /// receive are a few dozen bytes.
    static let maximumLineLength = 4096

    enum Step: Equatable, Sendable {
        /// The server accepted; `remainder` is the start of the message stream.
        case authenticated(guid: String, remainder: [UInt8])
        /// Nothing decided yet.
        case pending
    }

    private var line: [UInt8] = []
    /// What to send in reply to lines received so far.
    private(set) var outbound: [UInt8] = []

    /// The credentials-passing NUL byte, then `AUTH EXTERNAL` with `uid` as
    /// ASCII decimal digits, hex-encoded.
    static func opening(uid: UInt32) -> [UInt8] {
        let hex = String(uid).utf8.map { byte in
            let digits = Array("0123456789abcdef".utf8)
            return [digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]]
        }
        return [0] + Array("AUTH EXTERNAL ".utf8) + hex.flatMap { $0 } + Array("\r\n".utf8)
    }

    mutating func takeOutbound() -> [UInt8] {
        defer { outbound = [] }
        return outbound
    }

    /// Reads server lines from `bytes`, until `OK` or the bytes run out.
    mutating func receive(_ bytes: ArraySlice<UInt8>) throws(DBusAuthenticationError) -> Step {
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            index += 1
            guard byte != 0, byte < 0x80 else { throw .invalidLine }
            line.append(byte)
            guard line.count <= Self.maximumLineLength else { throw .invalidLine }
            guard line.count >= 2, line[line.count - 2] == UInt8(ascii: "\r"), byte == UInt8(ascii: "\n") else {
                continue
            }
            let text = String(decoding: line.dropLast(2), as: UTF8.self)
            line = []
            if let guid = try handle(text) {
                return .authenticated(guid: guid, remainder: Array(bytes[index...]))
            }
        }
        return .pending
    }

    /// The GUID when `text` is `OK`; nil when the exchange goes on.
    private mutating func handle(_ text: String) throws(DBusAuthenticationError) -> String? {
        let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        let command = parts[0]
        let argument = parts.count > 1 ? String(parts[1]) : ""
        switch command {
        case "OK":
            let isHex = argument.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                    || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
            }
            guard argument.utf8.count == 32, isHex else { throw .invalidLine }
            return argument
        case "REJECTED":
            throw .rejected(mechanisms: argument.split(separator: " ").map(String.init))
        case "ERROR":
            throw .serverError(argument)
        case "DATA":
            // EXTERNAL with an initial response has no challenge to answer.
            throw .unexpectedCommand(String(command))
        default:
            // The specification's client state machine answers a command it
            // does not know with ERROR and keeps waiting for OK.
            outbound += Array("ERROR\r\n".utf8)
            return nil
        }
    }
}

/// Why the server did not authenticate this side.
public enum DBusAuthenticationError: Error, Hashable, Sendable {
    /// The server refused EXTERNAL; it offers `mechanisms` instead.
    case rejected(mechanisms: [String])
    /// The server sent ERROR.
    case serverError(String)
    /// A command the exchange cannot answer here.
    case unexpectedCommand(String)
    /// A line holding a non-ASCII or NUL byte, over the length limit, or an
    /// `OK` without a 32-digit hex GUID.
    case invalidLine
}
