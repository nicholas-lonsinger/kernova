/// A peer's connection to the host as its UI shows it, folded from the connection's events.
public enum HostConnectionState: Sendable, Equatable {
    /// No connection: the peer is dialing, or waiting to.
    case connecting
    /// The host's Hello was read, and the host is answering.
    case connected
    /// Connected, but the host has been silent past the unresponsive threshold.
    case unresponsive

    /// The state after `event`; an event that says nothing about the connection leaves it unchanged.
    public func after(_ event: PeerEvent) -> HostConnectionState {
        switch event {
        case .role(.established), .liveness(.responsive): .connected
        case .liveness(.unresponsive): .unresponsive
        case .closed: .connecting
        case .role(.policyReceived), .role(.updateAvailable), .role(.itemFeatureUsable), .items, .dragTake, .itemReply,
            .diagnostic:
            self
        }
    }
}
