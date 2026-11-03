#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaFileTree

/// A new regular file's bytes, appended in order, each run of zeros the producer declared as one left a hole
/// wherever it covers whole hole-sized blocks.
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

    /// Appends `bytes`.
    mutating func append(_ bytes: UnsafeRawBufferPointer) throws(TreeFileSystemError) {
        var written = 0
        while written < bytes.count {
            written += try fileSystem.write(
                descriptor, from: UnsafeRawBufferPointer(rebasing: bytes[written...]), at: length + Int64(written))
        }
        length += Int64(written)
        punchSkipped()
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
        skipped = (skipped?.lowerBound ?? holeStart)..<holeEnd
        length = holeEnd
        try writeZeros(end - holeEnd)
    }

    /// Ends the file at the bytes appended, which skipped zeros leave it short of.
    mutating func finish() throws(TreeFileSystemError) {
        guard skipped != nil else { return }
        try fileSystem.setSize(of: descriptor, to: length)
        punchSkipped()
    }

    private mutating func writeZeros(_ count: Int64) throws(TreeFileSystemError) {
        var remaining = count
        while remaining > 0 {
            let piece = Int(min(remaining, Int64(zeroBlock.count)))
            try append(zeroBlock.prefix(piece))
            remaining -= Int64(piece)
        }
    }

    private mutating func punchSkipped() {
        guard let run = skipped else { return }
        skipped = nil
        // The run already reads as zeros, so a volume refusing the hole leaves the file whole, only larger.
        try? fileSystem.punchHole(in: descriptor, at: run.lowerBound, length: run.upperBound - run.lowerBound)
    }
}

/// The zeros ``SparseFile`` writes where it makes no hole.
private let zeroBlock = Data(count: 64 * 1024)
