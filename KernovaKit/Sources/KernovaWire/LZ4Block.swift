#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Why `LZ4Block.decompress(_:decompressedSize:ceiling:)` refused a block.
public enum LZ4BlockError: Error, Equatable, Sendable {
    /// The declared size is negative or above the caller's ceiling; nothing was allocated.
    case sizeOutOfRange(declared: Int, ceiling: Int)
    /// The block ends inside a token, a length, its literals or an offset.
    case truncated
    /// A match offset of 0, or one reaching before the start of the output.
    case badOffset
    /// Literals or a match would run past the declared size.
    case outputOverrun
    /// The block ended having produced fewer bytes than the declared size.
    case outputShort
}

/// The LZ4 block format (lz4's `doc/lz4_Block_format.md`), with no frame
/// format around it: the container records each block's decompressed size.
public enum LZ4Block {
    private static let minMatch = 4
    /// The last 5 bytes of a block are always literals.
    private static let lastLiterals = 5
    /// A match starts at least 12 bytes before the end of the block.
    private static let matchStartLimit = 12
    private static let maxOffset = 65_535
    private static let hashBits = 14

    /// `bytes` as one block, or nil when the block would not be smaller than `bytes`.
    public static func compress(_ bytes: Data) -> Data? {
        let count = bytes.count
        // Under 13 bytes the block is all literals, a token longer than the input.
        guard count > matchStartLimit else { return nil }
        // Room for one byte less than the input, so a block that is not smaller
        // stops being written as soon as it overflows.
        let scratch = UnsafeMutableRawBufferPointer.allocate(byteCount: count - 1, alignment: 8)
        defer { scratch.deallocate() }
        guard let written = bytes.withUnsafeBytes({ compress($0, into: scratch) }), let base = scratch.baseAddress
        else { return nil }
        return Data(bytes: base, count: written)
    }

    /// The bytes `block` holds, which must be exactly `decompressedSize` of them.
    ///
    /// - Parameters:
    ///   - block: One LZ4 block.
    ///   - decompressedSize: The size the container records for the block.
    ///   - ceiling: The largest `decompressedSize` the caller accepts; a larger one
    ///     throws before anything is allocated.
    /// - Returns: The decompressed bytes.
    /// - Throws: `LZ4BlockError` when the size is out of range or the block is malformed.
    public static func decompress(_ block: Data, decompressedSize: Int, ceiling: Int) throws(LZ4BlockError) -> Data {
        guard decompressedSize >= 0, decompressedSize <= ceiling else {
            throw .sizeOutOfRange(declared: decompressedSize, ceiling: ceiling)
        }
        // Uninitialized: a block that decodes writes every byte, and one that does not is discarded.
        let storage = UnsafeMutableRawPointer.allocate(byteCount: max(decompressedSize, 1), alignment: 16)
        if let error = block.withUnsafeBytes({ decompress($0, into: storage, count: decompressedSize) }) {
            storage.deallocate()
            throw error
        }
        return Data(
            bytesNoCopy: storage, count: decompressedSize, deallocator: .custom { pointer, _ in pointer.deallocate() })
    }

    // MARK: - Compression

    private static func readUInt32(_ buffer: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
    }

    /// How many bytes from `start` match those from `reference`, stopping at `limit`, compared a word at a time.
    private static func commonPrefix(_ input: UnsafeRawBufferPointer, _ start: Int, _ reference: Int, limit: Int) -> Int
    {
        var length = 0
        while start + length + 8 <= limit {
            let difference =
                input.loadUnaligned(fromByteOffset: start + length, as: UInt64.self)
                ^ input.loadUnaligned(fromByteOffset: reference + length, as: UInt64.self)
            if difference != 0 { return length + UInt64(littleEndian: difference).trailingZeroBitCount / 8 }
            length += 8
        }
        while start + length < limit, input[start + length] == input[reference + length] {
            length += 1
        }
        return length
    }

    private static func hash(_ sequence: UInt32) -> Int {
        Int((sequence &* 2_654_435_761) >> (32 - UInt32(hashBits)))
    }

    /// The bytes written, or nil once the block would not fit `output`.
    private static func compress(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) -> Int? {
        let count = input.count
        let lastMatchStart = count - matchStartLimit
        let matchEndLimit = count - lastLiterals
        var writer = Writer(output: output)
        var anchor = 0
        var position = 0

        return withUnsafeTemporaryAllocation(of: Int32.self, capacity: 1 << hashBits) { table -> Int? in
            table.initialize(repeating: -1)
            while true {
                // Find a match; the stride grows over incompressible stretches.
                var reference = -1
                var attempts = 1 << 6
                while true {
                    guard position <= lastMatchStart else {
                        guard writer.writeLastLiterals(input, from: anchor) else { return nil }
                        return writer.written
                    }
                    let sequence = readUInt32(input, position)
                    let slot = hash(sequence)
                    let candidate = Int(table[slot])
                    table[slot] = Int32(position)
                    if candidate >= 0, position - candidate <= maxOffset, readUInt32(input, candidate) == sequence {
                        reference = candidate
                        break
                    }
                    position += attempts >> 6
                    attempts += 1
                }
                // Extend it backwards over literals not yet emitted, then forwards.
                while position > anchor, reference > 0, input[position - 1] == input[reference - 1] {
                    position -= 1
                    reference -= 1
                }
                let length =
                    minMatch + commonPrefix(input, position + minMatch, reference + minMatch, limit: matchEndLimit)
                guard
                    writer.writeSequence(
                        input, literalsFrom: anchor, to: position, offset: position - reference, matchLength: length)
                else { return nil }
                position += length
                anchor = position
                if position - 2 <= lastMatchStart {
                    table[hash(readUInt32(input, position - 2))] = Int32(position - 2)
                }
            }
        }
    }

    private struct Writer {
        let output: UnsafeMutableRawBufferPointer
        var written = 0

        private static func extensionByteCount(_ value: Int) -> Int {
            value < 15 ? 0 : (value - 15) / 255 + 1
        }

        private mutating func writeExtension(_ value: Int) {
            guard value >= 15 else { return }
            var remaining = value - 15
            while remaining >= 255 {
                output[written] = 255
                written += 1
                remaining -= 255
            }
            output[written] = UInt8(remaining)
            written += 1
        }

        private mutating func writeLiterals(_ input: UnsafeRawBufferPointer, from start: Int, to end: Int) {
            guard end > start, let source = input.baseAddress, let destination = output.baseAddress else { return }
            (destination + written).copyMemory(from: source + start, byteCount: end - start)
            written += end - start
        }

        mutating func writeSequence(
            _ input: UnsafeRawBufferPointer, literalsFrom start: Int, to end: Int, offset: Int, matchLength: Int
        ) -> Bool {
            let literalCount = end - start
            let matchCode = matchLength - minMatch
            let needed =
                1 + Self.extensionByteCount(literalCount) + literalCount + 2 + Self.extensionByteCount(matchCode)
            guard output.count - written >= needed else { return false }
            output[written] = UInt8(min(literalCount, 15) << 4 | min(matchCode, 15))
            written += 1
            writeExtension(literalCount)
            writeLiterals(input, from: start, to: end)
            output[written] = UInt8(truncatingIfNeeded: offset)
            output[written + 1] = UInt8(truncatingIfNeeded: offset >> 8)
            written += 2
            writeExtension(matchCode)
            return true
        }

        mutating func writeLastLiterals(_ input: UnsafeRawBufferPointer, from start: Int) -> Bool {
            let literalCount = input.count - start
            guard output.count - written >= 1 + Self.extensionByteCount(literalCount) + literalCount else {
                return false
            }
            output[written] = UInt8(min(literalCount, 15) << 4)
            written += 1
            writeExtension(literalCount)
            writeLiterals(input, from: start, to: input.count)
            return true
        }
    }

    // MARK: - Decompression

    /// Copies `count` bytes forward eight at a time, writing up to 7 bytes past `destination + count`.
    ///
    /// Sound for a match whose source starts at least 8 bytes before `destination`: each word it reads was
    /// written before it is read.
    private static func copyWords(_ destination: UnsafeMutableRawPointer, from source: UnsafeRawPointer, count: Int) {
        var copied = 0
        repeat {
            destination.storeBytes(
                of: source.loadUnaligned(fromByteOffset: copied, as: UInt64.self), toByteOffset: copied,
                as: UInt64.self)
            copied &+= 8
        } while copied < count
    }

    /// `copyWords(_:from:count:)` sixteen bytes at a time, for a source at least 16 bytes before `destination`;
    /// writes up to 15 bytes past `destination + count`.
    private static func copyWides(_ destination: UnsafeMutableRawPointer, from source: UnsafeRawPointer, count: Int) {
        var copied = 0
        repeat {
            destination.storeBytes(
                of: source.loadUnaligned(fromByteOffset: copied, as: SIMD16<UInt8>.self), toByteOffset: copied,
                as: SIMD16<UInt8>.self)
            copied &+= 16
        } while copied < count
    }

    /// Nil on success. Every read is checked against `input` and every write against the `outputCount` bytes
    /// at `output`; nothing is written past them, and on success every one of them was written.
    private static func decompress(
        _ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawPointer, count outputEnd: Int
    ) -> LZ4BlockError? {
        guard let inputBase = input.baseAddress else { return .truncated }
        let inputEnd = input.count
        var source = 0
        var destination = 0

        /// Adds a length's extension bytes, bailing out once it exceeds `limit`.
        func readExtension(_ value: inout Int, limit: Int) -> LZ4BlockError? {
            while true {
                guard source < inputEnd else { return .truncated }
                let byte = Int(inputBase.load(fromByteOffset: source, as: UInt8.self))
                source += 1
                value += byte
                guard value <= limit else { return .outputOverrun }
                if byte != 255 { return nil }
            }
        }

        while true {
            guard source < inputEnd else { return .truncated }
            let token = Int(inputBase.load(fromByteOffset: source, as: UInt8.self))
            source += 1

            var literalCount = token >> 4
            if literalCount == 15, let error = readExtension(&literalCount, limit: outputEnd) { return error }
            guard literalCount <= inputEnd - source else { return .truncated }
            guard literalCount <= outputEnd - destination else { return .outputOverrun }
            if literalCount <= 16, inputEnd - source >= 16, outputEnd - destination >= 16 {
                copyWords(output + destination, from: inputBase + source, count: 16)
            } else if literalCount > 0 {
                (output + destination).copyMemory(from: inputBase + source, byteCount: literalCount)
            }
            source += literalCount
            destination += literalCount

            // The last sequence is literals alone.
            if source == inputEnd {
                return destination == outputEnd ? nil : .outputShort
            }

            guard inputEnd - source >= 2 else { return .truncated }
            let offset =
                Int(inputBase.load(fromByteOffset: source, as: UInt8.self))
                | Int(inputBase.load(fromByteOffset: source + 1, as: UInt8.self)) << 8
            source += 2
            guard offset > 0, offset <= destination else { return .badOffset }

            var matchLength = token & 15
            if matchLength == 15, let error = readExtension(&matchLength, limit: outputEnd) { return error }
            matchLength += minMatch
            guard matchLength <= outputEnd - destination else { return .outputOverrun }
            let target = output + destination
            if matchLength <= 18, offset >= 8, outputEnd - destination >= 24 {
                // The common short match, a fixed 24 bytes with no loop.
                copyWords(target, from: target - offset, count: 24)
            } else if offset >= 16, matchLength <= 64 || offset < matchLength,
                outputEnd - destination - matchLength >= 16
            {
                copyWides(target, from: target - offset, count: matchLength)
            } else if offset >= 8, matchLength <= 64 || offset < matchLength, outputEnd - destination - matchLength >= 8
            {
                copyWords(target, from: target - offset, count: matchLength)
            } else if offset >= matchLength {
                target.copyMemory(from: target - offset, byteCount: matchLength)
            } else {
                // The match overlaps the bytes it produces, so it repeats the `offset` bytes before it. Each copy
                // doubles what has been produced, reading only bytes already written.
                var copied = 0
                while copied < matchLength {
                    let chunk = min(copied + offset, matchLength - copied)
                    (target + copied).copyMemory(from: target - offset, byteCount: chunk)
                    copied += chunk
                }
            }
            destination += matchLength
        }
    }
}
