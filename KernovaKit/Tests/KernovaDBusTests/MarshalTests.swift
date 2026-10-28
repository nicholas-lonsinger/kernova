import KernovaDBus
import Testing

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

    @Test("A double's bits survive, NaN included", arguments: byteOrders)
    func doubleBits(byteOrder: DBusByteOrder) throws {
        let nan = Double(bitPattern: 0x7FF8_0000_DEAD_BEEF)
        let bytes = try DBusMarshal.encode([.double(nan)], byteOrder: byteOrder)
        let decoded = try DBusMarshal.decode(bytes, signature: "d", byteOrder: byteOrder)
        guard case .double(let value) = decoded[0] else {
            Issue.record("Decoded \(decoded)")
            return
        }
        #expect(value.bitPattern == nan.bitPattern)
    }

    @Test("The specification's string example: lengths, NULs, and padding before 'bar'")
    func specificationStrings() throws {
        let bytes = try DBusMarshal.encode([.string("foo"), .string("+"), .string("bar")], byteOrder: .littleEndian)
        #expect(
            bytes == [
                0x03, 0, 0, 0, 0x66, 0x6F, 0x6F, 0,
                0x01, 0, 0, 0, 0x2B, 0,
                0, 0,
                0x03, 0, 0, 0, 0x62, 0x61, 0x72, 0,
            ])
    }

    @Test("The specification's array example: an INT64 array pads to 8 after its length")
    func specificationArray() throws {
        let bytes = try DBusMarshal.encode([.array(elementType: .int64, [.int64(5)])], byteOrder: .bigEndian)
        #expect(bytes == [0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5])
    }

    @Test("The specification's variant example: signature, then padding to the value's alignment")
    func specificationVariant() throws {
        let bytes = try DBusMarshal.encode([.variant(.uint64(5))], byteOrder: .bigEndian)
        #expect(bytes == [0x01, 0x74, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5])
    }

    @Test("An empty array still pads to its element's alignment, outside its length")
    func emptyArrayPadding() throws {
        let bytes = try DBusMarshal.encode([.array(elementType: .struct([.byte]), [])], byteOrder: .littleEndian)
        #expect(bytes == [0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test("Structs and dict entries start on 8; padding between elements counts in the length")
    func structAlignment() throws {
        let value = DBusValue.array(elementType: .struct([.byte]), [.struct([.byte(1)]), .struct([.byte(2)])])
        let bytes = try DBusMarshal.encode([.byte(9), value], byteOrder: .littleEndian)
        #expect(
            bytes == [
                9, 0, 0, 0,  // byte, then padding to the length
                9, 0, 0, 0,  // 9 bytes: the first struct, 7 of padding, the second
                1, 0, 0, 0, 0, 0, 0, 0,
                2,
            ])
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

    @Test("Integers are written in the byte order asked for")
    func byteOrderLayout() throws {
        let value = DBusValue.uint32(0x0102_0304)
        #expect(try DBusMarshal.encode([value], byteOrder: .littleEndian) == [4, 3, 2, 1])
        #expect(try DBusMarshal.encode([value], byteOrder: .bigEndian) == [1, 2, 3, 4])
        #expect(
            try DBusMarshal.decode([0xFF, 0xFE], signature: "n", byteOrder: .bigEndian) == [.int16(-2)])
        #expect(
            try DBusMarshal.decode([0xFE, 0xFF], signature: "n", byteOrder: .littleEndian) == [.int16(-2)])
    }

    @Test("Encoding refuses values the specification does not allow")
    func encodeRefusals() {
        #expect(throws: DBusProtocolError.embeddedNUL) {
            try DBusMarshal.encode([.string("a\u{0}b")], byteOrder: .littleEndian)
        }
        #expect(throws: DBusProtocolError.elementTypeMismatch(expected: .int32, actual: .string)) {
            try DBusMarshal.encode([.array(elementType: .int32, [.string("x")])], byteOrder: .littleEndian)
        }
        #expect(throws: DBusProtocolError.emptyStruct) {
            try DBusMarshal.encode([.struct([])], byteOrder: .littleEndian)
        }
        #expect(throws: DBusProtocolError.dictEntryOutsideArray) {
            try DBusMarshal.encode([.dictEntry(key: .string("k"), value: .byte(1))], byteOrder: .littleEndian)
        }
    }

    @Test("An array's data may be 2^26 bytes and no more, encoding and decoding")
    func arrayLengthLimit() throws {
        let limit = DBusLimits.maximumArrayLength
        let atLimit = DBusValue.array(elementType: .uint64, Array(repeating: .uint64(0), count: limit / 8))
        #expect(try DBusMarshal.encode([atLimit], byteOrder: .littleEndian).count == 8 + limit)
        let overLimit = DBusValue.array(elementType: .uint64, Array(repeating: .uint64(0), count: limit / 8 + 1))
        #expect(throws: DBusProtocolError.arrayTooLong(limit + 8)) {
            try DBusMarshal.encode([overLimit], byteOrder: .littleEndian)
        }

        // A declared length over the limit is refused before any data is read.
        let declared = UInt32(limit + 1)
        let header: [UInt8] = [
            UInt8(declared & 0xFF), UInt8(declared >> 8 & 0xFF), UInt8(declared >> 16 & 0xFF), UInt8(declared >> 24),
        ]
        #expect(throws: DBusProtocolError.arrayTooLong(limit + 1)) {
            try DBusMarshal.decode(header, signature: "ay", byteOrder: .littleEndian)
        }
        // At the limit, the length is accepted and the missing data is what fails.
        let atLimitHeader: [UInt8] = [4, 0, 0, 0]
        #expect(throws: DBusProtocolError.truncated) {
            try DBusMarshal.decode(atLimitHeader, signature: "ay", byteOrder: .bigEndian)
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
