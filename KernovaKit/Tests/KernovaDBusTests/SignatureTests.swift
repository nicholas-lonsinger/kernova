import KernovaDBus
import Testing

@Suite("DBusSignature parsing")
struct SignatureTests {
    static let invalid: [(String, DBusProtocolError)] = [
        ("a", .incompleteType),
        ("(i", .incompleteType),
        ("a{s", .incompleteType),
        ("a{sv", .incompleteType),
        ("()", .emptyStruct),
        (")", .unbalancedSignature),
        ("i)", .unbalancedSignature),
        ("}", .unbalancedSignature),
        ("{sv}", .dictEntryOutsideArray),
        ("({sv})", .dictEntryOutsideArray),
        ("a{vs}", .dictEntryKeyNotBasic),
        ("a{(i)s}", .dictEntryKeyNotBasic),
        ("a{s}", .dictEntryFieldCount),
        ("a{}", .dictEntryFieldCount),
        ("a{sss}", .dictEntryFieldCount),
        ("r", .unknownTypeCode(UInt8(ascii: "r"))),
        ("e", .unknownTypeCode(UInt8(ascii: "e"))),
        ("m", .unknownTypeCode(UInt8(ascii: "m"))),
        ("*", .unknownTypeCode(UInt8(ascii: "*"))),
        ("?", .unknownTypeCode(UInt8(ascii: "?"))),
        ("@", .unknownTypeCode(UInt8(ascii: "@"))),
        ("&", .unknownTypeCode(UInt8(ascii: "&"))),
        ("^", .unknownTypeCode(UInt8(ascii: "^"))),
        ("z", .unknownTypeCode(UInt8(ascii: "z"))),
    ]

    @Test("Invalid signatures throw their fault", arguments: invalid)
    func rejectsInvalid(text: String, error: DBusProtocolError) {
        #expect(throws: error) { try DBusSignature(text) }
    }
}
