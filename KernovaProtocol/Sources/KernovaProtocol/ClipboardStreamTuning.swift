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
/// ## Why a 256 KiB window
/// The in-flight credit window matches the native credit-window defaults (Linux
/// `buf_alloc` 256 KiB; XNU socket buffer 512 KiB). On a same-host link the
/// bandwidth-delay product is microscopic, so the window is headroom rather than
/// the throughput limiter — going bigger only pins more un-acked RAM per stream.
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
}
