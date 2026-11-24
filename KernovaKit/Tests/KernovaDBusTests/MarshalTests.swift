import Testing

@testable import KernovaDBus

@Suite("DBusMarshal text, nesting bounds and malformed values")
struct MarshalTests {
    @Test("A string decodes holding every Unicode scalar of a plane but U+0000 and the surrogates", arguments: 0...16)
    func everyScalar(plane: UInt32) throws {
        var scalars = String.UnicodeScalarView()
        for value in (plane << 16)...(plane << 16 | 0xFFFF) where value != 0 {
            if let scalar = Unicode.Scalar(value) { scalars.append(scalar) }
        }
        let text = String(scalars)
        // An `s` as the specification lays it out: a little-endian UINT32 length, the UTF-8, then a NUL.
        let utf8 = Array(text.utf8)
        let length = UInt32(utf8.count)
        let bytes = (0..<4).map { UInt8(truncatingIfNeeded: length >> (8 * $0)) } + utf8 + [0]
        #expect(try DBusMarshal.decode(bytes, signature: "s", byteOrder: .littleEndian) == [.string(text)])
    }

    @Test("Values nest 64 containers deep, variants included, and no deeper")
    func valueNesting() throws {
        func variants(_ depth: Int) -> DBusValue {
            (0..<depth).reduce(DBusValue.byte(1)) { inner, _ in .variant(inner) }
        }
        let deepest = try DBusMarshal.encode([variants(64)], byteOrder: .littleEndian)
        #expect(try DBusMarshal.decode(deepest, signature: "v", byteOrder: .littleEndian) == [variants(64)])
        #expect(throws: DBusProtocolError.nestingTooDeep) {
            try DBusMarshal.encode([variants(65)], byteOrder: .littleEndian)
        }
        // 65 variants, hand-built: 64 whose content is a variant, then one
        // holding a byte.
        var tooDeep: [UInt8] = []
        for _ in 0..<64 {
            tooDeep += [1, UInt8(ascii: "v"), 0]
        }
        tooDeep += [1, UInt8(ascii: "y"), 0, 1]
        #expect(throws: DBusProtocolError.nestingTooDeep) {
            try DBusMarshal.decode(tooDeep, signature: "v", byteOrder: .littleEndian)
        }

        // 32 arrays inside 32 variants reach 64 together.
        let arrays = (0..<32).reduce((DBusValue.byte(1), DBusType.byte)) { inner, _ in
            (.array(elementType: inner.1, [inner.0]), .array(inner.1))
        }
        let mixed = (0..<32).reduce(arrays.0) { inner, _ in .variant(inner) }
        let bytes = try DBusMarshal.encode([mixed], byteOrder: .littleEndian)
        #expect(try DBusMarshal.decode(bytes, signature: "v", byteOrder: .littleEndian) == [mixed])
        #expect(throws: DBusProtocolError.nestingTooDeep) {
            try DBusMarshal.encode([.variant(mixed)], byteOrder: .littleEndian)
        }
    }

    static let malformed: [(String, [UInt8], DBusSignature, DBusProtocolError)] = [
        ("boolean 2", [2, 0, 0, 0], "b", .invalidBoolean(2)),
        ("truncated uint32", [1, 0, 0], "u", .truncated),
        ("nonzero padding", [1, 1, 0, 0, 5, 0, 0, 0], "yu", .nonzeroPadding),
        ("string without its NUL", [1, 0, 0, 0, 0x61], "s", .truncated),
        ("string ending in a non-NUL", [1, 0, 0, 0, 0x61, 0x62], "s", .missingNULTerminator),
        ("embedded NUL", [3, 0, 0, 0, 0x61, 0, 0x62, 0], "s", .embeddedNUL),
        ("overlong UTF-8", [2, 0, 0, 0, 0xC0, 0x80, 0], "s", .invalidUTF8),
        ("surrogate", [3, 0, 0, 0, 0xED, 0xA0, 0x80, 0], "s", .invalidUTF8),
        ("above U+10FFFF", [4, 0, 0, 0, 0xF4, 0x90, 0x80, 0x80, 0], "s", .invalidUTF8),
        ("cut UTF-8 sequence", [2, 0, 0, 0, 0xE2, 0x82, 0], "s", .invalidUTF8),
        ("invalid object path", [2, 0, 0, 0, 0x2F, 0x2F, 0], "o", .invalidObjectPath("//")),
        ("invalid signature", [1, 0x7A, 0], "g", .unknownTypeCode(UInt8(ascii: "z"))),
        ("variant of two types", [2, 0x79, 0x79, 0, 1, 1], "v", .notSingleCompleteType),
        ("variant of none", [0, 0], "v", .notSingleCompleteType),
        ("array overrunning its length", [3, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0], "au", .truncated),
        ("trailing bytes", [1, 0], "y", .trailingBytes),
    ]

    @Test("Malformed values throw their fault", arguments: malformed)
    func rejectsMalformed(name: String, bytes: [UInt8], signature: DBusSignature, error: DBusProtocolError) {
        #expect(throws: error, "\(name)") {
            try DBusMarshal.decode(bytes, signature: signature, byteOrder: .littleEndian)
        }
    }
}
