#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaWire

/// What an endpoint tells a feature machine.
enum FeatureEvent: Sendable, Equatable {
    /// The far side's Hello was read.
    case sessionEstablished
    /// Some input to `Connection.usability(_:)` changed.
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
    /// A stream this side opened stopped holding a slot, which can be after its
    /// `streamClosed`: an opener `canOpen` held back tries again.
    case slotFreed
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
