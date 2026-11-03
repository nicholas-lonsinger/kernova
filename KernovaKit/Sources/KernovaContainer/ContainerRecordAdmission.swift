#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// A container record admitted in stream order and not yet written. Everything about it is settled except
/// whether a chunk of LZ4 storage goes as an LZ4 block, which `ContainerRecordWriter` decides as it writes.
public enum AdmittedRecord: Equatable, Sendable {
    /// A record whose payload is final: a header, a chunk of an entry whose storage is not LZ4, a zero run, or
    /// the end.
    case final(ContainerRecordKind, Data)
    /// A chunk of an entry whose storage is LZ4, the `entry`-th of the container counting from 0.
    case lz4Candidate(Data, entry: Int)
}

/// Turns a tree's events into the records that carry them, in order, held to the same rules as
/// `ContainerDecoder`: `entry(_:)` for each header in depth-first pre-order, `bytes(_:)` for a file's data until it
/// has all it declared and then for its resource fork's, then `end()`. A file's bytes are cut into chunks of
/// `ContainerEncoder.chunkByteCount`, consecutive all-zero chunks merged into one zero run. Every limit is checked
/// here, before a record exists, so nothing downstream of it — the writer, or work handed to another thread — ever
/// holds a chunk the container refuses. After it throws, discard it.
public struct ContainerRecordAdmission {
    private var grammar: ContainerGrammar
    /// Zero bytes counted and not yet admitted as a record: consecutive all-zero chunks share one zero run.
    private var pendingZeros: UInt64 = 0
    /// The headers admitted.
    private var entries = 0

    /// An admission of a container `acceptance` admits.
    ///
    /// - Parameter acceptance: What the pull's destination accepts.
    public init(accepting acceptance: ContainerAcceptance) {
        grammar = ContainerGrammar(acceptance: acceptance)
    }

    /// The header record of the next entry.
    ///
    /// - Parameter header: The entry, at its depth in pre-order.
    /// - Returns: The record.
    /// - Throws: `ContainerError` when the entry breaks a container rule or its header is too large.
    public mutating func entry(_ header: EntryHeader) throws(ContainerError) -> [AdmittedRecord] {
        let payload = ContainerEncoder.serialized(header)
        guard ContainerRecordKind.header.payloadLengths.contains(payload.count) else {
            throw .recordLengthOutOfRange(kind: .header, length: payload.count)
        }
        _ = try grammar.admit(header)
        entries += 1
        return [.final(.header, payload)]
    }

    /// The records carrying the current entry's next bytes — its data's, then once those are whole its resource
    /// fork's: one per chunk, with consecutive all-zero chunks as one zero run, admitted once a non-zero chunk
    /// follows or the data or the fork has all its bytes.
    ///
    /// - Parameter bytes: The entry's next bytes, no more than its data, or its fork, still owes.
    /// - Returns: The records, possibly none while zeros are pending.
    /// - Throws: `ContainerError` when no entry owes bytes or `bytes` is more than it owes.
    public mutating func bytes(_ bytes: Data) throws(ContainerError) -> [AdmittedRecord] {
        var records: [AdmittedRecord] = []
        var start = bytes.startIndex
        while start < bytes.endIndex {
            let end = min(start + ContainerEncoder.chunkByteCount, bytes.endIndex)
            let chunk = bytes[start..<end]
            start = end
            if Self.isAllZero(chunk) {
                let progress = try grammar.admitChunk(count: UInt64(chunk.count), lz4: false)
                pendingZeros += UInt64(chunk.count)
                if progress != .continuing { flushZeros(into: &records) }
                continue
            }
            flushZeros(into: &records)
            _ = try grammar.admitChunk(count: UInt64(chunk.count), lz4: false)
            records.append(grammar.currentIsLZ4 ? .lz4Candidate(chunk, entry: entries - 1) : .final(.chunk, chunk))
        }
        return records
    }

    /// The records carrying the current entry's next `count` bytes, all zero, as a zero run: merged with any zeros
    /// pending, and admitted once a non-zero chunk follows or the data or the fork has all its bytes. A producer
    /// that knows where a file's holes are passes each one here, so it lands as exactly that hole.
    ///
    /// - Parameter count: The zero bytes, no more than the entry's data, or its fork, still owes.
    /// - Returns: The records, possibly none while zeros are pending.
    /// - Throws: `ContainerError` when no entry owes bytes or `count` is more than it owes.
    public mutating func zeros(_ count: UInt64) throws(ContainerError) -> [AdmittedRecord] {
        guard count > 0 else { return [] }
        let progress = try grammar.admitChunk(count: count, lz4: false)
        pendingZeros += count
        var records: [AdmittedRecord] = []
        if progress != .continuing { flushZeros(into: &records) }
        return records
    }

    /// The end record, stating the container's counts.
    ///
    /// - Returns: The record.
    /// - Throws: `ContainerError` when the current entry still owes bytes or no entry was admitted.
    public mutating func end() throws(ContainerError) -> [AdmittedRecord] {
        var end = EndRecord()
        end.entries = grammar.counted.entries
        end.bytes = grammar.counted.bytes
        _ = try grammar.admitEnd(end)
        return [.final(.end, ContainerEncoder.serialized(end))]
    }

    /// The records `event` adds: an entry's header, its bytes or zeros, or the end record. A leave adds nothing,
    /// since the next header's depth carries it, and nor does a resource fork's start or a file's finish, which
    /// the declared sizes carry; each is still held to `TreeEventSequence`.
    ///
    /// - Parameter event: The next event of a tree in depth-first pre-order.
    /// - Returns: The records, possibly none.
    /// - Throws: `ContainerError` when the event breaks a container rule.
    public mutating func admit(_ event: TreeEvent) throws(ContainerError) -> [AdmittedRecord] {
        switch event {
        case .enterDirectory(let header), .beginFile(let header), .symlink(let header): return try entry(header)
        case .bytes(let bytes): return try self.bytes(bytes)
        case .zeros(let count): return try zeros(count)
        case .resourceFork, .finishFile, .leaveDirectory:
            try grammar.admitStep(event)
            return []
        case .end: return try end()
        }
    }

    private mutating func flushZeros(into records: inout [AdmittedRecord]) {
        guard pendingZeros > 0 else { return }
        records.append(.final(.zeroRun, Data(littleEndianBytes(pendingZeros))))
        pendingZeros = 0
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
