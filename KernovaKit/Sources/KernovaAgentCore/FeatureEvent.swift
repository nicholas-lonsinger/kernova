#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What an endpoint tells a feature machine.
package enum FeatureEvent: Sendable, Equatable {
    /// The far side's Hello was read.
    case sessionEstablished
    /// Some input to `Connection.usability(_:)` changed.
    case usabilityChanged
    /// The policy changed (a `PolicyUpdate` on a peer, a command on the host).
    case policyChanged
    /// The far side opened one of the machine's kinds.
    case opened(StreamID, body: OpenBody)
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
    /// A stream this side opened stopped holding a slot, which can be after its
    /// `streamClosed`: an opener `canOpen` held back tries again.
    case slotFreed
    /// A timer passed: some machine's `nextDeadline`, or the connection's.
    case deadline
}

/// A role's feature machine, as its endpoint drives it.
package protocol FeatureMachine: Sendable {
    /// What the machine tells its endpoint's owner.
    associatedtype Event: Sendable & Equatable
    /// What the machine asks its endpoint's adapters to do.
    associatedtype Effect: Sendable & Equatable

    /// The machine's advert.
    var localAdvert: LocalAdvert { get }
    /// When the machine next needs `.deadline`; nil when it waits on none.
    func nextDeadline(on clock: JudgedClock) -> CoreInstant?
    /// Handles a connection-wide event, or an event of one of the machine's streams.
    mutating func handle(_ event: FeatureEvent, connection: inout Connection)
    /// Everything the machine emitted since the last call, each kind in its emission order, and whether its
    /// advert changed since then.
    mutating func takeOutputs() -> (effects: [Effect], events: [Event], diagnostics: [Diagnostic], advertChanged: Bool)
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
