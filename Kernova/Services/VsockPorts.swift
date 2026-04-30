import Foundation

/// Vsock port assignments for Kernova guest <-> host services.
///
/// Each service binds to its own port so the framework's listener routing
/// handles demultiplexing instead of in-band tagging in our wire protocol.
/// Ports live in the IANA dynamic range (49152-65535).
enum KernovaVsockPort {
    /// Guest agent log forwarding.
    static let log: UInt32 = 49153
}
