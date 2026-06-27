import Foundation

/// A clipboard transfer in flight, surfaced by `ClipboardServicing` for the
/// clipboard window's bottom bar and the toolbar button's under-bar to render.
///
/// Driven off the transport's existing byte-level progress (`ClipboardStreamSender`
/// outbound, `ClipboardStreamReceiver` inbound). `nil` on the service means no
/// transfer is currently being shown — either none is in flight, or the in-flight
/// one hasn't yet crossed the reveal delay (a fast transfer never shows).
struct ClipboardTransferProgress: Equatable, Sendable {
    /// Which way the bytes are moving, from the host's point of view.
    enum Direction: Equatable, Sendable {
        /// Guest → host (a "Copy to Mac" pull or a rich-preview fetch).
        case inbound
        /// Host → guest (the guest pasting the host's clipboard).
        case outbound
    }

    let direction: Direction
    let bytesTransferred: Int
    let totalBytes: Int
    /// Filename when the representation is a file payload, for the tooltip /
    /// accessibility value; `nil` for inline representations.
    let label: String?

    /// Progress as a `0...1` fraction, clamped (a zero/unknown total reads as 0,
    /// an overshoot or negative input is pinned into range).
    var fractionComplete: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, Double(bytesTransferred) / Double(totalBytes)))
    }
}
