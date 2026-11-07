import KernovaAgentCore
import KernovaLogging

/// The dialer of an agent built with the hang-before-Hello fault (`KERNOVA_AGENT_FAULT=hang-before-hello`, Debug
/// only): it reaches no transport, and its one dial stays in flight for the process's life, which the dial
/// schedule waits on with no deadline. The process runs on but never sends Hello, so nothing confirms an update
/// switch to it.
public struct UnansweredDialer: TransportDialer {
    private let logger: KernovaLogger

    /// A dialer that logs the fault's notice to `logger` when its dial starts.
    public init(logger: KernovaLogger) {
        self.logger = logger
    }

    /// Logs the notice and never calls `completion`.
    public func dial(_ completion: @escaping @Sendable (Result<any ByteStream, DialFailure>) -> Void) {
        logger.log(.notice, "This build carries the hang-before-Hello fault: it never dials")
    }
}
