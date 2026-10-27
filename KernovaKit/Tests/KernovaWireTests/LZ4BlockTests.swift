#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import Testing

/// Seeded inputs covering what the encoder must handle: incompressible bytes,
/// text, runs, overlapping repeats, and matches near and past the 64 KiB window.
enum LZ4Corpus {
    struct Input: Sendable, CustomTestStringConvertible {
        var name: String
        var bytes: Data
        /// Whether any sane encoder makes it smaller.
        var compressible: Bool
        var testDescription: String { "\(name) (\(bytes.count) bytes)" }
    }

    static func text(_ count: Int, seed: UInt64) -> Data {
        let words = ["guest", "agent", "frame", "stream", "kernova", "the", "of", "window", "credit", "\n"]
        var generator = SeededGenerator(seed: seed)
        var text = Data()
        while text.count < count {
            text.append(contentsOf: (words.randomElement(using: &generator) ?? "").utf8)
            text.append(0x20)
        }
        return text.prefix(count)
    }

    /// Random stretches interleaved with copies of earlier stretches at offsets
    /// up to and past the 65,535-byte limit.
    static func mixed(_ count: Int, seed: UInt64) -> Data {
        var generator = SeededGenerator(seed: seed)
        var data = generator.bytes(min(count, 300))
        while data.count < count {
            let length = Int.random(in: 1...600, using: &generator)
            if Bool.random(using: &generator) {
                let distance = Int.random(in: 1...min(data.count, 70_000), using: &generator)
                let start = data.count - distance
                for index in 0..<length {
                    data.append(data[start + index])
                }
            } else {
                data.append(generator.bytes(length))
            }
        }
        return data.prefix(count)
    }

    static let inputs: [Input] = {
        var generator = SeededGenerator(seed: 0x4C5A_34)
        var inputs: [Input] = []
        for size in [13, 14, 15, 16, 17, 31, 270, 271, 4_096, 65_536, 65_537, 300_000] {
            inputs.append(Input(name: "zeros", bytes: Data(count: size), compressible: true))
        }
        for size in [13, 20, 64, 1_000, 65_535, 1_048_576] {
            // A handful of words repeats only once the text is long enough.
            inputs.append(Input(name: "text", bytes: text(size, seed: UInt64(size)), compressible: size >= 64))
        }
        for size in [100, 5_000, 200_000, 1_048_576] {
            // The first 300 bytes are random.
            inputs.append(Input(name: "mixed", bytes: mixed(size, seed: UInt64(size)), compressible: size > 300))
        }
        for period in [1, 2, 3, 7, 19] {
            let pattern = generator.bytes(period)
            var bytes = Data()
            while bytes.count < 10_000 { bytes.append(pattern) }
            inputs.append(Input(name: "period \(period)", bytes: bytes, compressible: true))
        }
        // A long literal run, then a long match, then more literals.
        let literals = generator.bytes(5_000)
        inputs.append(
            Input(name: "long literals and match", bytes: literals + literals + generator.bytes(40), compressible: true)
        )
        for size in [0, 1, 12, 13, 100, 70_000, 1_048_576] {
            inputs.append(Input(name: "random", bytes: generator.bytes(size), compressible: false))
        }
        return inputs
    }()
}

@Suite("LZ4 block codec")
struct LZ4BlockTests {
    @Test("Every corpus input round-trips, and compressible ones come out smaller", arguments: LZ4Corpus.inputs)
    func roundTrip(_ input: LZ4Corpus.Input) throws {
        guard let block = LZ4Block.compress(input.bytes) else {
            #expect(!input.compressible)
            return
        }
        #expect(block.count < input.bytes.count)
        let restored = try LZ4Block.decompress(block, decompressedSize: input.bytes.count, ceiling: 1 << 20)
        #expect(restored == input.bytes)
    }

    @Test("Under 13 bytes nothing compresses: the block would be all literals")
    func shortInputs() {
        for count in 0...12 {
            #expect(LZ4Block.compress(Data(count: count)) == nil)
        }
    }

    @Test("Hand-written blocks decode: empty, literals only, an overlapping match, extended lengths")
    func knownBlocks() throws {
        #expect(try LZ4Block.decompress(Data([0x00]), decompressedSize: 0, ceiling: 0) == Data())
        #expect(try LZ4Block.decompress(Data([0x30, 1, 2, 3]), decompressedSize: 3, ceiling: 3) == Data([1, 2, 3]))
        let overlapping = Data([0x15, 0x61, 0x01, 0x00, 0x10, 0x62])
        #expect(try LZ4Block.decompress(overlapping, decompressedSize: 11, ceiling: 64) == Data("aaaaaaaaaab".utf8))
        let literals = Data((0..<273).map { UInt8(truncatingIfNeeded: $0) })
        let extended = Data([0xF0, 0xFF, 0x03]) + literals
        #expect(try LZ4Block.decompress(extended, decompressedSize: 273, ceiling: 273) == literals)
        // 1 literal, then a match of 4 + 15 + 255 + 1 = 275 bytes at offset 1, then 1 literal.
        let longMatch = Data([0x1F, 0x61, 0x01, 0x00, 0xFF, 0x01, 0x10, 0x62])
        #expect(
            try LZ4Block.decompress(longMatch, decompressedSize: 277, ceiling: 277)
                == Data(repeating: 0x61, count: 276) + Data([0x62]))
    }

    struct Malformed: Sendable, CustomTestStringConvertible {
        var name: String
        var block: [UInt8]
        var size: Int
        var error: LZ4BlockError
        var testDescription: String { name }
    }

    static let malformed: [Malformed] = [
        Malformed(name: "empty block", block: [], size: 0, error: .truncated),
        Malformed(name: "literals cut short", block: [0x30, 1, 2], size: 3, error: .truncated),
        Malformed(name: "literal length extension missing", block: [0xF0], size: 20, error: .truncated),
        Malformed(
            name: "literal length extension unterminated", block: [0xF0, 0xFF, 0xFF], size: 1_000, error: .truncated),
        Malformed(
            name: "literal length past the declared size", block: [0xF0] + [UInt8](repeating: 0xFF, count: 20) + [0],
            size: 10, error: .outputOverrun),
        Malformed(name: "literals past the declared size", block: [0x30, 1, 2, 3], size: 2, error: .outputOverrun),
        Malformed(name: "block ends after a match", block: [0x14, 0x61, 0x01, 0x00], size: 9, error: .truncated),
        Malformed(name: "offset cut short", block: [0x14, 0x61, 0x01], size: 9, error: .truncated),
        Malformed(name: "offset zero", block: [0x14, 0x61, 0x00, 0x00, 0x00], size: 9, error: .badOffset),
        Malformed(name: "offset before the output", block: [0x14, 0x61, 0x02, 0x00, 0x00], size: 9, error: .badOffset),
        Malformed(name: "offset with no output yet", block: [0x04, 0x01, 0x00, 0x00], size: 8, error: .badOffset),
        Malformed(
            name: "match length extension missing", block: [0x1F, 0x61, 0x01, 0x00], size: 100, error: .truncated),
        Malformed(
            name: "match length extension unterminated", block: [0x1F, 0x61, 0x01, 0x00, 0xFF], size: 1_000,
            error: .truncated),
        Malformed(
            name: "match length past the declared size",
            block: [0x1F, 0x61, 0x01, 0x00] + [UInt8](repeating: 0xFF, count: 8),
            size: 100, error: .outputOverrun),
        Malformed(
            name: "match past the declared size", block: [0x14, 0x61, 0x01, 0x00, 0x00], size: 5, error: .outputOverrun),
        Malformed(
            name: "sequences after the output is complete", block: [0x10, 0x61, 0x01, 0x00, 0x00], size: 1,
            error: .outputOverrun),
        Malformed(name: "block ends before the declared size", block: [0x30, 1, 2, 3], size: 4, error: .outputShort),
    ]

    @Test("Every malformed shape throws its error", arguments: malformed)
    func rejectsMalformed(_ shape: Malformed) {
        #expect(throws: shape.error) {
            try LZ4Block.decompress(Data(shape.block), decompressedSize: shape.size, ceiling: 1 << 20)
        }
    }

    @Test("A size above the ceiling, or negative, throws before anything is allocated")
    func ceiling() throws {
        #expect(throws: LZ4BlockError.sizeOutOfRange(declared: Int.max, ceiling: 1 << 20)) {
            try LZ4Block.decompress(Data([0x00]), decompressedSize: Int.max, ceiling: 1 << 20)
        }
        #expect(throws: LZ4BlockError.sizeOutOfRange(declared: 4, ceiling: 3)) {
            try LZ4Block.decompress(Data([0x40, 1, 2, 3, 4]), decompressedSize: 4, ceiling: 3)
        }
        #expect(throws: LZ4BlockError.sizeOutOfRange(declared: -1, ceiling: 3)) {
            try LZ4Block.decompress(Data([0x00]), decompressedSize: -1, ceiling: 3)
        }
        #expect(
            try LZ4Block.decompress(Data([0x40, 1, 2, 3, 4]), decompressedSize: 4, ceiling: 4) == Data([1, 2, 3, 4]))
    }

    @Test("Mutated blocks either throw or decode to exactly the declared size")
    func hostileBlocks() throws {
        var generator = SeededGenerator(seed: 0xBAD_B10C)
        let sources = [LZ4Corpus.text(3_000, seed: 1), LZ4Corpus.mixed(3_000, seed: 2)]
        for source in sources {
            let block = try #require(LZ4Block.compress(source))
            for _ in 0..<1_500 {
                var mutated = block
                switch Int.random(in: 0..<3, using: &generator) {
                case 0:
                    for _ in 0...Int.random(in: 0..<4, using: &generator) {
                        let index = Int.random(in: 0..<mutated.count, using: &generator)
                        mutated[index] = UInt8.random(in: 0...255, using: &generator)
                    }
                case 1:
                    mutated = mutated.prefix(Int.random(in: 0..<mutated.count, using: &generator))
                default:
                    mutated.append(generator.bytes(Int.random(in: 1...8, using: &generator)))
                }
                let size = Bool.random(using: &generator) ? source.count : Int.random(in: 0...6_000, using: &generator)
                do {
                    let output = try LZ4Block.decompress(mutated, decompressedSize: size, ceiling: 1 << 16)
                    #expect(output.count == size)
                } catch {
                    // Refusing is the other acceptable outcome.
                }
            }
        }
    }
}
