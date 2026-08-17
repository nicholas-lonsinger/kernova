import Foundation

/// Chunk and flow-control sizing for the streamed clipboard protocol.
///
/// 64 KiB is the vsock max packet size on **both** ends — Linux
/// `VIRTIO_VSOCK_MAX_PKT_BUF_SIZE` and macOS/XNU `VSOCK_MAX_PACKET_SIZE` are
/// both 65536 — so a larger `write` is only fragmented into 64 KiB packets.
public enum ClipboardStreamTuning {
    /// Default per-chunk payload size: 64 KiB (the shared vsock packet cap).
    public static let defaultChunkPayloadSize = 64 * 1024

    /// Default in-flight credit window: 4 MiB (64 chunks).
    ///
    /// Deeper than the native 256 KiB credit-window default (Linux `buf_alloc`)
    /// because a same-host vsock is bounded by per-chunk ack round-trip latency,
    /// not bandwidth: the window over that round trip is the stream's rate
    /// ceiling, so this is how much ack latency the transport absorbs before the
    /// sender starts parking on credit.
    ///
    /// It is free on the sending side, which frames and releases each chunk, and
    /// not on the receiving one: `handleChunk` hands a chunk to the write lane
    /// without blocking, so a sink slower than the wire retains up to this much
    /// per transfer. Size it for the round trip, but as memory a slow volume can
    /// hold, not as a number with no cost.
    public static let defaultWindowBytes = 4 * 1024 * 1024

    /// Hard cap on the credit window: 8 MiB.
    ///
    /// Every ack carries the receiver's window and each side clamps what it
    /// receives to its own compiled value here, so a default above this cap is
    /// silently undone by the first ack: the two move together. Clamping the
    /// receiver's own window is also what bounds `maxBacklogBytes`; a peer's
    /// advertisement is clamped on the sending side and reaches neither.
    public static let maxWindowBytes = 8 * 1024 * 1024

    /// How far the archive encoder may run ahead of the transport: 1 MiB.
    ///
    /// Sized apart from the credit window because they bound different stages —
    /// this one parks the encoder, the window parks the wire — and because this
    /// one is resident memory that the window is not: a pipe holds its capacity
    /// plus one callback buffer, on every concurrent transfer.
    public static let encodePipeBytes = 1024 * 1024

    /// How far arriving wire bytes may run ahead of extraction: 1 MiB.
    ///
    /// Sized apart from the credit window because the receiver acks only once
    /// the sink has taken the bytes: sized *from* the window, this would let
    /// credit reopen no faster than the extract drains.
    public static let extractPipeBytes = 1024 * 1024

    /// Output granularity at which a streamed extract re-checks its guards:
    /// 1 MiB.
    ///
    /// How far an extract can overrun its free-space and payload ceilings
    /// before the next check catches it, which is why it is sized against
    /// `freeSpaceMargin`.
    public static let extractPacingBytes = 1024 * 1024

    /// Cumulative-ack coalescing quantum for a credit window: window/4 (at
    /// least 1 byte).
    ///
    /// The receiver acks once at least this many durably-written bytes have
    /// accumulated since its last ack, rather than after every 64 KiB chunk.
    /// Acks are cumulative, so the coarser cadence is self-healing.
    public static func ackQuantum(forWindowBytes windowBytes: Int) -> Int {
        max(1, windowBytes / 4)
    }

    /// Upper bound on how long the last ack may age before the next
    /// durably-written chunk forces a fresh ack regardless of the byte
    /// quantum: 1 s.
    ///
    /// Without it the quantum stretches the gap between credit-opening acks to
    /// a quarter-window of chunk writes — 16 of them at the shipped window — so
    /// under degraded I/O a sustained per-chunk write above 0.625 s trips the
    /// sender's 10 s no-ack deadline and aborts a live transfer.
    public static let ackLatencyBound: TimeInterval = 1

    /// Upper bound on how much an inline reassembly buffer pre-reserves: 64 MiB.
    ///
    /// The buffer reserves toward the sender's declared `total_bytes`; this cap
    /// keeps a peer-declared size from forcing an unbounded up-front allocation.
    /// Beyond it the buffer still grows geometrically.
    public static let maxInlineReserveBytes = 64 * 1024 * 1024

    /// Margin kept free above a transfer's size when checking disk space, so a
    /// transfer never fills the staging volume to the last byte.
    public static let freeSpaceMargin = 64 * 1024 * 1024

    /// RAM-residency threshold for an inline representation: 256 MiB.
    ///
    /// A spill point, not a hard cap: beyond it the rep is not rejected, the
    /// receiver stages it to a file and serves it back memory-mapped, so there is
    /// **no** Kernova-imposed size cap (CLIPBOARD.md §1).
    public static let maxResidentInlineBytes = 256 * 1024 * 1024

    /// Hard ceiling on a single received chunk: 16 MiB.
    ///
    /// The negotiated chunk is 64 KiB, but one frame can legally carry up to
    /// `VsockFrame.maxPayloadSize` (128 MiB); rejecting an over-large chunk
    /// bounds what a misbehaving peer can apply between disk re-checks.
    public static let maxChunkBytes = 16 * 1024 * 1024

    /// Floor on how much tree a streamed folder may extract regardless of the
    /// size its offer advertised: 64 MiB.
    ///
    /// A folder's estimate sums file bytes only, so a tree of directories and
    /// empty files advertises zero while its archive still carries a header per
    /// entry. This is the allowance that keeps such a tree extractable while
    /// still bounding one whose advertised size is a fabrication.
    public static let minimumExtractAllowance = 64 * 1024 * 1024

    /// Headroom above a file's advertised size that its one-entry archive may
    /// unpack to: 1 MiB.
    ///
    /// The extract counts uncompressed archive bytes — the entry's header plus
    /// the file's data — against a ceiling stated in file bytes, and a file's
    /// advertised size is exact where a folder's is an estimate, so the header
    /// is all the slack a file needs.
    public static let fileExtractAllowance = 1024 * 1024

    /// The most a receiver lets arrive ahead of what it has written: one credit
    /// window plus one maximum-size chunk.
    ///
    /// A sender honoring the window it was advertised can never reach this — its
    /// in-flight bytes are bounded by that window — so it bounds only a peer that
    /// ignores the protocol, whose chunks would otherwise queue on the write lane
    /// without limit. A declared payload is bounded by its own size; one that
    /// declares none (a folder archived onto the wire) has only this.
    public static func maxBacklogBytes(forWindowBytes windowBytes: Int) -> Int {
        windowBytes + maxChunkBytes
    }

    /// How long an inbound transfer waits for its next chunk before aborting a
    /// silent sender: 30 s.
    ///
    /// Bounds a sender that stops sending after Begin, so a hung peer can't pin
    /// an open file descriptor and a partial temp file until channel teardown.
    /// Larger than the sender's 10 s no-ack timeout so a slow-but-live transfer
    /// is never killed.
    public static let inboundStallTimeout: TimeInterval = 30

    /// Backstop on how long a lazy pull blocks the consuming thread *without
    /// progress* before giving up: 120 s of **inactivity**.
    ///
    /// An inactivity window, never an absolute deadline — each arriving chunk
    /// re-arms it (`LazyPullCoordinator.progress`), so a healthy transfer of any
    /// size never trips it. Made absolute, it silently kills large,
    /// still-progressing transfers that need more than one window to stream.
    public static let lazyPullTimeout: TimeInterval = 120

    /// `SO_RCVTIMEO`/`SO_SNDTIMEO` on a transfer's data connection: 30 s.
    ///
    /// A `read(2)` or `write(2)` that reaches it is the stall — the peer has
    /// gone quiet or stopped draining — reported as `stall.timeout`. It is the
    /// transport's own liveness bound, inside the `lazyPullTimeout` backstop a
    /// parked pull keeps.
    public static let dataSocketTimeout: TimeInterval = 30

    /// `SO_SNDBUF` on the host's end of a data connection: 1 MiB.
    ///
    /// The throughput lever, not a buffer budget: a freshly accepted vsock fd
    /// is born at 8 KiB, which caps host→guest at ~715 MiB/s; at 256 KiB and
    /// above the same stream reaches ~6.4 GiB/s
    /// (docs/research/2026-07-13-vsock-transport-throughput.md).
    public static let dataSendBufferBytes = 1024 * 1024

    /// How much a data connection reads from its socket at a time: 64 KiB.
    ///
    /// 64 KiB is the vsock max packet size on both ends — Linux
    /// `VIRTIO_VSOCK_MAX_PKT_BUF_SIZE` and macOS/XNU `VSOCK_MAX_PACKET_SIZE`
    /// are both 65536 — so a larger read only spans more packets. It is also
    /// the progress cadence: a receiver reports once per read.
    public static let dataReadBufferBytes = 64 * 1024

    /// How far past a completed archive a peer may keep streaming before the
    /// receiver refuses the surplus: one read buffer.
    ///
    /// A decoder that has unpacked the whole archive stops pulling, which can
    /// legitimately leave the codec's own trailing bytes unread; anything
    /// beyond that is a peer holding a finished transfer open, and is reported
    /// as `size.overrun`.
    public static let archiveTailAllowance = dataReadBufferBytes

    /// Sentinel `maxAcceptByteCount` meaning "no explicit ceiling" — the
    /// requester could not measure its free space.
    ///
    /// `0` is a *real* ceiling (zero acceptable bytes) and must never double as
    /// "unlimited": a measured-full volume advertising `0` would then read as
    /// "send anything".
    public static let unlimitedAcceptByteCount = UInt64.max
}
