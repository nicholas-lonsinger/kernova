#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// What a `ConnectionDriver` needs of an endpoint: the transport inputs, one role-typed input, and the polls.
public protocol DrivenEndpoint: Sendable {
    /// What the endpoint's owner and adapters feed it.
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
    /// The transmit marked `isFinal` was written in full.
    mutating func finalTransmitWritten(now: CoreInstant)
    /// The transport ended.
    mutating func transportEnded(now: CoreInstant)
    /// The timer fired.
    mutating func handleTimeout(now: CoreInstant)
    /// An input from the endpoint's owner or adapters.
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
    /// How the connection ended, when `event` is its one `.closed`.
    static func closure(in event: Event) -> ConnectionClosure?
}

extension PeerEndpoint: DrivenEndpoint {
    /// The diagnostic a peer event carries.
    public static func diagnostic(in event: PeerEvent) -> Diagnostic? {
        if case .diagnostic(let diagnostic) = event { return diagnostic }
        return nil
    }

    /// The closure a peer event carries.
    public static func closure(in event: PeerEvent) -> ConnectionClosure? {
        if case .closed(let closure) = event { return closure }
        return nil
    }
}

/// What a host connection's driver feeds its endpoint: the hub's commands, and the payload source's
/// answers to the endpoint's reads. The hub can send only the first.
public enum HostInput: Sendable, Equatable {
    /// A hub command.
    case hub(HostCommand)
    /// The payload source's answer.
    case payload(PayloadInput)
}

extension HostEndpoint: DrivenEndpoint {
    /// The hub's commands and the payload source's answers.
    public typealias Input = HostInput

    /// Feeds a hub command or a payload answer.
    public mutating func handle(_ input: HostInput, now: CoreInstant) {
        switch input {
        case .hub(let command): handle(command, now: now)
        case .payload(let answer): handle(answer, now: now)
        }
    }

    /// Closes the connection with `code` and no retry delay.
    public mutating func close(_ code: ErrorCode, now: CoreInstant) {
        handle(HostCommand.close(code, retryAfter: nil), now: now)
    }

    /// The diagnostic a host event carries.
    public static func diagnostic(in event: HostEvent) -> Diagnostic? {
        if case .diagnostic(let diagnostic) = event { return diagnostic }
        return nil
    }

    /// The closure a host event carries.
    public static func closure(in event: HostEvent) -> ConnectionClosure? {
        if case .closed(let closure) = event { return closure }
        return nil
    }
}
