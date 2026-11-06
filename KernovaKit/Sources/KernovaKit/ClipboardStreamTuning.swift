import Foundation

/// Timing for the v1 vsock channels' sockets.
public enum ClipboardStreamTuning {
    /// `SO_RCVTIMEO`/`SO_SNDTIMEO` on a v1 vsock channel's socket: 30 s.
    ///
    /// A `read(2)` or `write(2)` that reaches it is the stall — the peer has
    /// gone quiet or stopped draining.
    public static let dataSocketTimeout: TimeInterval = 30
}
