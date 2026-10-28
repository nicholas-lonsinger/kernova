/// A D-Bus value of any type.
///
/// An array names its element type, so an empty one still has a type. A
/// dictionary is an array of `dictEntry` values, as on the wire;
/// `dictionary(key:value:_:)` spells one.
public enum DBusValue: Sendable, Hashable {
    /// BYTE.
    case byte(UInt8)
    /// BOOLEAN.
    case boolean(Bool)
    /// INT16.
    case int16(Int16)
    /// UINT16.
    case uint16(UInt16)
    /// INT32.
    case int32(Int32)
    /// UINT32.
    case uint32(UInt32)
    /// INT64.
    case int64(Int64)
    /// UINT64.
    case uint64(UInt64)
    /// DOUBLE. Equality compares values, so NaN is unequal to itself.
    case double(Double)
    /// STRING. One holding U+0000 cannot be encoded.
    case string(String)
    /// OBJECT_PATH.
    case objectPath(DBusObjectPath)
    /// SIGNATURE.
    case signature(DBusSignature)
    /// UNIX_FD: the index of a descriptor sent beside the message.
    case unixFD(UInt32)
    /// ARRAY of `elementType`.
    indirect case array(elementType: DBusType, [DBusValue])
    /// STRUCT.
    indirect case `struct`([DBusValue])
    /// DICT_ENTRY, valid only as an array element.
    indirect case dictEntry(key: DBusValue, value: DBusValue)
    /// VARIANT.
    indirect case variant(DBusValue)

    /// An array of dict entries: a D-Bus dictionary.
    public static func dictionary(key: DBusType, value: DBusType, _ entries: [(DBusValue, DBusValue)]) -> DBusValue {
        .array(
            elementType: .dictEntry(key: key, value: value),
            entries.map { .dictEntry(key: $0.0, value: $0.1) })
    }

    /// This value's type.
    public var type: DBusType {
        switch self {
        case .byte: .byte
        case .boolean: .boolean
        case .int16: .int16
        case .uint16: .uint16
        case .int32: .int32
        case .uint32: .uint32
        case .int64: .int64
        case .uint64: .uint64
        case .double: .double
        case .string: .string
        case .objectPath: .objectPath
        case .signature: .signature
        case .unixFD: .unixFD
        case .array(let elementType, _): .array(elementType)
        case .struct(let fields): .struct(fields.map(\.type))
        case .dictEntry(let key, let value): .dictEntry(key: key.type, value: value.type)
        case .variant: .variant
        }
    }
}

/// Typed reads of a decoded value, each throwing
/// `DBusValueMismatch` when the value is another type.
extension DBusValue {
    /// The BOOLEAN's value.
    public func boolean() throws(DBusValueMismatch) -> Bool {
        guard case .boolean(let value) = self else { throw DBusValueMismatch(expected: .boolean, actual: type) }
        return value
    }

    /// The UINT32's value.
    public func uint32() throws(DBusValueMismatch) -> UInt32 {
        guard case .uint32(let value) = self else { throw DBusValueMismatch(expected: .uint32, actual: type) }
        return value
    }

    /// The STRING's value.
    public func string() throws(DBusValueMismatch) -> String {
        guard case .string(let value) = self else { throw DBusValueMismatch(expected: .string, actual: type) }
        return value
    }

    /// The OBJECT_PATH's value.
    public func objectPath() throws(DBusValueMismatch) -> DBusObjectPath {
        guard case .objectPath(let value) = self else {
            throw DBusValueMismatch(expected: .objectPath, actual: type)
        }
        return value
    }

    /// The ARRAY's elements, of any element type.
    public func arrayElements() throws(DBusValueMismatch) -> [DBusValue] {
        guard case .array(_, let elements) = self else {
            throw DBusValueMismatch(expected: .array(.variant), actual: type)
        }
        return elements
    }

    /// The STRUCT's fields, of any types.
    public func structFields() throws(DBusValueMismatch) -> [DBusValue] {
        guard case .struct(let fields) = self else { throw DBusValueMismatch(expected: .struct([]), actual: type) }
        return fields
    }

    /// The VARIANT's content.
    public func variantContent() throws(DBusValueMismatch) -> DBusValue {
        guard case .variant(let content) = self else { throw DBusValueMismatch(expected: .variant, actual: type) }
        return content
    }

    /// A dictionary's entries, keyed by their STRING keys, a later duplicate
    /// replacing an earlier one.
    public func stringKeyedEntries() throws(DBusValueMismatch) -> [String: DBusValue] {
        var result: [String: DBusValue] = [:]
        for element in try arrayElements() {
            guard case .dictEntry(.string(let key), let value) = element else {
                throw DBusValueMismatch(expected: .dictEntry(key: .string, value: .variant), actual: element.type)
            }
            result[key] = value
        }
        return result
    }
}

/// A typed read of a `DBusValue` that holds another type. For an array, a
/// struct or a dict entry, `expected` stands for the container kind alone.
public struct DBusValueMismatch: Error, Hashable, Sendable {
    /// The type the read wanted.
    public var expected: DBusType
    /// The value's type.
    public var actual: DBusType

    /// A read wanting `expected` of a value of type `actual`.
    public init(expected: DBusType, actual: DBusType) {
        self.expected = expected
        self.actual = actual
    }
}
