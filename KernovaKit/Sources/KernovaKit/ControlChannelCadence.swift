import Foundation

/// The control channel's timing contract, held once for the host service and
/// the guest agent so a cadence change moves both peers together.
public struct ControlChannelCadence: Equatable, Sendable {
    /// Seconds between outbound heartbeats.
    public let heartbeatInterval: TimeInterval

    /// Seconds of peer silence after which the peer is reported unresponsive.
    public let unresponsiveAfter: TimeInterval

    /// Seconds of peer silence after which the channel is torn down.
    public let terminateAfter: TimeInterval

    /// Seconds between liveness evaluations.
    ///
    /// Several checks per ``unresponsiveAfter`` so the transition fires
    /// promptly, capped at ``heartbeatInterval`` so a small threshold does not
    /// over-spin the timer.
    public let livenessTickInterval: TimeInterval

    /// Creates a cadence and derives ``livenessTickInterval`` from it.
    ///
    /// - Precondition: `unresponsiveAfter < terminateAfter`. Reversed,
    ///   `terminateAfter` fires first and the unresponsive stage is never
    ///   reached.
    public init(
        heartbeatInterval: TimeInterval,
        unresponsiveAfter: TimeInterval,
        terminateAfter: TimeInterval
    ) {
        precondition(
            unresponsiveAfter < terminateAfter,
            "ControlChannelCadence: unresponsiveAfter (\(unresponsiveAfter)) must be < terminateAfter (\(terminateAfter))"
        )
        self.heartbeatInterval = heartbeatInterval
        self.unresponsiveAfter = unresponsiveAfter
        self.terminateAfter = terminateAfter
        self.livenessTickInterval = min(heartbeatInterval, unresponsiveAfter / 3)
    }

    /// The cadence both peers run outside tests.
    public static let production = ControlChannelCadence(
        heartbeatInterval: 5, unresponsiveAfter: 15, terminateAfter: 30)
}
