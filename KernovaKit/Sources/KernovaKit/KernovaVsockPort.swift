import Foundation

/// Vsock port assignments for Kernova guest <-> host services.
///
/// Each service binds to its own port. Ports live in the IANA dynamic range
/// (49152-65535).
public enum KernovaVsockPort {
    /// Always-on control plane — carries the agent version handshake and
    /// bidirectional heartbeats regardless of any feature toggle.
    public static let control: UInt32 = 49154

    /// Bidirectional clipboard sync (text, eventually richer formats).
    public static let clipboard: UInt32 = 49152

    /// Guest agent log forwarding.
    public static let log: UInt32 = 49153

    /// Files dragged onto the VM display, streamed host→guest into Downloads.
    public static let drop: UInt32 = 49155

    /// One connection per clipboard transfer, carrying that transfer's bytes.
    public static let clipboardData: UInt32 = 49156

    /// One connection per dropped item, carrying that item's bytes.
    public static let dropData: UInt32 = 49157
}
