import os

/// The `OSSignposter` the clipboard stream engines emit intervals on, so a
/// transfer's timing comes from an Instruments trace rather than from
/// `sample(1)`, which costs a large fraction of the throughput it is measuring
/// here.
enum ClipboardSignposts {
    /// Whole-transfer intervals. On the Points of Interest track, so a trace
    /// shows them with no custom instrument.
    static let transfers = OSSignposter(subsystem: "app.kernova", category: .pointsOfInterest)
}
