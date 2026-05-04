import Foundation

/// Vsock port assignments for Kernova guest <-> host services.
///
/// Each service binds to its own port so the framework's listener routing
/// handles demultiplexing instead of in-band tagging in our wire protocol.
/// Ports live in the IANA dynamic range (49152-65535).
enum KernovaVsockPort {
    /// Always-on control plane. Carries the agent version handshake and
    /// bidirectional heartbeats independent of any optional feature toggle,
    /// so the host can detect agent presence/liveness even when clipboard
    /// sharing or other features are disabled.
    static let control: UInt32 = 49154

    /// Bidirectional clipboard sync (text, eventually richer formats).
    static let clipboard: UInt32 = 49152

    /// Guest agent log forwarding.
    static let log: UInt32 = 49153
}
