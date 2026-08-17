import Foundation

/// Sizing and timing for a clipboard transfer's data connection and the extract
/// pipeline behind it.
public enum ClipboardStreamTuning {
    /// Output granularity at which a streamed extract re-checks its guards:
    /// 1 MiB.
    ///
    /// How far an extract can overrun its free-space and payload ceilings
    /// before the next check catches it, which is why it is sized against
    /// `freeSpaceMargin`.
    public static let extractPacingBytes = 1024 * 1024

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

    /// Backstop on how long a lazy pull blocks the consuming thread *without
    /// progress* before giving up: 120 s of **inactivity**.
    ///
    /// An inactivity window, never an absolute deadline — each arriving buffer
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
