import os

/// The `OSSignposter`s the clipboard stream engines emit intervals on, so a
/// stage split comes from an Instruments trace rather than from `sample(1)`,
/// which costs a large fraction of the throughput it is measuring here.
enum ClipboardSignposts {
    /// Whole-transfer intervals. On the Points of Interest track, so a trace
    /// shows them with no custom instrument.
    static let transfers = OSSignposter(subsystem: "app.kernova", category: .pointsOfInterest)

    /// Per-stage intervals, including per-chunk ones. `isEnabled` is false
    /// until an instrument attaches, and every per-chunk site is gated on it —
    /// hoisted once per transfer, never re-read per chunk.
    static let stages = OSSignposter(subsystem: "app.kernova", category: "ClipboardStream")
}
