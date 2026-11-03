#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire
import SwiftProtobuf

/// Reads a container incrementally: `feed(_:)` its bytes as they arrive, take `TreeEvent`s from `next()`
/// until it returns nil, and call `finish()` once the input ends. The container is valid only once `finish()`
/// returns: `.end` can come before bytes after the end record are seen, so a consumer commits a landed tree
/// only after `finish()`.
///
/// Every limit is checked before the bytes it governs are held or allocated: a record's length from its
/// 5-byte prefix, an entry's size against the byte ceiling from its header, and an LZ4 chunk's declared
/// size against its entry before decompressing. So, fed after each nil from `next()`, the decoder holds at
/// most one incomplete record and the latest feed, and no event carries more than
/// `ContainerRecord.maxChunkPayload` bytes. After it throws, it throws the same error from every call.
public struct ContainerDecoder {
    private var grammar: ContainerGrammar
    /// Input not yet decoded; it begins at a record boundary.
    private var buffer = Data()
    private var leavesDue = 0
    /// Events of the last record, after `leavesDue`: at most an entry or its bytes, then `resourceFork` or
    /// `finishFile`.
    private var due: [TreeEvent] = []
    private var failure: ContainerError?

    /// A decoder of a container `acceptance` admits.
    ///
    /// - Parameter acceptance: What the pull accepts.
    public init(accepting acceptance: ContainerAcceptance) {
        grammar = ContainerGrammar(acceptance: acceptance)
    }

    /// The input bytes held and not yet decoded.
    public var bufferedByteCount: Int { buffer.count }

    /// Takes the container's next bytes.
    ///
    /// - Parameter bytes: The bytes following those fed before.
    public mutating func feed(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        guard !buffer.isEmpty else {
            buffer = bytes
            return
        }
        // A slice past decoded records would keep their storage alive and grow it; a copy holds only the
        // incomplete record, which later feeds then extend in place.
        if buffer.startIndex != 0 { buffer = Data(buffer) }
        buffer.append(bytes)
    }

    /// The next event, or nil when the bytes fed so far hold no more.
    ///
    /// - Returns: The event, or nil until more is fed.
    /// - Throws: `ContainerError` when the container breaks a rule.
    public mutating func next() throws(ContainerError) -> TreeEvent? {
        if let failure { throw failure }
        if let event = dueEvent() { return event }
        do {
            guard try decodeRecord() else { return nil }
        } catch {
            failure = error
            throw error
        }
        return dueEvent()
    }

    /// Confirms the input ended with the end record and nothing after it.
    ///
    /// - Throws: `ContainerError.truncated` when the end record never came, `.bytesAfterEnd` when bytes
    ///   followed it, or the error the decoder already threw.
    public mutating func finish() throws(ContainerError) {
        if let failure { throw failure }
        let error: ContainerError
        if !grammar.ended {
            error = .truncated
        } else if !buffer.isEmpty {
            error = .bytesAfterEnd
        } else {
            return
        }
        failure = error
        throw error
    }

    private mutating func dueEvent() -> TreeEvent? {
        if leavesDue > 0 {
            leavesDue -= 1
            return .leaveDirectory
        }
        return due.isEmpty ? nil : due.removeFirst()
    }

    /// Decodes the record at the front of the buffer into due events, or returns false until it is whole.
    private mutating func decodeRecord() throws(ContainerError) -> Bool {
        guard let first = buffer.first else { return false }
        if grammar.ended { throw .bytesAfterEnd }
        guard let kind = ContainerRecordKind(rawValue: first) else { throw .unknownRecordKind(first) }
        guard buffer.count >= 5 else { return false }
        let length = Int(littleEndian(UInt32.self, in: buffer, at: 1))
        guard kind.payloadLengths.contains(length) else { throw .recordLengthOutOfRange(kind: kind, length: length) }
        let recordLength = ContainerRecord.prefixByteCount + length
        guard buffer.count >= recordLength else { return false }
        let stated = littleEndian(UInt32.self, in: buffer, at: 5)
        let payloadStart = buffer.startIndex + ContainerRecord.prefixByteCount
        let payload = buffer[payloadStart..<(payloadStart + length)]
        guard ContainerRecord.checksum(kind: first, length: UInt32(length), payload: payload) == stated else {
            throw .checksumMismatch(kind: kind)
        }
        buffer = buffer.count == recordLength ? Data() : buffer[(buffer.startIndex + recordLength)...]
        try decode(kind, payload: payload)
        return true
    }

    private mutating func decode(_ kind: ContainerRecordKind, payload: Data) throws(ContainerError) {
        switch kind {
        case .header:
            let header: EntryHeader
            do {
                header = try EntryHeader(serializedBytes: payload)
            } catch {
                throw .headerUndecodable
            }
            let (leaving, entry) = try grammar.admit(header)
            leavesDue = leaving
            switch entry {
            case .directory: due = [.enterDirectory(header)]
            case .symlink: due = [.symlink(header)]
            case .file(let progress): due = [.beginFile(header)] + Self.events(after: progress)
            }
        case .chunk:
            let progress = try grammar.admitChunk(count: UInt64(payload.count), lz4: false)
            due = [.bytes(payload)] + Self.events(after: progress)
        case .lz4Chunk:
            let declared = Int(littleEndian(UInt32.self, in: payload, at: 0))
            guard declared <= ContainerRecord.maxChunkPayload else {
                throw .lz4(.sizeOutOfRange(declared: declared, ceiling: ContainerRecord.maxChunkPayload))
            }
            let progress = try grammar.admitChunk(count: UInt64(declared), lz4: true)
            let block = payload.dropFirst(ContainerRecord.lz4SizeByteCount)
            let bytes: Data
            do {
                bytes = try LZ4Block.decompress(block, decompressedSize: declared, ceiling: declared)
            } catch {
                throw .lz4(error)
            }
            due = [.bytes(bytes)] + Self.events(after: progress)
        case .zeroRun:
            let count = littleEndian(UInt64.self, in: payload, at: 0)
            let progress = try grammar.admitChunk(count: count, lz4: false)
            due = [.zeros(count)] + Self.events(after: progress)
        case .end:
            let end: EndRecord
            do {
                end = try EndRecord(serializedBytes: payload)
            } catch {
                throw .endUndecodable
            }
            leavesDue = try grammar.admitEnd(end)
            due = [.end]
        }
    }

    /// The events that mark where a file's bytes stand.
    private static func events(after progress: ContainerGrammar.Progress) -> [TreeEvent] {
        switch progress {
        case .continuing: []
        case .resourceForkFollows: [.resourceFork]
        case .complete: [.finishFile]
        }
    }
}
