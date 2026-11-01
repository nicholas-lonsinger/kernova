#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

import KernovaAgentCore
import KernovaWire

/// How a power action the hub routed ended (spec §6.4).
public enum PowerRoutingOutcome: Sendable, Equatable {
    /// A peer took it, and the guest is going down.
    case handedOff
    /// These apps stopped it; the guest keeps running. `skippable` when a peer offers the action without
    /// waiting for them, as ``AgentHub/requestPower(_:skippingBlockers:_:)`` asks it.
    case blocked([AppValue], skippable: Bool)
    /// A user in the guest cancelled it.
    case cancelledInGuest
    /// The guest's OS gave up after accepting it.
    case failed(WireError)
    /// The host cannot tell whether the guest is going down.
    case indeterminate
    /// The peer's connection ended after it accepted, as it does when the guest goes down.
    case lostAfterAcceptance
    /// No peer took it, and nothing was done. `refusals` say why each peer asked declined. For a shutdown
    /// that waits for blocking apps, the caller presses the ACPI button.
    case unserved(refusals: [PeerRefusal])
    /// Another routing is running for this VM.
    case busy
}

/// Which agent the hub would ask for a shutdown now, as the merged POWER entry the UI reads.
public enum PowerProvision: Sendable, Equatable {
    /// The first candidate is the peer in this role.
    case agent(PeerRole)
    /// No peer is a candidate, for this reason: Stop presses the ACPI button.
    case absent(AbsenceReason)
}

/// A routing in progress, as the UI shows it.
public struct PowerRoutingProgress: Sendable, Equatable {
    /// What a routing's current request has reached.
    public enum Stage: Sendable, Equatable {
        /// The peer has not accepted yet.
        case asking
        /// The peer's OS took it.
        case accepted
        /// The guest is asking apps to quit.
        case askingApps
        /// These apps are holding it up.
        case waitingOnApps([AppValue])
    }

    /// The action routed.
    public var action: PowerAction
    /// The role of the peer asked now.
    public var role: PeerRole
    /// How far that peer's request has come.
    public var stage: Stage

    /// A routing of `action` whose request to the peer in `role` is at `stage`.
    public init(action: PowerAction, role: PeerRole, stage: Stage) {
        self.action = action
        self.role = role
        self.stage = stage
    }
}

/// The hub's power routing: one `PowerRouting`, the requests it has asked peers for, and the caller
/// waiting on its outcome. Touched only on the hub's queue.
struct HubPowerRouting: Sendable {
    var routing = PowerRouting()
    /// The caller of the routing running now.
    var completion: (@Sendable (PowerRoutingOutcome) -> Void)?
    var progress: PowerRoutingProgress?
    /// The hub's id for each request asked of a peer and not yet ended, and the peer it was asked of.
    var requests: [PowerRequestID: PeerHandle] = [:]
    private var nextRequest: UInt64 = 0

    /// The id for the next request to a connection of `generation` (spec §9.7.4): the hub's own number,
    /// unique across its connections.
    mutating func drawID(_ generation: ConnectionGeneration) -> PowerRequestID {
        nextRequest += 1
        return PowerRequestID(generation: generation, rawValue: nextRequest)
    }
}

extension PowerRoutingOutcome {
    /// The outcome a terminal routing output names; nil for an output that ends nothing.
    init?(_ output: RoutingOutput) {
        switch output {
        case .ask, .progress:
            return nil
        case .handedOff: self = .handedOff
        case .blocked(_, let apps, let skippable): self = .blocked(apps, skippable: skippable)
        case .cancelledInGuest: self = .cancelledInGuest
        case .failed(_, let error): self = .failed(error)
        case .indeterminate: self = .indeterminate
        case .lostAfterAcceptance: self = .lostAfterAcceptance
        case .unserved(let refusals): self = .unserved(refusals: refusals)
        case .busy: self = .busy
        }
    }
}
