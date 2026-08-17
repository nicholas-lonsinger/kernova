import Foundation

/// Timing telemetry for one successfully completed transfer, surfaced by the
/// owning service as a `.notice` log line so a host↔guest throughput baseline
/// can be read out of Console.app without a special build.
///
/// One type serves both directions, so a send line and the receive line that
/// answers it state the same figures in the same order and compare as they
/// stand; what only one side of a transfer can know lives in `detail`.
///
/// Successful transfers only — a failed inbound transfer reports through
/// `ClipboardStreamAbortInfo`, and a failed outbound transfer reports nothing.
public struct ClipboardTransferMetrics: Sendable, Equatable {
    /// Identifies the transfer these metrics describe.
    public let transferID: UInt64
    /// UTI of the transferred representation.
    public let uti: String
    /// Payload bytes — the file, tree or inline bytes the transfer carried — in
    /// the unit every readout and the offer's `byte_count` use.
    ///
    /// A sent folder is the one payload whose exact size is not known while it
    /// streams, and reports its uncompressed archive stream instead: the tree
    /// plus its per-entry headers, so it reads slightly above the count the
    /// receiver reports for the same transfer.
    public let byteCount: Int
    /// Bytes that crossed the wire: the archive for an archived payload,
    /// `byteCount` itself for a raw one.
    public let wireByteCount: Int
    /// Whole-transfer wall time in seconds — `ClipboardStreamBegin` processed →
    /// digest verified and committed inbound; registration → `ClipboardStreamEnd`
    /// written outbound, so the sender's source-open ramp is inside it.
    public let duration: TimeInterval
    /// What only the measuring side can know.
    public let detail: Detail

    /// The direction of a transfer, carrying that direction's own figures.
    public enum Detail: Sendable, Equatable {
        case inbound(Inbound)
        case outbound(Outbound)
    }

    /// What a receiver measures.
    public struct Inbound: Sendable, Equatable {
        /// Whether the payload streamed through the extract pipeline (vs.
        /// reassembling in RAM).
        public let streamedToDisk: Bool
        /// First chunk arrival → digest verified and committed, in seconds,
        /// excluding the go-signal round-trip and the sender's source-open ramp.
        /// `nil` for a zero-byte transfer, which never carries a chunk.
        public let streamingDuration: TimeInterval?

        init(streamedToDisk: Bool, streamingDuration: TimeInterval?) {
            self.streamedToDisk = streamedToDisk
            self.streamingDuration = streamingDuration
        }
    }

    /// What a sender measures: the stage split behind a slow send, in the same
    /// units the whole-transfer figures above are stated in.
    public struct Outbound: Sendable, Equatable {
        /// Whether the payload was encoded onto the wire as an archive — what
        /// the transfer's descriptor declared. Stated rather than inferred from
        /// `wireByteCount != byteCount`, which an incompressible archive
        /// coincides on.
        public let isArchived: Bool
        /// Registration → first payload byte handed to the socket, in seconds,
        /// covering the payload classification and an archive's first-byte
        /// latency. `nil` when no byte was sent.
        public let timeToFirstByte: TimeInterval?
        /// Seconds spent producing bytes rather than handing them to the
        /// socket — reading and compressing the source, so it is what a slow
        /// source rather than a slow peer costs.
        public let sourceWait: TimeInterval
        /// Chunk frames handed to the socket, or `nil` for a transport that
        /// does not chunk.
        public let chunkCount: Int?
        /// Seconds summed over every wait for the peer's go-signal and credit,
        /// or `nil` for a transport with no application-level credit.
        public let creditStall: TimeInterval?

        init(
            isArchived: Bool, timeToFirstByte: TimeInterval?, sourceWait: TimeInterval,
            chunkCount: Int? = nil, creditStall: TimeInterval? = nil
        ) {
            self.isArchived = isArchived
            self.timeToFirstByte = timeToFirstByte
            self.sourceWait = sourceWait
            self.chunkCount = chunkCount
            self.creditStall = creditStall
        }
    }

    init(
        transferID: UInt64, uti: String, byteCount: Int, wireByteCount: Int,
        duration: TimeInterval, detail: Detail
    ) {
        self.transferID = transferID
        self.uti = uti
        self.byteCount = byteCount
        self.wireByteCount = wireByteCount
        self.duration = duration
        self.detail = detail
    }

    /// The receive-side figures, or `nil` for a send.
    public var inbound: Inbound? {
        if case .inbound(let inbound) = detail { return inbound }
        return nil
    }

    /// The send-side figures, or `nil` for a receive.
    public var outbound: Outbound? {
        if case .outbound(let outbound) = detail { return outbound }
        return nil
    }

    /// One-line human-readable rendering for the throughput log line, e.g.
    /// `"10485760 bytes (public.data) in 0.052 s — 192.3 MiB/s (disk, 4194304 wire bytes, streamed 0.049 s)"`.
    ///
    /// The rate is in payload bytes — what the user sees move — and the wire
    /// count is stated when it differs, so the compression ratio is one
    /// division away.
    public var logSummary: String {
        let seconds = duration
        let rate = seconds > 0 ? Double(byteCount) / 1_048_576 / seconds : 0
        let kind: String
        var stages: [String] = []
        switch detail {
        case .inbound(let inbound):
            kind = inbound.streamedToDisk ? "disk" : "memory"
            if let streamingDuration = inbound.streamingDuration {
                stages.append(String(format: "streamed %.3f s", streamingDuration))
            }
        case .outbound(let outbound):
            kind = outbound.isArchived ? "archive" : "raw"
            if let chunkCount = outbound.chunkCount {
                stages.append("\(chunkCount) chunks")
            }
            if let timeToFirstByte = outbound.timeToFirstByte {
                stages.append(String(format: "ramp %.3f s", timeToFirstByte))
            }
            if let creditStall = outbound.creditStall {
                stages.append(String(format: "credit %.3f s", creditStall))
            }
            stages.append(String(format: "source %.3f s", outbound.sourceWait))
        }
        var parts = [kind]
        if wireByteCount != byteCount {
            parts.append("\(wireByteCount) wire bytes")
        }
        parts.append(contentsOf: stages)
        return String(
            format: "%ld bytes (%@) in %.3f s — %.1f MiB/s (%@)",
            byteCount, uti, seconds, rate, parts.joined(separator: ", "))
    }
}
