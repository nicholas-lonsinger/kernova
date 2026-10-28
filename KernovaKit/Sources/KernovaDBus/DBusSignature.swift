/// The D-Bus specification's size and depth limits.
public enum DBusLimits {
    /// The most bytes a signature holds.
    public static let maximumSignatureLength = 255
    /// The most arrays one signature nests, and separately the most structs.
    public static let maximumSignatureNesting = 32
    /// The most containers — arrays, structs and variants — a value nests.
    public static let maximumValueNesting = 64
    /// The most bytes an array's data holds.
    public static let maximumArrayLength = 1 << 26
    /// The most bytes a message holds, header and body together.
    public static let maximumMessageLength = 1 << 27
    /// The most bytes a bus, interface, member or error name holds.
    public static let maximumNameLength = 255
}

/// A valid D-Bus signature: zero or more single complete types.
public struct DBusSignature: Sendable, Hashable, CustomStringConvertible {
    /// The signature of no values.
    public static let empty = DBusSignature(validated: [], bytes: [])

    /// The types, in order.
    public let types: [DBusType]
    /// The signature's bytes, all ASCII.
    let bytes: [UInt8]

    /// The signature as text.
    public var description: String { String(decoding: bytes, as: UTF8.self) }

    /// Parses `text` as a signature.
    public init(_ text: String) throws(DBusProtocolError) {
        try self.init(parsing: Array(text.utf8))
    }

    /// The signature of `types`, validated as though parsed.
    public init(_ types: [DBusType]) throws(DBusProtocolError) {
        var bytes: [UInt8] = []
        for type in types {
            type.appendSignature(to: &bytes)
        }
        try self.init(parsing: bytes)
    }

    init(parsing bytes: [UInt8]) throws(DBusProtocolError) {
        guard bytes.count <= DBusLimits.maximumSignatureLength else {
            throw .signatureTooLong(bytes.count)
        }
        var parser = SignatureParser(bytes: bytes)
        var types: [DBusType] = []
        while parser.index < bytes.count {
            types.append(try parser.completeType(arrayDepth: 0, structDepth: 0))
        }
        self.init(validated: types, bytes: bytes)
    }

    private init(validated types: [DBusType], bytes: [UInt8]) {
        self.types = types
        self.bytes = bytes
    }
}

private struct SignatureParser {
    let bytes: [UInt8]
    var index = 0

    mutating func completeType(arrayDepth: Int, structDepth: Int) throws(DBusProtocolError) -> DBusType {
        guard index < bytes.count else { throw .incompleteType }
        let code = bytes[index]
        index += 1
        if let simple = DBusType.simple(code: code) {
            return simple
        }
        switch code {
        case UInt8(ascii: "a"):
            guard arrayDepth < DBusLimits.maximumSignatureNesting else { throw .nestingTooDeep }
            guard index < bytes.count else { throw .incompleteType }
            guard bytes[index] == UInt8(ascii: "{") else {
                return .array(try completeType(arrayDepth: arrayDepth + 1, structDepth: structDepth))
            }
            index += 1
            return .array(try dictEntry(arrayDepth: arrayDepth + 1, structDepth: structDepth))
        case UInt8(ascii: "("):
            guard structDepth < DBusLimits.maximumSignatureNesting else { throw .nestingTooDeep }
            var fields: [DBusType] = []
            while true {
                guard index < bytes.count else { throw .incompleteType }
                if bytes[index] == UInt8(ascii: ")") {
                    index += 1
                    break
                }
                fields.append(try completeType(arrayDepth: arrayDepth, structDepth: structDepth + 1))
            }
            guard !fields.isEmpty else { throw .emptyStruct }
            return .struct(fields)
        case UInt8(ascii: "{"):
            throw .dictEntryOutsideArray
        case UInt8(ascii: ")"), UInt8(ascii: "}"):
            throw .unbalancedSignature
        default:
            throw .unknownTypeCode(code)
        }
    }

    /// The dict entry whose `{` was just read. The specification bounds arrays
    /// and structs; a dict entry is reached only through an array, so the
    /// array bound holds it.
    private mutating func dictEntry(arrayDepth: Int, structDepth: Int) throws(DBusProtocolError) -> DBusType {
        var fields: [DBusType] = []
        while true {
            guard index < bytes.count else { throw .incompleteType }
            if bytes[index] == UInt8(ascii: "}") {
                index += 1
                break
            }
            fields.append(try completeType(arrayDepth: arrayDepth, structDepth: structDepth))
        }
        guard fields.count == 2 else { throw .dictEntryFieldCount }
        guard fields[0].isBasic else { throw .dictEntryKeyNotBasic }
        return .dictEntry(key: fields[0], value: fields[1])
    }
}

/// A valid D-Bus object path.
public struct DBusObjectPath: Sendable, Hashable, CustomStringConvertible {
    /// `/`.
    public static let root = DBusObjectPath(validated: "/")

    /// The path.
    public let rawValue: String

    /// The path itself.
    public var description: String { rawValue }

    /// `rawValue`, if it is a valid object path.
    public init(_ rawValue: String) throws(DBusProtocolError) {
        guard Self.isValid(rawValue.utf8) else { throw .invalidObjectPath(rawValue) }
        self.rawValue = rawValue
    }

    private init(validated rawValue: String) {
        self.rawValue = rawValue
    }

    static func isValid(_ utf8: some Collection<UInt8>) -> Bool {
        guard utf8.first == UInt8(ascii: "/") else { return false }
        if utf8.count == 1 { return true }
        var elementLength = 0
        for byte in utf8.dropFirst() {
            if byte == UInt8(ascii: "/") {
                guard elementLength > 0 else { return false }
                elementLength = 0
            } else {
                guard DBusNameKind.isNameCharacter(byte) else { return false }
                elementLength += 1
            }
        }
        return elementLength > 0
    }
}

/// A signature spelled in code. A literal that is not a valid signature traps:
/// it is a programming error, and the first run that reaches it finds it.
extension DBusSignature: ExpressibleByStringLiteral {
    /// The signature `value` spells.
    public init(stringLiteral value: String) {
        do {
            try self.init(value)
        } catch {
            preconditionFailure("\(value) is not a valid signature: \(error)")
        }
    }
}

/// An object path spelled in code. A literal that is not a valid path traps:
/// it is a programming error, and the first run that reaches it finds it.
extension DBusObjectPath: ExpressibleByStringLiteral {
    /// The object path `value` spells.
    public init(stringLiteral value: String) {
        do {
            try self.init(value)
        } catch {
            preconditionFailure("\(value) is not a valid object path: \(error)")
        }
    }
}
