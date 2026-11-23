import Testing

@testable import KernovaDBus

@Suite("DBusMarshal round trips, alignment and byte order")
struct MarshalTests {
    static let byteOrders: [DBusByteOrder] = [.littleEndian, .bigEndian]

    static let samples: [DBusValue] = [
        .byte(0), .byte(0xFF),
        .boolean(false), .boolean(true),
        .int16(.min), .int16(-1), .int16(.max),
        .uint16(0), .uint16(.max),
        .int32(.min), .int32(.max),
        .uint32(0), .uint32(.max),
        .int64(.min), .int64(.max),
        .uint64(0), .uint64(.max),
        .double(0), .double(-1.5), .double(.infinity), .double(.leastNonzeroMagnitude),
        .string(""), .string("foo"), .string("é"),
        // U+10FFFF and the noncharacter U+FDD0, which the specification allows.
        .string(String(decoding: [0xF4, 0x8F, 0xBF, 0xBF, 0xEF, 0xB7, 0x90], as: UTF8.self)),
        .objectPath("/"), .objectPath("/org/freedesktop/login1"),
        .signature(""), .signature("a{sv}"),
        .unixFD(3),
        .array(elementType: .int64, []),
        .array(elementType: .byte, [.byte(1), .byte(2)]),
        .array(elementType: .string, [.string("a"), .string("bc")]),
        .array(
            elementType: .array(.int16), [.array(elementType: .int16, [.int16(1)]), .array(elementType: .int16, [])]),
        .struct([.byte(1), .uint64(2), .string("three")]),
        .struct([.struct([.byte(1)]), .byte(2)]),
        .dictionary(
            key: .string, value: .variant,
            [(.string("a"), .variant(.int32(1))), (.string("b"), .variant(.string("x")))]),
        .dictionary(key: .uint32, value: .array(.byte), []),
        .variant(.byte(7)),
        .variant(.variant(.uint64(5))),
        .variant(.array(elementType: .struct([.string, .uint32]), [.struct([.string("s"), .uint32(9)])])),
    ]

    @Test("Every value round-trips alone and after a byte", arguments: samples, byteOrders)
    func roundTrip(value: DBusValue, byteOrder: DBusByteOrder) throws {
        for values in [[value], [.byte(0xAB), value], [value, value]] {
            let bytes = try DBusMarshal.encode(values, byteOrder: byteOrder)
            let signature = try DBusSignature(values.map(\.type))
            #expect(try DBusMarshal.decode(bytes, signature: signature, byteOrder: byteOrder) == values)
        }
    }

    @Test("The specification's array example: an INT64 array pads to 8 after its length")
    func specificationArray() throws {
        let bytes = try DBusMarshal.encode([.array(elementType: .int64, [.int64(5)])], byteOrder: .bigEndian)
        #expect(bytes == [0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5])
    }

    @Test("An empty array still pads to its element's alignment, outside its length")
    func emptyArrayPadding() throws {
        let bytes = try DBusMarshal.encode([.array(elementType: .struct([.byte]), [])], byteOrder: .littleEndian)
        #expect(bytes == [0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test("Each fixed type aligns to its size", arguments: byteOrders)
    func fixedAlignment(byteOrder: DBusByteOrder) throws {
        let cases: [(DBusValue, Int)] = [
            (.int16(1), 2), (.uint16(1), 2), (.int32(1), 4), (.uint32(1), 4), (.boolean(true), 4), (.unixFD(1), 4),
            (.int64(1), 8), (.uint64(1), 8), (.double(1), 8), (.string("x"), 4), (.objectPath("/"), 4),
            (.signature("y"), 1), (.variant(.byte(1)), 1),
        ]
        for (value, alignment) in cases {
            let bytes = try DBusMarshal.encode([.byte(1), value], byteOrder: byteOrder)
            let padding = (alignment - 1) % alignment
            #expect(bytes[1..<(1 + padding)].allSatisfy { $0 == 0 }, "\(value)")
            let alone = try DBusMarshal.encode([value], byteOrder: byteOrder)
            #expect(bytes.count == 1 + padding + alone.count, "\(value)")
        }
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
