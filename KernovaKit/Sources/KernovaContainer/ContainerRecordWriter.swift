#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// When the writer tries LZ4 on a chunk of an entry whose storage is LZ4. A tried chunk is sent as a block only
/// when its record comes out smaller than the raw chunk's.
public struct ChunkCompressionPolicy: Equatable, Sendable {
    /// Whether any chunk is tried.
    public var attemptsLZ4: Bool
    /// After this many tried chunks of one entry in a row that LZ4 did not shrink, the entry's remaining chunks
    /// go raw; nil keeps trying.
    public var abandonAfterUnshrunkChunks: Int?

    /// A policy of the given rules.
    ///
    /// - Parameters:
    ///   - attemptsLZ4: Whether any chunk is tried.
    ///   - abandonAfterUnshrunkChunks: Tried chunks of one entry in a row that did not shrink, after which the
    ///     entry's remaining chunks go raw; nil keeps trying.
    public init(attemptsLZ4: Bool, abandonAfterUnshrunkChunks: Int?) {
        self.attemptsLZ4 = attemptsLZ4
        self.abandonAfterUnshrunkChunks = abandonAfterUnshrunkChunks
    }

    /// Every chunk raw.
    public static let never = ChunkCompressionPolicy(attemptsLZ4: false, abandonAfterUnshrunkChunks: nil)
}

/// What became of LZ4 on an LZ4 candidate before it reached the writer.
public enum LZ4Attempt: Sendable, Equatable {
    /// Nobody tried it.
    case notAttempted
    /// `ContainerRecordWriter.lz4Payload(for:)` of the candidate's chunk: the LZ4 chunk's payload, or nil when the
    /// chunk did not shrink.
    case attempted(Data?)
}

/// Writes admitted records in stream order, deciding for each LZ4 candidate, as the policy and the entry's
/// candidates before it say, whether it goes as an LZ4 block or raw. The decision rests on the records written
/// so far alone, so the bytes it writes are the same whether an attempt was made ahead of time on another
/// thread or is made here; an attempt it does not want is ignored, and one it wants and was not given it makes.
public struct ContainerRecordWriter {
    private let policy: ChunkCompressionPolicy
    /// The entry whose records are being written, counting from 0; -1 before the first header.
    private var entry = -1
    private var unshrunkChunks = 0
    private var lz4Abandoned = false

    /// A writer compressing chunks as `policy` allows.
    ///
    /// - Parameter policy: When to try LZ4 on a chunk.
    public init(policy: ChunkCompressionPolicy) {
        self.policy = policy
    }

    /// Whether a candidate of the `entry`-th entry is worth attempting ahead of its write: false once the
    /// records written so far show the writer will not try it — the policy never tries, or that entry gave up
    /// on LZ4. An entry not yet reached could still be tried.
    ///
    /// - Parameter entry: The candidate's entry, as `AdmittedRecord.lz4Candidate` numbers it.
    /// - Returns: Whether an attempt could still be written.
    public func mayTry(candidateOf entry: Int) -> Bool {
        policy.attemptsLZ4 && !(entry == self.entry && lz4Abandoned)
    }

    /// Appends `record`'s bytes to `container`.
    ///
    /// - Parameters:
    ///   - record: The next record in stream order.
    ///   - attempt: For an LZ4 candidate, the attempt already made on its chunk, if any.
    ///   - container: The bytes to append to.
    public mutating func write(_ record: AdmittedRecord, attempt: LZ4Attempt = .notAttempted, to container: inout Data)
    {
        switch record {
        case .final(let kind, let payload):
            if kind == .header {
                entry += 1
                unshrunkChunks = 0
                lz4Abandoned = false
            }
            ContainerRecord.append(kind, payload: payload, to: &container)
        case .lz4Candidate(let chunk, _):
            guard policy.attemptsLZ4, !lz4Abandoned else {
                ContainerRecord.append(.chunk, payload: chunk, to: &container)
                return
            }
            let payload: Data?
            switch attempt {
            case .attempted(let attempted): payload = attempted
            case .notAttempted: payload = Self.lz4Payload(for: chunk)
            }
            if let payload {
                unshrunkChunks = 0
                ContainerRecord.append(.lz4Chunk, payload: payload, to: &container)
                return
            }
            unshrunkChunks += 1
            if let limit = policy.abandonAfterUnshrunkChunks, unshrunkChunks >= limit { lz4Abandoned = true }
            ContainerRecord.append(.chunk, payload: chunk, to: &container)
        }
    }

    /// The payload of `chunk` as an LZ4 chunk — its size, then its block — when that record comes out smaller than
    /// the raw chunk's, or nil. Pure, so it may run on any thread.
    ///
    /// - Parameter chunk: A chunk of at most `ContainerRecord.maxChunkPayload` bytes.
    /// - Returns: The LZ4 chunk's payload, or nil.
    public static func lz4Payload(for chunk: Data) -> Data? {
        guard let block = LZ4Block.compress(chunk), block.count + ContainerRecord.lz4SizeByteCount < chunk.count
        else { return nil }
        var payload = Data(littleEndianBytes(UInt32(chunk.count)))
        payload.append(block)
        return payload
    }
}
