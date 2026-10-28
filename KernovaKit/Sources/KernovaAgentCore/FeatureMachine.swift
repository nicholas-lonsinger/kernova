#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// One feature's machine for one role. An endpoint holds one stored property
/// per machine and routes each stream event to the machine owning its kind.
public protocol FeatureMachine: Sendable {
    /// The feature the machine implements.
    static var feature: FeatureID { get }
    /// What this side advertises for the feature now; the endpoint republishes on change.
    var localAdvert: LocalAdvert { get }
    /// Handles one connection-level event for the machine's streams.
    mutating func handle(_ event: FeatureEvent, connection: inout Connection, now: CoreInstant)
    /// When the machine next needs `.deadline`, on the connection's raw time
    /// (`JudgedClock.external` converts it to the caller's timeline), computed
    /// from `clock` as it is now. Every machine receives every `.deadline`.
    func nextDeadline(on clock: JudgedClock) -> CoreInstant?
}

/// What an endpoint tells a feature machine.
public enum FeatureEvent: Sendable, Equatable {
    /// The far side's Hello was read.
    case sessionEstablished
    /// Some input to §4.3's usability changed.
    case usabilityChanged
    /// The policy changed (a `PolicyUpdate` on a peer, a command on the host).
    case policyChanged
    /// The far side opened one of the machine's kinds.
    case opened(StreamID, body: Data)
    /// A message arrived on one of its streams.
    case message(StreamID, Data)
    /// Raw bytes arrived on one of its streams.
    case data(StreamID, Data)
    /// The far side ended one of its streams.
    case remoteEnded(StreamID, body: Data)
    /// One of its streams became writable.
    case writable(StreamID)
    /// One of its streams closed.
    case streamClosed(StreamID, StreamClosure)
    /// A timer passed: some machine's `nextDeadline`, or the connection's.
    case deadline
}

extension Connection {
    /// Whether a machine may queue DATA, END or RESET on `id` now.
    func canQueue(on id: StreamID) -> Bool {
        guard isAcceptingInput, let index = index(of: id) else { return false }
        return streams[index].canSend
    }

    /// Whether a machine may RESET `id` now.
    func canReset(_ id: StreamID) -> Bool {
        guard isAcceptingInput, let index = index(of: id) else { return false }
        return streams[index].phase != .closed
    }

    func judgedDeadline(after span: CoreDuration) -> JudgedDeadline {
        JudgedDeadline(after: span, on: clock, confirmation: policy.expiryConfirmation)
    }
}

extension Availability where Params == Data {
    /// A wire availability from a typed one, encoding its params.
    init<Typed>(_ typed: Availability<Typed>, encode: (Typed) -> Data) {
        switch typed {
        case .available(let params): self = .available(encode(params))
        case .absent(let reason, let detail): self = .absent(reason, debugDetail: detail)
        }
    }
}
