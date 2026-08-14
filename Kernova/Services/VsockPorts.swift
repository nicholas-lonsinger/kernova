import Foundation

/// Vsock port assignments for Kernova guest <-> host services.
///
/// Each service binds to its own port. Ports live in the IANA dynamic range
/// (49152-65535).
enum KernovaVsockPort {
    /// Always-on control plane — carries the agent version handshake and
    /// bidirectional heartbeats regardless of any feature toggle.
    static let control: UInt32 = 49154

    /// Bidirectional clipboard sync (text, eventually richer formats).
    static let clipboard: UInt32 = 49152

    /// Guest agent log forwarding.
    static let log: UInt32 = 49153

    /// Files dragged onto the VM display, streamed host→guest into Downloads.
    static let drop: UInt32 = 49155
}
