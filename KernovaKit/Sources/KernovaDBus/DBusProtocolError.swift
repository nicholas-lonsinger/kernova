/// What makes a signature, a value, or a message invalid under the D-Bus
/// specification, found while parsing, encoding or decoding it.
public enum DBusProtocolError: Error, Hashable, Sendable {
    // Signatures.

    /// A signature over `DBusLimits.maximumSignatureLength` bytes.
    case signatureTooLong(Int)
    /// A byte that is not a type code the specification allows in a signature.
    case unknownTypeCode(UInt8)
    /// A signature that ends inside a type: `a`, `(i`, `a{s`.
    case incompleteType
    /// `()`.
    case emptyStruct
    /// A `)` or `}` with no type open to close.
    case unbalancedSignature
    /// A dict entry anywhere but directly as an array's element type.
    case dictEntryOutsideArray
    /// A dict entry whose key is a container type.
    case dictEntryKeyNotBasic
    /// A dict entry holding other than exactly two types.
    case dictEntryFieldCount
    /// More than 32 nested arrays or 32 nested structs in one signature, or
    /// more than 64 nested containers in one value, variants included.
    case nestingTooDeep
    /// A variant's signature that is not exactly one complete type.
    case notSingleCompleteType

    // Values.

    /// The bytes end before the value does.
    case truncated
    /// An alignment padding byte that is not zero.
    case nonzeroPadding
    /// A BOOLEAN other than 0 or 1.
    case invalidBoolean(UInt32)
    /// A string-like value that is not strict UTF-8.
    case invalidUTF8
    /// A string-like value holding U+0000.
    case embeddedNUL
    /// A string-like value whose terminating byte is not NUL.
    case missingNULTerminator
    /// A string that is not a valid object path.
    case invalidObjectPath(String)
    /// An array whose data is over `DBusLimits.maximumArrayLength` bytes.
    case arrayTooLong(Int)
    /// Bytes left over after the last value of a body.
    case trailingBytes
    /// An array element whose type is not the array's element type.
    case elementTypeMismatch(expected: DBusType, actual: DBusType)
    /// A body whose signature is not the one the caller expected.
    case signatureMismatch(expected: DBusSignature, actual: DBusSignature)

    // Messages.

    /// An endianness byte other than `l` or `B`.
    case invalidByteOrder(UInt8)
    /// A major protocol version other than 1.
    case unsupportedProtocolVersion(UInt8)
    /// A message over `DBusLimits.maximumMessageLength` bytes.
    case messageTooLong(Int)
    /// A message type of 0, which the specification names INVALID.
    case invalidMessageType
    /// A serial of 0.
    case zeroSerial
    /// A message lacking a header field its type requires, by field code.
    case missingHeaderField(UInt8)
    /// A known header field holding a value of the wrong type, or the INVALID
    /// field code 0, by field code.
    case invalidHeaderField(UInt8)
    /// A known header field appearing twice, by field code.
    case duplicateHeaderField(UInt8)
    /// A name that breaks the specification's rules for its kind.
    case invalidName(DBusNameKind, String)
    /// A message that carries Unix file descriptors, which this implementation
    /// never negotiates.
    case unixFDsNotNegotiated
}
