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

    /// Upper bound on how much an inline reassembly buffer pre-reserves: 64 MiB.
    ///
    /// Reserving toward the sender's declared `total_bytes` (rather than the 2 MiB
    /// credit window) lets a large inline rep grow in one allocation instead of the
    /// geometric reallocations a 2 MiB reserve forces. The 64 MiB cap keeps an
    /// attacker-declared `total_bytes` from forcing an unbounded up-front
    /// allocation — beyond it the buffer still grows geometrically, and the rep
    /// spills to disk at `maxResidentInlineBytes` (256 MiB) anyway, so this sits
    /// deliberately below that spill point.
    public static let maxInlineReserveBytes = 64 * 1024 * 1024

    /// Margin kept free above a transfer's size when checking disk space, so a
    /// transfer never fills the staging volume to the last byte.
    public static let freeSpaceMargin = 64 * 1024 * 1024

    /// RAM-residency threshold for an inline representation: 256 MiB.
    ///
    /// An inline rep (text/RTF/inline image) is reassembled in memory up to this
    /// size — matching native, where small clipboard content stays RAM-resident
    /// and the consuming app holds it in RAM too. Beyond it the rep is **not**
    /// rejected: the receiver spills it to a staging file and serves it back via
    /// a memory-mapped read, so residency is an implementation detail and there
    /// is **no** Kernova-imposed size cap (CLIPBOARD.md §1). The blast radius of
    /// a peer-declared `total_bytes` is then bounded by the disk free-space guard
    /// — exactly as a file rep already is — rather than by a fixed heap ceiling.
    ///
    /// This is a spill point, not a hard cap: lowering it trades less Kernova RAM
    /// for a disk round-trip on medium payloads (§2 prefers matching native
    /// residency), so any change is a measurement call, not a correctness one.
    public static let maxResidentInlineBytes = 256 * 1024 * 1024

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

    /// Backstop on how long a lazy pull blocks the consuming thread *without
    /// progress* before giving up: 120 s of **inactivity**.
    ///
    /// This is an inactivity window, not an absolute deadline — each arriving
    /// chunk re-arms it (`LazyPullCoordinator.heartbeat`, driven by the
    /// receiver's per-chunk progress hook), so a healthy transfer of any size
    /// never trips it no matter how long it runs. (An earlier absolute 120 s
    /// ceiling silently killed large, still-progressing transfers — e.g. a
    /// multi-GB file that simply needed more than two minutes to stream, which
    /// left the paste hanging then failing with no feedback.) It is not the
    /// primary liveness guard either: the receiver's `inboundStallTimeout` (30 s
    /// of no chunk) aborts a dead transfer and wakes the blocked pull first, and
    /// channel teardown unblocks it immediately. The backstop fires only if
    /// neither delivers an outcome after a full window of silence (a
    /// coordinator/receiver bug). Tests inject a tiny value to exercise it.
    public static let lazyPullTimeout: Duration = .seconds(120)

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
