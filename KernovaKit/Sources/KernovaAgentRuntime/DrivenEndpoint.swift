#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// What a `ConnectionDriver` needs of an endpoint: the transport inputs, one role-typed input, and the polls.
public protocol DrivenEndpoint: Sendable {
    /// What the endpoint's owner feeds it: adapter reports, or the hub's commands.
    associatedtype Input: Sendable
    /// What it asks adapters to do.
    associatedtype Effect: Sendable
    /// What it tells its owner.
    associatedtype Event: Sendable

    /// The connection the endpoint runs.
    var generation: ConnectionGeneration { get }
    /// The connection's phase.
    var state: ConnectionState { get }
    /// When `handleTimeout` must next run.
    var nextDeadline: CoreInstant? { get }

    /// Bytes from the transport.
    mutating func receive(_ bytes: Data, now: CoreInstant)
    /// The transport ended.
    mutating func transportEnded(now: CoreInstant)
    /// The timer fired.
    mutating func handleTimeout(now: CoreInstant)
    /// An input from the endpoint's owner.
    mutating func handle(_ input: Input, now: CoreInstant)
    /// Closes the connection with `code`.
    mutating func close(_ code: ErrorCode, now: CoreInstant)

    /// The next frames to write.
    mutating func pollTransmit(maxBytes: Int) -> Transmit?
    /// The next event for the owner.
    mutating func pollEvent() -> Event?
    /// The next effect for an adapter.
    mutating func pollEffect() -> Effect?

    /// The diagnostic `event` carries, which the driver logs.
    static func diagnostic(in event: Event) -> Diagnostic?
}

extension PeerEndpoint: DrivenEndpoint {
    /// The diagnostic a peer event carries.
    public static func diagnostic(in event: PeerEvent) -> Diagnostic? {
        if case .diagnostic(let diagnostic) = event { return diagnostic }
        return nil
    }
}

extension HostEndpoint: DrivenEndpoint {
    /// A host endpoint asks no adapter for anything: the hub acts on its events.
    public mutating func pollEffect() -> Never? { nil }

    /// Closes the connection with `code` and no retry delay.
    public mutating func close(_ code: ErrorCode, now: CoreInstant) {
        handle(.close(code, retryAfter: nil), now: now)
    }

    /// The diagnostic a host event carries.
    public static func diagnostic(in event: HostEvent) -> Diagnostic? {
        if case .diagnostic(let diagnostic) = event { return diagnostic }
        return nil
    }
}
