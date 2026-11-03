#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf

/// When the encoder tries LZ4 on a chunk of an entry whose storage is LZ4. A tried chunk is sent as a block
/// only when its record comes out smaller than the raw chunk's.
public struct ChunkCompressionPolicy: Equatable, Sendable {
    /// Whether any chunk is tried.
    public var attemptsLZ4: Bool
    /// After this many tried chunks of one entry in a row that LZ4 did not shrink, the entry's remaining
    /// chunks go raw; nil keeps trying.
    public var abandonAfterUnshrunkChunks: Int?

    /// A policy of the given rules.
    ///
    /// - Parameters:
    ///   - attemptsLZ4: Whether any chunk is tried.
    ///   - abandonAfterUnshrunkChunks: Tried chunks of one entry in a row that did not shrink, after which
    ///     the entry's remaining chunks go raw; nil keeps trying.
    public init(attemptsLZ4: Bool, abandonAfterUnshrunkChunks: Int?) {
        self.attemptsLZ4 = attemptsLZ4
        self.abandonAfterUnshrunkChunks = abandonAfterUnshrunkChunks
    }

    /// Every chunk raw.
    public static let never = ChunkCompressionPolicy(attemptsLZ4: false, abandonAfterUnshrunkChunks: nil)
}

/// Writes a container's records from its entries: `entry(_:)` for each header in depth-first pre-order,
/// `bytes(_:)` for a file's data until it has all it declared and then for its resource fork's, then `end()`.
/// It holds the container to the same rules as `ContainerDecoder`, so what it writes the decoder accepts.
/// After it throws, discard it.
public struct ContainerEncoder {
    /// The most bytes one chunk carries.
    public static let chunkByteCount = 262_144

    private var grammar: ContainerGrammar
    private let policy: ChunkCompressionPolicy
    /// Zero bytes counted and not yet written: consecutive all-zero chunks share one zero run.
    private var pendingZeros: UInt64 = 0
    private var unshrunkChunks = 0
    private var lz4Abandoned = false

    /// An encoder of a container `acceptance` admits, compressing chunks as `policy` allows.
    ///
    /// - Parameters:
    ///   - acceptance: What the pull's destination accepts.
    ///   - policy: When to try LZ4 on a chunk.
    public init(accepting acceptance: ContainerAcceptance, policy: ChunkCompressionPolicy) {
        grammar = ContainerGrammar(acceptance: acceptance)
        self.policy = policy
    }

    /// The header record of the next entry.
    ///
    /// - Parameter header: The entry, at its depth in pre-order.
    /// - Returns: The record's bytes.
    /// - Throws: `ContainerError` when the entry breaks a container rule or its header is too large.
    public mutating func entry(_ header: EntryHeader) throws(ContainerError) -> Data {
        let payload = Self.serialized(header)
        guard ContainerRecordKind.header.payloadLengths.contains(payload.count) else {
            throw .recordLengthOutOfRange(kind: .header, length: payload.count)
        }
        _ = try grammar.admit(header)
        unshrunkChunks = 0
        lz4Abandoned = false
        var records = Data()
        ContainerRecord.append(.header, payload: payload, to: &records)
        return records
    }

    /// The records carrying the current entry's next bytes — its data's, then once those are whole its
    /// resource fork's: one per chunk, with consecutive all-zero chunks as one zero run, written once a
    /// non-zero chunk follows or the data or the fork has all its bytes.
    ///
    /// - Parameter bytes: The entry's next bytes, no more than its data, or its fork, still owes.
    /// - Returns: The records' bytes, possibly none while zeros are pending.
    /// - Throws: `ContainerError` when no entry owes bytes or `bytes` is more than it owes.
    public mutating func bytes(_ bytes: Data) throws(ContainerError) -> Data {
        guard !bytes.isEmpty else { return Data() }
        if let remaining = grammar.owed?.current, UInt64(bytes.count) > remaining {
            throw .chunkPastEntrySize(count: UInt64(bytes.count), remaining: remaining)
        }
        var records = Data()
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = min(start + Self.chunkByteCount, bytes.endIndex)
            let chunk = bytes[start..<end]
            start = end
            if Self.isAllZero(chunk) {
                let progress = try grammar.admitChunk(count: UInt64(chunk.count), lz4: false)
                pendingZeros += UInt64(chunk.count)
                if progress != .continuing { flushZeros(into: &records) }
                continue
            }
            flushZeros(into: &records)
            let (kind, payload) = encodedChunk(chunk)
            _ = try grammar.admitChunk(count: UInt64(chunk.count), lz4: kind == .lz4Chunk)
            ContainerRecord.append(kind, payload: payload, to: &records)
        }
        return records
    }

    /// The end record, stating the container's counts.
    ///
    /// - Returns: The record's bytes.
    /// - Throws: `ContainerError` when the current entry still owes bytes or no entry was written.
    public mutating func end() throws(ContainerError) -> Data {
        var end = EndRecord()
        end.entries = grammar.counted.entries
        end.bytes = grammar.counted.bytes
        _ = try grammar.admitEnd(end)
        var records = Data()
        ContainerRecord.append(.end, payload: Self.serialized(end), to: &records)
        return records
    }

    /// The records carrying the current entry's next `count` bytes, all zero, as a zero run: merged with any
    /// zeros pending, and written once a non-zero chunk follows or the data or the fork has all its bytes. A
    /// producer that knows where a file's holes are passes each one here, so it lands as exactly that hole.
    ///
    /// - Parameter count: The zero bytes, no more than the entry's data, or its fork, still owes.
    /// - Returns: The records' bytes, possibly none while zeros are pending.
    /// - Throws: `ContainerError` when no entry owes bytes or `count` is more than it owes.
    public mutating func zeros(_ count: UInt64) throws(ContainerError) -> Data {
        guard count > 0 else { return Data() }
        let progress = try grammar.admitChunk(count: count, lz4: false)
        pendingZeros += count
        var records = Data()
        if progress != .continuing { flushZeros(into: &records) }
        return records
    }

    /// The records `event` adds: an entry's header, its bytes or zeros, or the end record. A leave adds
    /// nothing, since the next header's depth carries it, and nor does a resource fork's start or a file's
    /// finish, which the grammar confirms.
    ///
    /// - Parameter event: The next event of a tree in depth-first pre-order.
    /// - Returns: The records' bytes, possibly none.
    /// - Throws: `ContainerError` when the event breaks a container rule.
    public mutating func encode(_ event: TreeEvent) throws(ContainerError) -> Data {
        switch event {
        case .enterDirectory(let header), .beginFile(let header), .symlink(let header): return try entry(header)
        case .bytes(let bytes): return try self.bytes(bytes)
        case .zeros(let count): return try zeros(count)
        case .resourceFork:
            guard let owed = grammar.owed else { throw .resourceForkUndeclared }
            if owed.data > 0 { throw .entryIncomplete(remaining: owed.data) }
            return Data()
        case .finishFile:
            if let owed = grammar.owed { throw .entryIncomplete(remaining: owed.total) }
            return Data()
        case .leaveDirectory: return Data()
        case .end: return try end()
        }
    }

    /// A proto3 message's bytes; with no required fields, serializing it cannot fail.
    fileprivate static func serialized(_ message: some SwiftProtobuf.Message) -> Data {
        do {
            return try message.serializedBytes()
        } catch {
            preconditionFailure("a proto3 message always serializes: \(error)")
        }
    }

    private mutating func flushZeros(into records: inout Data) {
        guard pendingZeros > 0 else { return }
        ContainerRecord.append(.zeroRun, payload: Data(littleEndianBytes(pendingZeros)), to: &records)
        pendingZeros = 0
    }

    /// `chunk` as an LZ4 chunk when the policy tries it and its record comes out smaller, otherwise raw.
    private mutating func encodedChunk(_ chunk: Data) -> (ContainerRecordKind, Data) {
        guard grammar.currentIsLZ4, policy.attemptsLZ4, !lz4Abandoned else { return (.chunk, chunk) }
        if let block = LZ4Block.compress(chunk), block.count + ContainerRecord.lz4SizeByteCount < chunk.count {
            unshrunkChunks = 0
            var payload = Data(littleEndianBytes(UInt32(chunk.count)))
            payload.append(block)
            return (.lz4Chunk, payload)
        }
        unshrunkChunks += 1
        if let limit = policy.abandonAfterUnshrunkChunks, unshrunkChunks >= limit { lz4Abandoned = true }
        return (.chunk, chunk)
    }

    /// Whether every byte of `bytes` is zero, read a word at a time.
    static func isAllZero(_ bytes: Data) -> Bool {
        bytes.withUnsafeBytes { buffer in
            let wordSize = MemoryLayout<UInt64>.size
            var index = 0
            while index + wordSize <= buffer.count {
                if buffer.loadUnaligned(fromByteOffset: index, as: UInt64.self) != 0 { return false }
                index += wordSize
            }
            while index < buffer.count {
                if buffer[index] != 0 { return false }
                index += 1
            }
            return true
        }
    }
}

extension EntryHeader {
    /// Whether the header fits one header record, whose payload lengths `ContainerRecordKind.header` states.
    public var fitsHeaderRecord: Bool {
        ContainerRecordKind.header.payloadLengths.contains(ContainerEncoder.serialized(self).count)
    }
}
