/// The four message types the specification defines.
public enum DBusMessageKind: UInt8, Sendable, Hashable {
    /// METHOD_CALL.
    case methodCall = 1
    /// METHOD_RETURN.
    case methodReturn = 2
    /// ERROR.
    case error = 3
    /// SIGNAL.
    case signal = 4
}

/// A message header's flags byte; bits the specification does not define are
/// dropped on decode, as it says they must be ignored.
public struct DBusMessageFlags: OptionSet, Sendable, Hashable {
    /// The byte.
    public let rawValue: UInt8

    /// Flags from their byte.
    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// NO_REPLY_EXPECTED.
    public static let noReplyExpected = DBusMessageFlags(rawValue: 0x1)
    /// NO_AUTO_START.
    public static let noAutoStart = DBusMessageFlags(rawValue: 0x2)
    /// ALLOW_INTERACTIVE_AUTHORIZATION.
    public static let allowInteractiveAuthorization = DBusMessageFlags(rawValue: 0x4)

    static let defined: DBusMessageFlags = [.noReplyExpected, .noAutoStart, .allowInteractiveAuthorization]
}

/// What a message's header says about it, short of its serial and body
/// signature: the fields the sender chooses.
public struct DBusMessageHeader: Sendable, Hashable {
    /// The message type.
    public var kind: DBusMessageKind
    /// The flags.
    public var flags: DBusMessageFlags = []
    /// PATH: the object called, or the one a signal comes from.
    public var path: DBusObjectPath?
    /// INTERFACE.
    public var interface: String?
    /// MEMBER: the method or signal name.
    public var member: String?
    /// ERROR_NAME.
    public var errorName: String?
    /// REPLY_SERIAL: the serial of the call this message answers.
    public var replySerial: UInt32?
    /// DESTINATION.
    public var destination: String?
    /// SENDER, which a message bus sets on everything it relays.
    public var sender: String?

    /// A header of `kind` with no fields.
    public init(kind: DBusMessageKind) {
        self.kind = kind
    }

    /// Throws unless every name is valid and the fields `kind` requires are
    /// present.
    func validate() throws(DBusProtocolError) {
        let names: [(String?, DBusNameKind)] = [
            (interface, .interface), (member, .member), (errorName, .error), (destination, .bus), (sender, .bus),
        ]
        for case (let name?, let nameKind) in names where !nameKind.isValid(name) {
            throw .invalidName(nameKind, name)
        }
        switch kind {
        case .methodCall:
            guard path != nil else { throw .missingHeaderField(HeaderField.path) }
            guard member != nil else { throw .missingHeaderField(HeaderField.member) }
        case .signal:
            guard path != nil else { throw .missingHeaderField(HeaderField.path) }
            guard interface != nil else { throw .missingHeaderField(HeaderField.interface) }
            guard member != nil else { throw .missingHeaderField(HeaderField.member) }
        case .error:
            guard errorName != nil else { throw .missingHeaderField(HeaderField.errorName) }
            guard replySerial != nil else { throw .missingHeaderField(HeaderField.replySerial) }
        case .methodReturn:
            guard replySerial != nil else { throw .missingHeaderField(HeaderField.replySerial) }
        }
    }
}

/// The header field codes.
enum HeaderField {
    static let path: UInt8 = 1
    static let interface: UInt8 = 2
    static let member: UInt8 = 3
    static let errorName: UInt8 = 4
    static let replySerial: UInt8 = 5
    static let destination: UInt8 = 6
    static let sender: UInt8 = 7
    static let signature: UInt8 = 8
    static let unixFDs: UInt8 = 9
}

/// A message to send: a header and the values of its body.
public struct DBusMessage: Sendable, Hashable {
    /// The header.
    public var header: DBusMessageHeader
    /// The body's values; their types make the body's signature.
    public var body: [DBusValue]

    /// A message of `header` and `body`.
    public init(header: DBusMessageHeader, body: [DBusValue] = []) {
        self.header = header
        self.body = body
    }

    /// A method call.
    public static func methodCall(
        destination: String?, path: DBusObjectPath, interface: String?, member: String, body: [DBusValue] = []
    ) -> DBusMessage {
        var header = DBusMessageHeader(kind: .methodCall)
        header.destination = destination
        header.path = path
        header.interface = interface
        header.member = member
        return DBusMessage(header: header, body: body)
    }

    /// A signal from `path`.
    public static func signal(
        path: DBusObjectPath, interface: String, member: String, body: [DBusValue] = []
    ) -> DBusMessage {
        var header = DBusMessageHeader(kind: .signal)
        header.path = path
        header.interface = interface
        header.member = member
        return DBusMessage(header: header, body: body)
    }

    /// The method return answering `call`.
    public static func methodReturn(replyingTo call: DBusReceivedMessage, body: [DBusValue] = []) -> DBusMessage {
        var header = DBusMessageHeader(kind: .methodReturn)
        header.replySerial = call.serial
        header.destination = call.header.sender
        return DBusMessage(header: header, body: body)
    }

    /// The error answering `call`, its body the conventional human-readable
    /// message.
    public static func error(replyingTo call: DBusReceivedMessage, name: String, message: String) -> DBusMessage {
        var header = DBusMessageHeader(kind: .error)
        header.replySerial = call.serial
        header.destination = call.header.sender
        header.errorName = name
        return DBusMessage(header: header, body: [.string(message)])
    }

    /// The message's bytes, with `serial`.
    ///
    /// A body holding a UNIX_FD is refused: no descriptors are ever sent beside
    /// a message, so its index could name none.
    public func encoded(serial: UInt32, byteOrder: DBusByteOrder = .littleEndian) throws(DBusProtocolError) -> [UInt8] {
        guard serial != 0 else { throw .zeroSerial }
        try header.validate()
        let signature = try DBusSignature(body.map(\.type))
        guard !signature.bytes.contains(UInt8(ascii: "h")) else { throw .unixFDsNotNegotiated }

        var bodyWriter = DBusWriter(byteOrder: byteOrder)
        for value in body {
            try bodyWriter.write(value, depth: 0)
        }

        var writer = DBusWriter(byteOrder: byteOrder)
        writer.bytes = [byteOrder.rawValue, header.kind.rawValue, header.flags.rawValue, 1]
        writer.write(UInt32(0))  // The body length, patched below.
        writer.write(serial)
        writer.write(UInt32(0))  // The field array's length, patched below.
        let fieldsStart = writer.bytes.count
        func field(_ code: UInt8, _ value: DBusValue) throws(DBusProtocolError) {
            writer.pad(to: 8)
            writer.bytes.append(code)
            writer.writeSignature(try DBusSignature([value.type]))
            try writer.write(value, depth: 3)
        }
        if let path = header.path { try field(HeaderField.path, .objectPath(path)) }
        if let interface = header.interface { try field(HeaderField.interface, .string(interface)) }
        if let member = header.member { try field(HeaderField.member, .string(member)) }
        if let errorName = header.errorName { try field(HeaderField.errorName, .string(errorName)) }
        if let replySerial = header.replySerial { try field(HeaderField.replySerial, .uint32(replySerial)) }
        if let destination = header.destination { try field(HeaderField.destination, .string(destination)) }
        if let sender = header.sender { try field(HeaderField.sender, .string(sender)) }
        if !signature.types.isEmpty { try field(HeaderField.signature, .signature(signature)) }
        let fieldsLength = writer.bytes.count - fieldsStart
        writer.pad(to: 8)

        let total = writer.bytes.count + bodyWriter.bytes.count
        guard total <= DBusLimits.maximumMessageLength else { throw .messageTooLong(total) }
        writer.bytes.replaceSubrange(4..<8, with: Self.uint32Bytes(bodyWriter.bytes.count, byteOrder))
        writer.bytes.replaceSubrange(12..<16, with: Self.uint32Bytes(fieldsLength, byteOrder))
        return writer.bytes + bodyWriter.bytes
    }

    private static func uint32Bytes(_ value: Int, _ byteOrder: DBusByteOrder) -> [UInt8] {
        let ordered = byteOrder == .littleEndian ? UInt32(value).littleEndian : UInt32(value).bigEndian
        return withUnsafeBytes(of: ordered) { Array($0) }
    }
}

/// A message as received: its header, serial and body signature decoded, its
/// body validated but kept as bytes until `decodeBody()` asks for it.
///
/// Keeping the body as bytes holds a message's memory to its size, where
/// decoded values cost many times that, so a peer's large message costs
/// little unless it is read.
public struct DBusReceivedMessage: Sendable, Hashable {
    /// The fields the sender chose.
    public let header: DBusMessageHeader
    /// The sender's serial for it.
    public let serial: UInt32
    /// The body's signature.
    public let signature: DBusSignature
    let byteOrder: DBusByteOrder
    let body: [UInt8]

    /// The body's values.
    public func decodeBody() throws(DBusProtocolError) -> [DBusValue] {
        try DBusMarshal.decode(body, signature: signature, byteOrder: byteOrder)
    }

    /// The body's values, if its signature is `expected`.
    public func decodeBody(expecting expected: DBusSignature) throws(DBusProtocolError) -> [DBusValue] {
        guard signature == expected else { throw .signatureMismatch(expected: expected, actual: signature) }
        return try decodeBody()
    }

    /// The error this message carries: its name, and the first argument when
    /// that is a string, as the specification makes it the human-readable
    /// message. Nil unless this is an ERROR.
    public var remoteError: DBusRemoteError? {
        guard header.kind == .error, let name = header.errorName else { return nil }
        var text = ""
        if signature.types.first == .string, case .string(let first)? = try? decodeBody().first {
            text = first
        }
        return DBusRemoteError(name: name, message: text)
    }

    /// The bytes a message needs, from its first 16: the fixed header and the
    /// field array's length. Throws as soon as those bytes show the message
    /// is invalid or over the size limit.
    static func length(fixedHeader bytes: ArraySlice<UInt8>) throws(DBusProtocolError) -> Int {
        let start = bytes.startIndex
        guard let byteOrder = DBusByteOrder(rawValue: bytes[start]) else {
            throw .invalidByteOrder(bytes[start])
        }
        guard bytes[start + 3] == 1 else { throw .unsupportedProtocolVersion(bytes[start + 3]) }
        var reader = DBusReader(bytes: Array(bytes.prefix(16)), base: 0, end: 16, byteOrder: byteOrder)
        reader.index = 4
        let bodyLength = Int(try reader.read(UInt32.self))
        reader.index = 12
        let fieldsLength = Int(try reader.read(UInt32.self))
        guard fieldsLength <= DBusLimits.maximumArrayLength else { throw .arrayTooLong(fieldsLength) }
        let headerLength = (16 + fieldsLength + 7) & ~7
        let total = headerLength + bodyLength
        guard total <= DBusLimits.maximumMessageLength else { throw .messageTooLong(total) }
        return total
    }

    /// Decodes one whole message: header and body are validated in full.
    /// Returns nil for a message type the specification does not define,
    /// which it says must be ignored.
    public static func decode(_ bytes: [UInt8]) throws(DBusProtocolError) -> DBusReceivedMessage? {
        guard bytes.count >= 16 else { throw .truncated }
        let length = try length(fixedHeader: bytes[0..<16])
        guard bytes.count >= length else { throw .truncated }
        guard bytes.count == length else { throw .trailingBytes }
        // `length(fixedHeader:)` accepted the byte order.
        let byteOrder: DBusByteOrder = bytes[0] == DBusByteOrder.bigEndian.rawValue ? .bigEndian : .littleEndian
        let typeByte = bytes[1]
        guard typeByte != 0 else { throw .invalidMessageType }
        let flags = DBusMessageFlags(rawValue: bytes[2]).intersection(.defined)

        var reader = DBusReader(bytes: bytes, base: 0, end: bytes.count, byteOrder: byteOrder)
        reader.index = 8
        let serial = try reader.read(UInt32.self)
        guard serial != 0 else { throw .zeroSerial }
        let fieldsLength = Int(try reader.read(UInt32.self))
        let fieldsEnd = 16 + fieldsLength
        reader.end = fieldsEnd

        var fields: [UInt8: DBusValue] = [:]
        while reader.index < fieldsEnd {
            try reader.align(8)
            let code = try reader.readByte()
            let signature = try reader.readSignature()
            guard signature.types.count == 1 else { throw .notSingleCompleteType }
            let type = signature.types[0]
            guard let expected = Self.fieldType(code) else {
                if code == 0 { throw .invalidHeaderField(0) }
                // An unknown field, which the specification says to accept and ignore.
                try reader.skip(type, depth: 3)
                continue
            }
            guard type == expected else { throw .invalidHeaderField(code) }
            guard fields[code] == nil else { throw .duplicateHeaderField(code) }
            fields[code] = try reader.read(type, depth: 3)
        }
        reader.end = bytes.count
        try reader.align(8)

        let signature: DBusSignature
        if case .signature(let declared)? = fields[HeaderField.signature] {
            signature = declared
        } else {
            signature = .empty
        }
        if case .uint32(let count)? = fields[HeaderField.unixFDs], count > 0 {
            throw .unixFDsNotNegotiated
        }
        let bodyStart = reader.index
        var bodyReader = DBusReader(bytes: bytes, base: bodyStart, end: bytes.count, byteOrder: byteOrder)
        for type in signature.types {
            try bodyReader.skip(type, depth: 0)
        }
        guard bodyReader.index == bytes.count else { throw .trailingBytes }

        guard let kind = DBusMessageKind(rawValue: typeByte) else { return nil }
        var header = DBusMessageHeader(kind: kind)
        header.flags = flags
        if case .objectPath(let path)? = fields[HeaderField.path] { header.path = path }
        if case .string(let text)? = fields[HeaderField.interface] { header.interface = text }
        if case .string(let text)? = fields[HeaderField.member] { header.member = text }
        if case .string(let text)? = fields[HeaderField.errorName] { header.errorName = text }
        if case .uint32(let number)? = fields[HeaderField.replySerial] { header.replySerial = number }
        if case .string(let text)? = fields[HeaderField.destination] { header.destination = text }
        if case .string(let text)? = fields[HeaderField.sender] { header.sender = text }
        try header.validate()
        return DBusReceivedMessage(
            header: header, serial: serial, signature: signature, byteOrder: byteOrder,
            body: Array(bytes[bodyStart...]))
    }

    private static func fieldType(_ code: UInt8) -> DBusType? {
        switch code {
        case HeaderField.path: .objectPath
        case HeaderField.interface, HeaderField.member, HeaderField.errorName, HeaderField.destination,
            HeaderField.sender:
            .string
        case HeaderField.replySerial, HeaderField.unixFDs: .uint32
        case HeaderField.signature: .signature
        default: nil
        }
    }
}

/// An ERROR reply's name and message.
public struct DBusRemoteError: Error, Sendable, Hashable {
    /// The error name, as `org.freedesktop.DBus.Error.AccessDenied`.
    public var name: String
    /// The human-readable message, empty when the reply carried none.
    public var message: String

    /// An error of `name` and `message`.
    public init(name: String, message: String) {
        self.name = name
        self.message = message
    }
}
