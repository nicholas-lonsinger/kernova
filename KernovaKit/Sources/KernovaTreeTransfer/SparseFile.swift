#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaFileTree

/// A new regular file's bytes, appended in order, every whole hole-sized block of zeros left a hole —
/// whether a producer declared the zeros as a run or carried them as bytes.
///
/// Skipping a range leaves no hole on APFS, and a punch frees blocks only once the range lies inside the file
/// (docs/research/2026-10-24-receiver-writer-parity.md, findings 6 and 7), so a skipped run is punched once the
/// next write, or the closing size, puts it there. A volume that makes no holes is written every zero.
struct SparseFile<FileSystem: MutableTreeFileSystem> {
    let fileSystem: FileSystem
    let descriptor: Int32
    /// The unit and alignment of a hole; `nil` on a volume that makes none.
    let holeSize: Int?
    /// The bytes written and skipped so far.
    private(set) var length: Int64 = 0
    /// The zeros skipped since the last write, not yet a hole.
    private var skipped: Range<Int64>?

    init(fileSystem: FileSystem, descriptor: Int32, holeSize: Int?) {
        self.fileSystem = fileSystem
        self.descriptor = descriptor
        self.holeSize = holeSize
    }

    /// Appends `bytes`.
    mutating func append(_ bytes: Data) throws(TreeFileSystemError) {
        // `withUnsafeBytes` rethrows untyped, so the failure crosses it as a value.
        var failure: TreeFileSystemError?
        bytes.withUnsafeBytes { buffer in
            do throws(TreeFileSystemError) {
                try append(buffer)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
    }

    /// Appends `bytes`, skipping each run of whole hole-sized blocks of zeros among them.
    mutating func append(_ bytes: UnsafeRawBufferPointer) throws(TreeFileSystemError) {
        guard let holeSize else {
            try write(bytes)
            return
        }
        var start = 0
        while start < bytes.count {
            let intoBlock = Int(length % Int64(holeSize))
            guard intoBlock == 0, bytes.count - start >= holeSize else {
                let end = start + min(bytes.count - start, holeSize - intoBlock)
                try write(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
                start = end
                continue
            }
            let isZero = Self.isZero(bytes, at: start, count: holeSize)
            var end = start + holeSize
            while bytes.count - end >= holeSize, Self.isZero(bytes, at: end, count: holeSize) == isZero {
                end += holeSize
            }
            if isZero {
                skip(Int64(end - start))
            } else {
                try write(UnsafeRawBufferPointer(rebasing: bytes[start..<end]))
            }
            start = end
        }
    }

    /// Appends `count` zero bytes: the whole hole-sized blocks among them skipped, the rest written.
    mutating func appendZeros(_ count: Int64) throws(TreeFileSystemError) {
        guard let holeSize else {
            try writeZeros(count)
            return
        }
        let unit = Int64(holeSize)
        let end = length + count
        let holeStart = (length + unit - 1) / unit * unit
        let holeEnd = end / unit * unit
        guard holeEnd > holeStart else {
            try writeZeros(count)
            return
        }
        try writeZeros(holeStart - length)
        skip(holeEnd - holeStart)
        try writeZeros(end - holeEnd)
    }

    /// Ends the file at the bytes appended, which skipped zeros leave it short of.
    mutating func finish() throws(TreeFileSystemError) {
        guard skipped != nil else { return }
        try fileSystem.setSize(of: descriptor, to: length)
        punchSkipped()
    }

    private mutating func skip(_ count: Int64) {
        skipped = (skipped?.lowerBound ?? length)..<(length + count)
        length += count
    }

    /// Writes `bytes` as they are, then punches the run they put inside the file.
    private mutating func write(_ bytes: UnsafeRawBufferPointer) throws(TreeFileSystemError) {
        var written = 0
        while written < bytes.count {
            written += try fileSystem.write(
                descriptor, from: UnsafeRawBufferPointer(rebasing: bytes[written...]), at: length + Int64(written))
        }
        length += Int64(written)
        punchSkipped()
    }

    private mutating func writeZeros(_ count: Int64) throws(TreeFileSystemError) {
        var remaining = count
        while remaining > 0 {
            let piece = Int(min(remaining, Int64(zeroBlock.count)))
            try write(UnsafeRawBufferPointer(rebasing: zeroBlock[..<piece]))
            remaining -= Int64(piece)
        }
    }

    private mutating func punchSkipped() {
        guard let run = skipped else { return }
        skipped = nil
        // The run already reads as zeros, so a volume refusing the hole leaves the file whole, only larger.
        try? fileSystem.punchHole(in: descriptor, at: run.lowerBound, length: run.upperBound - run.lowerBound)
    }

    /// Whether the `count` bytes of `bytes` at `start` are all zero, read eight words at a time: a
    /// `SIMD64<UInt8>` comparison is 54 times slower (the parity note, finding 9).
    private static func isZero(_ bytes: UnsafeRawBufferPointer, at start: Int, count: Int) -> Bool {
        guard let base = bytes.baseAddress?.advanced(by: start) else { return true }
        var offset = 0
        while count - offset >= 64 {
            var word: UInt64 = 0
            for index in 0..<8 { word |= base.loadUnaligned(fromByteOffset: offset + index * 8, as: UInt64.self) }
            if word != 0 { return false }
            offset += 64
        }
        return UnsafeRawBufferPointer(start: base + offset, count: count - offset).allSatisfy { $0 == 0 }
    }
}

/// The zeros ``SparseFile`` writes where it makes no hole, allocated once and never freed.
private nonisolated(unsafe) let zeroBlock = UnsafeRawBufferPointer(
    UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16).initializeMemory(
        as: UInt8.self, repeating: 0))
