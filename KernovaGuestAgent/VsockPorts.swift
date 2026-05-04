import Foundation

/// Vsock port assignments (guest-side mirror of `Kernova/Services/VsockPorts.swift`).
///
/// Duplicated rather than imported across the host/agent boundary so the two
/// sides can drift independently if needed (e.g. a guest agent built against
/// an older host). The port numbers are part of the wire contract — keep
/// both sides in sync.
enum KernovaVsockPort {
    /// Always-on control plane. Carries the agent version handshake and
    /// bidirectional heartbeats independent of any optional feature toggle,
    /// so the host can detect agent presence/liveness even when clipboard
    /// sharing or other features are disabled.
    static let control: UInt32 = 49154

    /// Bidirectional clipboard sync.
    static let clipboard: UInt32 = 49152

    /// Guest agent log forwarding.
    static let log: UInt32 = 49153
}
