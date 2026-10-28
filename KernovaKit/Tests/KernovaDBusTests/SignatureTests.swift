import KernovaDBus
import Testing

@Suite("DBusSignature parsing and limits")
struct SignatureTests {
    static let valid: [(String, [DBusType])] = [
        ("", []),
        ("y", [.byte]),
        (
            "bnqiuxtdsogh",
            [
                .boolean, .int16, .uint16, .int32, .uint32, .int64, .uint64, .double, .string, .objectPath, .signature,
                .unixFD,
            ]
        ),
        ("v", [.variant]),
        ("ai", [.array(.int32)]),
        ("aai", [.array(.array(.int32))]),
        ("(ii)", [.struct([.int32, .int32])]),
        ("(i(ii))", [.struct([.int32, .struct([.int32, .int32])])]),
        ("a{sv}", [.array(.dictEntry(key: .string, value: .variant))]),
        (
            "a{oa{sa{sv}}}",
            [
                .array(
                    .dictEntry(
                        key: .objectPath,
                        value: .array(
                            .dictEntry(key: .string, value: .array(.dictEntry(key: .string, value: .variant))))
                    ))
            ]
        ),
        ("a(ssssuu)", [.array(.struct([.string, .string, .string, .string, .uint32, .uint32]))]),
        ("sa{sv}as", [.string, .array(.dictEntry(key: .string, value: .variant)), .array(.string)]),
    ]

    @Test("Valid signatures parse to their types and render back", arguments: valid)
    func parsesValid(text: String, types: [DBusType]) throws {
        let signature = try DBusSignature(text)
        #expect(signature.types == types)
        #expect(signature.description == text)
        #expect(try DBusSignature(types) == signature)
    }

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

    @Test("255 bytes is the longest signature")
    func lengthLimit() throws {
        #expect(try DBusSignature(String(repeating: "y", count: 255)).types.count == 255)
        #expect(throws: DBusProtocolError.signatureTooLong(256)) {
            try DBusSignature(String(repeating: "y", count: 256))
        }
    }

    @Test("32 nested arrays parse; 33 do not")
    func arrayNesting() throws {
        #expect(try DBusSignature(String(repeating: "a", count: 32) + "y").types.count == 1)
        #expect(throws: DBusProtocolError.nestingTooDeep) {
            try DBusSignature(String(repeating: "a", count: 33) + "y")
        }
    }

    @Test("32 nested structs parse; 33 do not")
    func structNesting() throws {
        let depth32 = String(repeating: "(", count: 32) + "y" + String(repeating: ")", count: 32)
        #expect(try DBusSignature(depth32).types.count == 1)
        let depth33 = String(repeating: "(", count: 33) + "y" + String(repeating: ")", count: 33)
        #expect(throws: DBusProtocolError.nestingTooDeep) { try DBusSignature(depth33) }
    }

    @Test("Arrays and structs are bounded separately, so 32 of each nest together")
    func combinedNesting() throws {
        let text = String(repeating: "a(", count: 32) + "y" + String(repeating: ")", count: 32)
        #expect(try DBusSignature(text).types.count == 1)
    }

    @Test("A dict entry's array counts toward the array bound")
    func dictEntryNesting() throws {
        let depth32 = String(repeating: "a{s", count: 32) + "y" + String(repeating: "}", count: 32)
        #expect(try DBusSignature(depth32).types.count == 1)
        let depth33 = String(repeating: "a{s", count: 33) + "y" + String(repeating: "}", count: 33)
        #expect(throws: DBusProtocolError.nestingTooDeep) { try DBusSignature(depth33) }
    }

    @Test("A type no signature allows is refused when made into one")
    func refusesInvalidTypes() {
        #expect(throws: DBusProtocolError.emptyStruct) { try DBusSignature([.struct([])]) }
        #expect(throws: DBusProtocolError.dictEntryOutsideArray) {
            try DBusSignature([.dictEntry(key: .string, value: .int32)])
        }
        #expect(throws: DBusProtocolError.dictEntryKeyNotBasic) {
            try DBusSignature([.array(.dictEntry(key: .variant, value: .int32))])
        }
    }

    static let objectPaths: [(String, Bool)] = [
        ("/", true), ("/a", true), ("/org/freedesktop/login1/session/_32", true), ("/A_b/9", true),
        ("", false), ("a", false), ("//", false), ("/a/", false), ("/a//b", false), ("/a-b", false),
        ("/a.b", false), ("/é", false),
    ]

    @Test("Object paths follow the specification's rules", arguments: objectPaths)
    func objectPathRules(text: String, isValid: Bool) {
        #expect(((try? DBusObjectPath(text)) != nil) == isValid)
    }
}
