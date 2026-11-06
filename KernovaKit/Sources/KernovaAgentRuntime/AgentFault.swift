import KernovaAgentCore

/// A fault a Debug build of an agent carries, chosen once by its entry point from a Debug-only build input,
/// for tests of what the host and the installer do when an agent misbehaves.
public enum AgentFault: Sendable, Equatable {
    /// The process runs as usual but never dials, so it never sends Hello and nothing confirms an update
    /// switch to it.
    case hangBeforeHello
}

/// The dialer a ``AgentFault/hangBeforeHello`` runtime dials through: its one dial stays in flight for the
/// process's life, which the dial schedule waits on with no deadline.
struct UnansweredDialer: TransportDialer {
    func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void) {}
}
