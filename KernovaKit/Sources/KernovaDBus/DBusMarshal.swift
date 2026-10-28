/// A message's byte order, named by its first byte.
public enum DBusByteOrder: UInt8, Sendable, Hashable {
    /// `l`.
    case littleEndian = 0x6C
    /// `B`.
    case bigEndian = 0x42
}

/// The D-Bus marshalling format for a block of values, aligned as though the
/// block starts a message — as a message body does, since a header's length is
/// a multiple of 8.
public enum DBusMarshal {
    /// Encodes `values` in `byteOrder`, validating each against the
    /// specification's rules.
    public static func encode(_ values: [DBusValue], byteOrder: DBusByteOrder) throws(DBusProtocolError) -> [UInt8] {
        _ = try DBusSignature(values.map(\.type))
        var writer = DBusWriter(byteOrder: byteOrder)
        for value in values {
            try writer.write(value, depth: 0)
        }
        return writer.bytes
    }

    /// Decodes `bytes` as values of `signature`'s types in `byteOrder`; every
    /// byte must belong to a value.
    public static func decode(
        _ bytes: [UInt8], signature: DBusSignature, byteOrder: DBusByteOrder
    ) throws(DBusProtocolError) -> [DBusValue] {
        var reader = DBusReader(bytes: bytes, base: 0, end: bytes.count, byteOrder: byteOrder)
        var values: [DBusValue] = []
        values.reserveCapacity(signature.types.count)
        for type in signature.types {
            values.append(try reader.read(type, depth: 0))
        }
        guard reader.index == bytes.count else { throw .trailingBytes }
        return values
    }
}

struct DBusWriter {
    let byteOrder: DBusByteOrder
    var bytes: [UInt8] = []

    init(byteOrder: DBusByteOrder) {
        self.byteOrder = byteOrder
    }

    mutating func pad(to alignment: Int) {
        while bytes.count % alignment != 0 {
            bytes.append(0)
        }
    }

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        pad(to: MemoryLayout<T>.size)
        let ordered = byteOrder == .littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { bytes.append(contentsOf: $0) }
    }

    mutating func writeSignature(_ signature: DBusSignature) {
        bytes.append(UInt8(signature.bytes.count))
        bytes.append(contentsOf: signature.bytes)
        bytes.append(0)
    }

    mutating func writeString(_ utf8: String.UTF8View) throws(DBusProtocolError) {
        guard !utf8.contains(0) else { throw .embeddedNUL }
        guard let length = UInt32(exactly: utf8.count) else { throw .arrayTooLong(utf8.count) }
        write(length)
        bytes.append(contentsOf: utf8)
        bytes.append(0)
    }

    /// Writes `value` nested inside `depth` containers.
    mutating func write(_ value: DBusValue, depth: Int) throws(DBusProtocolError) {
        switch value {
        case .byte(let byte): bytes.append(byte)
        case .boolean(let flag): write(UInt32(flag ? 1 : 0))
        case .int16(let number): write(number)
        case .uint16(let number): write(number)
        case .int32(let number): write(number)
        case .uint32(let number): write(number)
        case .int64(let number): write(number)
        case .uint64(let number): write(number)
        case .double(let number): write(number.bitPattern)
        case .unixFD(let index): write(index)
        case .string(let text): try writeString(text.utf8)
        case .objectPath(let path): try writeString(path.rawValue.utf8)
        case .signature(let signature): writeSignature(signature)
        case .array(let elementType, let elements):
            guard depth < DBusLimits.maximumValueNesting else { throw .nestingTooDeep }
            write(UInt32(0))
            let lengthOffset = bytes.count - 4
            pad(to: elementType.alignment)
            let start = bytes.count
            for element in elements {
                let actual = element.type
                guard actual == elementType else { throw .elementTypeMismatch(expected: elementType, actual: actual) }
                try write(element, depth: depth + 1)
            }
            let length = bytes.count - start
            guard length <= DBusLimits.maximumArrayLength else { throw .arrayTooLong(length) }
            let ordered = byteOrder == .littleEndian ? UInt32(length).littleEndian : UInt32(length).bigEndian
            withUnsafeBytes(of: ordered) { raw in
                for offset in 0..<4 {
                    bytes[lengthOffset + offset] = raw[offset]
                }
            }
        case .struct(let fields):
            guard !fields.isEmpty else { throw .emptyStruct }
            guard depth < DBusLimits.maximumValueNesting else { throw .nestingTooDeep }
            pad(to: 8)
            for field in fields {
                try write(field, depth: depth + 1)
            }
        case .dictEntry(let key, let value):
            // An array's element: the array counted this level.
            pad(to: 8)
            try write(key, depth: depth)
            try write(value, depth: depth)
        case .variant(let content):
            guard depth < DBusLimits.maximumValueNesting else { throw .nestingTooDeep }
            writeSignature(try DBusSignature([content.type]))
            try write(content, depth: depth + 1)
        }
    }
}

/// Reads values from `bytes[index..<end]`, aligning relative to `base`.
///
/// Every read checks the bytes remain before touching them, so malformed
/// input throws and is never read out of bounds.
struct DBusReader {
    let bytes: [UInt8]
    let base: Int
    var end: Int
    let byteOrder: DBusByteOrder
    var index: Int

    init(bytes: [UInt8], base: Int, end: Int, byteOrder: DBusByteOrder) {
        self.bytes = bytes
        self.base = base
        self.end = end
        self.byteOrder = byteOrder
        index = base
    }

    var remaining: Int { end - index }

    mutating func align(_ alignment: Int) throws(DBusProtocolError) {
        let padding = (alignment - (index - base) % alignment) % alignment
        guard padding <= remaining else { throw .truncated }
        for offset in index..<(index + padding) where bytes[offset] != 0 {
            throw .nonzeroPadding
        }
        index += padding
    }

    mutating func readByte() throws(DBusProtocolError) -> UInt8 {
        guard remaining >= 1 else { throw .truncated }
        defer { index += 1 }
        return bytes[index]
    }

    mutating func read<T: FixedWidthInteger>(_: T.Type) throws(DBusProtocolError) -> T {
        let size = MemoryLayout<T>.size
        try align(size)
        guard remaining >= size else { throw .truncated }
        var raw: UInt64 = 0
        for offset in 0..<size {
            let byte = UInt64(bytes[index + offset])
            let shift = byteOrder == .littleEndian ? offset : size - 1 - offset
            raw |= byte << UInt64(8 * shift)
        }
        index += size
        return T(truncatingIfNeeded: raw)
    }

    /// The `length` bytes of a string-like value and its NUL, validated.
    mutating func readText(length: Int) throws(DBusProtocolError) -> Range<Int> {
        guard length < remaining else { throw .truncated }
        let range = index..<(index + length)
        guard bytes[range.upperBound] == 0 else { throw .missingNULTerminator }
        try validateUTF8(bytes[range])
        index = range.upperBound + 1
        return range
    }

    mutating func readSignature() throws(DBusProtocolError) -> DBusSignature {
        let length = Int(try readByte())
        let range = try readText(length: length)
        return try DBusSignature(parsing: Array(bytes[range]))
    }

    /// Reads a value of `type` nested inside `depth` containers.
    mutating func read(_ type: DBusType, depth: Int) throws(DBusProtocolError) -> DBusValue {
        try walk(type, depth: depth, keep: true)
    }

    /// Validates a value of `type` nested inside `depth` containers, keeping
    /// nothing: an array's elements and a string's text are checked and
    /// dropped, so a hostile length costs no more memory than its bytes.
    mutating func skip(_ type: DBusType, depth: Int) throws(DBusProtocolError) {
        _ = try walk(type, depth: depth, keep: false)
    }

    /// The one walk `read` and `skip` share. With `keep` false, a string-like
    /// value comes back empty and a container comes back with no contents.
    private mutating func walk(_ type: DBusType, depth: Int, keep: Bool) throws(DBusProtocolError) -> DBusValue {
        switch type {
        case .byte:
            return .byte(try readByte())
        case .boolean:
            let raw = try read(UInt32.self)
            guard raw <= 1 else { throw .invalidBoolean(raw) }
            return .boolean(raw == 1)
        case .int16: return .int16(try read(Int16.self))
        case .uint16: return .uint16(try read(UInt16.self))
        case .int32: return .int32(try read(Int32.self))
        case .uint32: return .uint32(try read(UInt32.self))
        case .int64: return .int64(try read(Int64.self))
        case .uint64: return .uint64(try read(UInt64.self))
        case .double: return .double(Double(bitPattern: try read(UInt64.self)))
        case .unixFD: return .unixFD(try read(UInt32.self))
        case .string:
            let range = try readText(length: Int(try read(UInt32.self)))
            return .string(keep ? String(decoding: bytes[range], as: UTF8.self) : "")
        case .objectPath:
            let range = try readText(length: Int(try read(UInt32.self)))
            let text = String(decoding: bytes[range], as: UTF8.self)
            return .objectPath(try DBusObjectPath(text))
        case .signature:
            return .signature(try readSignature())
        case .array(let elementType):
            guard depth < DBusLimits.maximumValueNesting else { throw .nestingTooDeep }
            let length = Int(try read(UInt32.self))
            guard length <= DBusLimits.maximumArrayLength else { throw .arrayTooLong(length) }
            try align(elementType.alignment)
            guard length <= remaining else { throw .truncated }
            let outerEnd = end
            end = index + length
            var elements: [DBusValue] = []
            while index < end {
                let element = try walk(elementType, depth: depth + 1, keep: keep)
                if keep {
                    elements.append(element)
                }
            }
            end = outerEnd
            return .array(elementType: elementType, elements)
        case .struct(let fieldTypes):
            guard depth < DBusLimits.maximumValueNesting else { throw .nestingTooDeep }
            try align(8)
            var fields: [DBusValue] = []
            for fieldType in fieldTypes {
                let field = try walk(fieldType, depth: depth + 1, keep: keep)
                if keep {
                    fields.append(field)
                }
            }
            return .struct(fields)
        case .dictEntry(let keyType, let valueType):
            // An array's element: the array counted this level.
            try align(8)
            let key = try walk(keyType, depth: depth, keep: keep)
            let value = try walk(valueType, depth: depth, keep: keep)
            return .dictEntry(key: key, value: value)
        case .variant:
            guard depth < DBusLimits.maximumValueNesting else { throw .nestingTooDeep }
            let signature = try readSignature()
            guard signature.types.count == 1 else { throw .notSingleCompleteType }
            return .variant(try walk(signature.types[0], depth: depth + 1, keep: keep))
        }
    }
}

/// Throws unless `utf8` is strict UTF-8 — no overlong forms, surrogates, or
/// code points above U+10FFFF — holding no U+0000.
func validateUTF8(_ utf8: ArraySlice<UInt8>) throws(DBusProtocolError) {
    var index = utf8.startIndex
    while index < utf8.endIndex {
        let lead = utf8[index]
        if lead < 0x80 {
            guard lead != 0 else { throw .embeddedNUL }
            index += 1
            continue
        }
        let count: Int
        let minimum: UInt32
        var scalar: UInt32
        switch lead {
        case 0xC2...0xDF: (count, minimum, scalar) = (2, 0x80, UInt32(lead & 0x1F))
        case 0xE0...0xEF: (count, minimum, scalar) = (3, 0x800, UInt32(lead & 0x0F))
        case 0xF0...0xF4: (count, minimum, scalar) = (4, 0x1_0000, UInt32(lead & 0x07))
        default: throw .invalidUTF8
        }
        guard utf8.endIndex - index >= count else { throw .invalidUTF8 }
        for offset in 1..<count {
            let continuation = utf8[index + offset]
            guard continuation & 0xC0 == 0x80 else { throw .invalidUTF8 }
            scalar = scalar << 6 | UInt32(continuation & 0x3F)
        }
        guard scalar >= minimum, scalar <= 0x10_FFFF, !(0xD800...0xDFFF).contains(scalar) else {
            throw .invalidUTF8
        }
        index += count
    }
}
