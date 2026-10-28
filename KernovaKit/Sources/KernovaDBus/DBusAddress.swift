/// One server address: a transport and its unescaped key-value pairs.
public struct DBusAddress: Sendable, Hashable {
    /// The transport, as `unix`.
    public var transport: String
    /// The keys and their unescaped values.
    public var parameters: [String: String]

    /// An address of `transport` with `parameters`.
    public init(transport: String, parameters: [String: String]) {
        self.transport = transport
        self.parameters = parameters
    }

    /// The addresses in `text`, `;`-separated, in the order a client tries
    /// them.
    public static func parse(_ text: String) throws(DBusAddressError) -> [DBusAddress] {
        var addresses: [DBusAddress] = []
        for entry in text.split(separator: ";", omittingEmptySubsequences: true) {
            guard let colon = entry.firstIndex(of: ":"), colon != entry.startIndex else {
                throw .missingTransport(String(entry))
            }
            var parameters: [String: String] = [:]
            for pair in entry[entry.index(after: colon)...].split(separator: ",", omittingEmptySubsequences: true) {
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else {
                    throw .malformedPair(String(pair))
                }
                let key = String(pair[..<equals])
                guard parameters[key] == nil else { throw .duplicateKey(key) }
                parameters[key] = try unescape(pair[pair.index(after: equals)...])
            }
            addresses.append(DBusAddress(transport: String(entry[..<colon]), parameters: parameters))
        }
        return addresses
    }

    /// The socket a `unix:` address connects to; nil for any other transport,
    /// or a `unix:` address that is listenable only.
    public var unixSocket: UnixSocket? {
        guard transport == "unix" else { return nil }
        if let path = parameters["path"] { return .path(path) }
        if let name = parameters["abstract"] { return .abstract(name) }
        return nil
    }

    /// A Unix domain socket's name.
    public enum UnixSocket: Sendable, Hashable {
        /// A socket in the file system.
        case path(String)
        /// A socket in Linux's abstract namespace.
        case abstract(String)
    }

    private static func unescape(_ value: Substring) throws(DBusAddressError) -> String {
        var bytes: [UInt8] = []
        var utf8 = value.utf8[...]
        while let byte = utf8.popFirst() {
            if byte == UInt8(ascii: "%") {
                guard let high = utf8.popFirst().flatMap(hexValue), let low = utf8.popFirst().flatMap(hexValue)
                else { throw .badEscape(String(value)) }
                bytes.append(high << 4 | low)
            } else {
                guard isOptionallyEscaped(byte) else { throw .unescapedByte(String(value)) }
                bytes.append(byte)
            }
        }
        do throws(DBusProtocolError) {
            try validateUTF8(bytes[...])
        } catch {
            throw .badEscape(String(value))
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `[-0-9A-Za-z_/.\*]`, the bytes a value may hold unescaped.
    private static func isOptionallyEscaped(_ byte: UInt8) -> Bool {
        DBusNameKind.isNameCharacter(byte) || "-/.\\*".utf8.contains(byte)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

/// An address string that breaks the specification's address syntax.
public enum DBusAddressError: Error, Hashable, Sendable {
    /// An entry with no `transport:` prefix.
    case missingTransport(String)
    /// A pair that is not `key=value`.
    case malformedPair(String)
    /// A key given twice in one address.
    case duplicateKey(String)
    /// A `%` not followed by two hex digits, or a value whose bytes are not
    /// UTF-8.
    case badEscape(String)
    /// A byte outside the optionally-escaped set appearing unescaped.
    case unescapedByte(String)
}
