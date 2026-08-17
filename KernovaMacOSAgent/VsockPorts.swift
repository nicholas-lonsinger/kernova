import Foundation

/// Vsock port assignments, part of the wire contract and mirrored in
/// `Kernova/Services/VsockPorts.swift` — change both sides together.
enum KernovaVsockPort {
    /// Always-on control plane: version handshake and heartbeats, carried
    /// independently of any optional feature toggle.
    static let control: UInt32 = 49154

    /// Bidirectional clipboard sync.
    static let clipboard: UInt32 = 49152

    /// Guest agent log forwarding.
    static let log: UInt32 = 49153

    /// Files dragged onto the VM display, streamed host→guest into Downloads.
    static let drop: UInt32 = 49155

    /// One connection per clipboard transfer, carrying that transfer's bytes.
    static let clipboardData: UInt32 = 49156

    /// One connection per dropped item, carrying that item's bytes.
    static let dropData: UInt32 = 49157
}
