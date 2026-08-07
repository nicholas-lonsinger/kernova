import Foundation

/// Chunk and flow-control sizing for the streamed clipboard protocol.
///
/// 64 KiB is the vsock max packet size on **both** ends — Linux
/// `VIRTIO_VSOCK_MAX_PKT_BUF_SIZE` and macOS/XNU `VSOCK_MAX_PACKET_SIZE` are
/// both 65536 — so a larger `write` is only fragmented into 64 KiB packets.
public enum ClipboardStreamTuning {
    /// Default per-chunk payload size: 64 KiB (the shared vsock packet cap).
    public static let defaultChunkPayloadSize = 64 * 1024

    /// Default in-flight credit window: 1 MiB (16 chunks).
    ///
    /// Deeper than the native 256 KiB credit-window default (Linux `buf_alloc`)
    /// because a same-host vsock is bounded by per-chunk ack round-trip latency,
    /// not bandwidth.
    public static let defaultWindowBytes = 1024 * 1024

    /// Hard cap on the credit window: 2 MiB.
    public static let maxWindowBytes = 2 * 1024 * 1024

    /// Cumulative-ack coalescing quantum for a credit window: window/4 (at
    /// least 1 byte) — 256 KiB at the production 1 MiB window.
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
    /// four chunk-write times, so under degraded I/O sustained per-chunk writes
    /// in the 2.5–10 s range trip the sender's 10 s no-ack deadline and abort a
    /// live transfer.
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
    /// re-arms it (`LazyPullCoordinator.heartbeat`), so a healthy transfer of any
    /// size never trips it. Made absolute, it silently kills large,
    /// still-progressing transfers that need more than one window to stream.
    public static let lazyPullTimeout: TimeInterval = 120

    /// Sentinel `maxAcceptByteCount` meaning "no explicit ceiling" — the
    /// requester could not measure its free space.
    ///
    /// `0` is a *real* ceiling (zero acceptable bytes) and must never double as
    /// "unlimited": a measured-full volume advertising `0` would then read as
    /// "send anything".
    public static let unlimitedAcceptByteCount = UInt64.max
}
