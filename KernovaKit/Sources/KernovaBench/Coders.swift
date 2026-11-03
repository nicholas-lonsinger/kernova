#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

#if canImport(Compression)
import Compression
#endif
import KernovaWire

/// A block codec under measurement: Kernova's `LZ4Block`, and where the platform has it, Apple's
/// `COMPRESSION_LZ4_RAW`.
enum Coder: String, CaseIterable {
    case swift
    #if canImport(Compression)
    case apple
    #endif

    /// Encodes `block` as one LZ4 block, returning its size, or 0 when it would not come out smaller than `block`.
    ///
    /// `LZ4Block` runs through its public call, allocation included, as the container encoder calls it. Apple's
    /// codec writes into `workspace`'s buffer with its scratch, which is its cheapest use, and is given one byte
    /// less than the input, as `LZ4Block` gives itself.
    func encode(_ block: Data, in workspace: Workspace) -> Int {
        switch self {
        case .swift:
            return LZ4Block.compress(block)?.count ?? 0
        #if canImport(Compression)
        case .apple:
            return block.withUnsafeBytes { input in
                guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(
                    workspace.output, block.count - 1, source, block.count, workspace.encodeScratch,
                    COMPRESSION_LZ4_RAW)
            }
        #endif
        }
    }

    /// Decodes `block` to its `size` bytes, returning the count written, or -1 when it was refused.
    func decode(_ block: Data, size: Int, in workspace: Workspace) -> Int {
        switch self {
        case .swift:
            return (try? LZ4Block.decompress(block, decompressedSize: size, ceiling: size))?.count ?? -1
        #if canImport(Compression)
        case .apple:
            return block.withUnsafeBytes { input in
                guard let source = input.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return compression_decode_buffer(
                    workspace.output, size, source, block.count, workspace.decodeScratch, COMPRESSION_LZ4_RAW)
            }
        #endif
        }
    }

    /// The decoded bytes, for the check that precedes timing.
    func decoded(_ block: Data, size: Int, in workspace: Workspace) -> Data? {
        switch self {
        case .swift:
            return try? LZ4Block.decompress(block, decompressedSize: size, ceiling: size)
        #if canImport(Compression)
        case .apple:
            let written = decode(block, size: size, in: workspace)
            return written == size ? Data(bytes: workspace.output, count: size) : nil
        #endif
        }
    }

    /// The encoded block, or nil when it would not come out smaller, for the check that precedes timing.
    func encoded(_ block: Data, in workspace: Workspace) -> Data? {
        switch self {
        case .swift:
            return LZ4Block.compress(block)
        #if canImport(Compression)
        case .apple:
            let written = encode(block, in: workspace)
            return written == 0 ? nil : Data(bytes: workspace.output, count: written)
        #endif
        }
    }
}

/// One thread's buffers: an output block and Apple's scratch, allocated before timing starts.
///
/// Each workspace is touched by one thread at a time — the one `DispatchQueue.concurrentPerform` hands its
/// index — which is what makes it sendable.
final class Workspace: @unchecked Sendable {
    let output: UnsafeMutablePointer<UInt8>
    let encodeScratch: UnsafeMutableRawPointer?
    let decodeScratch: UnsafeMutableRawPointer?
    /// What the timed work returned, summed and printed so no result is dead code.
    var sink = 0

    init(blockSize: Int) {
        output = .allocate(capacity: blockSize)
        output.initialize(repeating: 0, count: blockSize)
        #if canImport(Compression)
        encodeScratch = .allocate(
            byteCount: compression_encode_scratch_buffer_size(COMPRESSION_LZ4_RAW), alignment: 16)
        decodeScratch = .allocate(
            byteCount: compression_decode_scratch_buffer_size(COMPRESSION_LZ4_RAW), alignment: 16)
        #else
        encodeScratch = nil
        decodeScratch = nil
        #endif
    }

    deinit {
        output.deallocate()
        encodeScratch?.deallocate()
        decodeScratch?.deallocate()
    }
}
