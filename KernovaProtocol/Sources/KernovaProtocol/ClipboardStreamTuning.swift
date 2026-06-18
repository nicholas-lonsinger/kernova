import Foundation

/// Chunk and flow-control sizing for the streamed clipboard protocol.
///
/// These are the production defaults; the sender and receiver take the same
/// values as constructor parameters so tests can inject tiny sizes to exercise
/// multi-chunk and windowed-backpressure paths without moving real megabytes.
/// (Constructor injection rather than a mutable global keeps parallel test runs
/// from racing on a shared override.)
///
/// ## Why 64 KiB chunks
/// 64 KiB is the vsock max packet size on **both** ends — Linux
/// `VIRTIO_VSOCK_MAX_PKT_BUF_SIZE` and macOS/XNU `VSOCK_MAX_PACKET_SIZE` are
/// both 65536; a larger `write` is just fragmented into 64 KiB packets.
/// Throughput plateaus at this size (benchmarks show < 3% past it), it is the
/// size Firecracker uses, and it is page-aligned on both 4 KiB and 16 KiB page
/// sizes. The absolute ceiling on Apple's hypervisor is unmeasured, so the size
/// is left tunable for later benchmarking — but the knee is structural (the
/// shared packet cap), not an Apple-published figure.
///
/// ## Why a 1 MiB window
/// The in-flight credit window starts from the native credit-window defaults
/// (Linux `buf_alloc` 256 KiB; XNU socket buffer 512 KiB) and goes a little
/// deeper. On a same-host link the bandwidth-delay product is microscopic, so
/// the window is headroom rather than the throughput limiter — going bigger only
/// pins more un-acked RAM per stream.
public enum ClipboardStreamTuning {
    /// Default per-chunk payload size: 64 KiB (the shared vsock packet cap).
    public static let defaultChunkPayloadSize = 64 * 1024

    /// Default in-flight credit window: 1 MiB (16 chunks).
    ///
    /// Larger than the native 256 KiB default: on a same-host vsock the limiter
    /// is per-chunk round-trip latency, not bandwidth, so a deeper window keeps
    /// the pipe full across the ack round-trip (the un-acked RAM cost is a few
    /// MiB per transfer, negligible). Stream frames are processed off the owning
    /// actor, so the receiver can drain at full rate.
    public static let defaultWindowBytes = 1024 * 1024

    /// Hard cap on the credit window: 2 MiB.
    public static let maxWindowBytes = 2 * 1024 * 1024

    /// Margin kept free above a transfer's size when checking disk space, so a
    /// transfer never fills the staging volume to the last byte.
    public static let freeSpaceMargin = 64 * 1024 * 1024

    /// Hard ceiling on an inline (RAM-reassembled) representation: 256 MiB.
    ///
    /// Inline reps (text/RTF/inline image) are held resident in memory by
    /// design, so unlike file reps they need a finite bound: a peer-declared
    /// `total_bytes` is otherwise an unbounded heap-growth (OOM) vector from an
    /// untrusted or buggy guest. 256 MiB comfortably covers any realistic
    /// clipboard text/image while capping the blast radius. File representations
    /// stay unbounded — they stream to disk under the free-space guard.
    public static let maxInlineBytes = 256 * 1024 * 1024

    /// Hard ceiling on a single received chunk: 16 MiB.
    ///
    /// The negotiated chunk is 64 KiB, but one frame can legally carry up to
    /// `VsockFrame.maxPayloadSize` (128 MiB). Rejecting an over-large chunk
    /// bounds the per-chunk memory/disk pressure a misbehaving peer can apply
    /// between the once-per-window disk re-check.
    public static let maxChunkBytes = 16 * 1024 * 1024

    /// How long an inbound transfer waits for its next chunk before aborting a
    /// silent sender: 30 s.
    ///
    /// Symmetric to the sender's no-ack deadline (which bounds a receiver that
    /// stops *acking*); this bounds a sender that stops *sending* after Begin, so
    /// a dropped or hung peer can't pin an open file descriptor and a partial
    /// temp file until channel teardown. Comfortably larger than the sender's
    /// 10 s no-ack timeout so a slow-but-live transfer is never killed.
    public static let inboundStallTimeout: Duration = .seconds(30)

    /// Sentinel `maxAcceptByteCount` meaning "no explicit ceiling" — the
    /// requester could not measure its free space, so it relies on the receiver's
    /// mid-stream disk guard and the write-failure backstop instead.
    ///
    /// `RATIONALE:` `0` is a *real* ceiling (zero acceptable bytes), so it must
    /// not double as "unlimited"; a measured-full volume advertising `0` would
    /// otherwise read as "send anything". Unknown capacity maps to this sentinel.
    public static let unlimitedAcceptByteCount = UInt64.max
}

extension Duration {
    /// This duration as fractional seconds, for `DispatchTime`/`Date` math.
    var timeInterval: TimeInterval {
        let (s, attos) = components
        return Double(s) + Double(attos) / 1_000_000_000_000_000_000
    }
}
