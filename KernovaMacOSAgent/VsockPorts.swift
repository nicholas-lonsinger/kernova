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
}
