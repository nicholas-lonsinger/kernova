/// A single complete D-Bus type.
///
/// A value of this enum can describe a type no signature allows — an empty
/// struct, a dict entry outside an array; `DBusSignature` is where a type is
/// validated, and every encode goes through one.
public indirect enum DBusType: Sendable, Hashable {
    /// `y`
    case byte
    /// `b`
    case boolean
    /// `n`
    case int16
    /// `q`
    case uint16
    /// `i`
    case int32
    /// `u`
    case uint32
    /// `x`
    case int64
    /// `t`
    case uint64
    /// `d`
    case double
    /// `s`
    case string
    /// `o`
    case objectPath
    /// `g`
    case signature
    /// `h`: an index into the file descriptors sent beside a message.
    case unixFD
    /// `a` followed by the element type.
    case array(DBusType)
    /// `(` the field types `)`.
    case `struct`([DBusType])
    /// `{` key value `}`, only ever an array's element type.
    case dictEntry(key: DBusType, value: DBusType)
    /// `v`
    case variant

    /// Whether this is a basic type, the only kind a dict entry's key may be.
    public var isBasic: Bool {
        switch self {
        case .array, .struct, .dictEntry, .variant: false
        default: true
        }
    }

    /// The boundary, relative to the start of the message, a value of this
    /// type starts on.
    var alignment: Int {
        switch self {
        case .byte, .signature, .variant: 1
        case .int16, .uint16: 2
        case .boolean, .int32, .uint32, .unixFD, .string, .objectPath, .array: 4
        case .int64, .uint64, .double, .struct, .dictEntry: 8
        }
    }

    /// The signature code of a basic type or a variant; nil for the containers
    /// spelled with more than one byte.
    var code: UInt8? {
        switch self {
        case .byte: UInt8(ascii: "y")
        case .boolean: UInt8(ascii: "b")
        case .int16: UInt8(ascii: "n")
        case .uint16: UInt8(ascii: "q")
        case .int32: UInt8(ascii: "i")
        case .uint32: UInt8(ascii: "u")
        case .int64: UInt8(ascii: "x")
        case .uint64: UInt8(ascii: "t")
        case .double: UInt8(ascii: "d")
        case .string: UInt8(ascii: "s")
        case .objectPath: UInt8(ascii: "o")
        case .signature: UInt8(ascii: "g")
        case .unixFD: UInt8(ascii: "h")
        case .variant: UInt8(ascii: "v")
        case .array, .struct, .dictEntry: nil
        }
    }

    /// The basic type or variant a signature code names.
    static func simple(code: UInt8) -> DBusType? {
        switch code {
        case UInt8(ascii: "y"): .byte
        case UInt8(ascii: "b"): .boolean
        case UInt8(ascii: "n"): .int16
        case UInt8(ascii: "q"): .uint16
        case UInt8(ascii: "i"): .int32
        case UInt8(ascii: "u"): .uint32
        case UInt8(ascii: "x"): .int64
        case UInt8(ascii: "t"): .uint64
        case UInt8(ascii: "d"): .double
        case UInt8(ascii: "s"): .string
        case UInt8(ascii: "o"): .objectPath
        case UInt8(ascii: "g"): .signature
        case UInt8(ascii: "h"): .unixFD
        case UInt8(ascii: "v"): .variant
        default: nil
        }
    }

    /// Appends this type's signature, unvalidated.
    func appendSignature(to bytes: inout [UInt8]) {
        switch self {
        case .array(let element):
            bytes.append(UInt8(ascii: "a"))
            element.appendSignature(to: &bytes)
        case .struct(let fields):
            bytes.append(UInt8(ascii: "("))
            for field in fields {
                field.appendSignature(to: &bytes)
            }
            bytes.append(UInt8(ascii: ")"))
        case .dictEntry(let key, let value):
            bytes.append(UInt8(ascii: "{"))
            key.appendSignature(to: &bytes)
            value.appendSignature(to: &bytes)
            bytes.append(UInt8(ascii: "}"))
        default:
            if let code {
                bytes.append(code)
            }
        }
    }
}
