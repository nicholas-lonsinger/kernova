import Foundation
import KernovaKit
import Synchronization

/// The guest capability a feature vsock channel needs before it may be
/// admitted, beyond the completed control handshake every one of them
/// requires.
enum FeatureChannelRequirement {
    /// Log forwarding — the handshake alone.
    case none
    /// The clipboard channel: `clipboard.transfer.v3`.
    case clipboardStreaming
    /// The drop channel: `drop.files.v3`.
    case dropFiles

    /// The capability tag a guest must advertise, or `nil` when none is
    /// needed.
    var capability: String? {
        switch self {
        case .none: return nil
        case .clipboardStreaming: return KernovaCapability.clipboardTransferV3
        case .dropFiles: return KernovaCapability.dropFilesV3
        }
    }
}

/// Answers the feature listeners' admission checks without touching the main
/// actor: whether a control channel's `Hello` handshake has completed, and
/// which capabilities that `Hello` advertised.
///
/// Owned by `VMInstance`, one per VM across every control-service generation.
/// `VsockControlService` publishes into it on the main actor as the handshake
/// state changes; the listeners' `shouldAdmit` closures read it from whatever
/// queue VZ delivers accepts on.
final class VsockAdmissionGate: Sendable {
    /// One control channel's handshake state, as admission reads it.
    struct State: Sendable, Equatable {
        var handshakeComplete = false
        var capabilities: Set<String> = []
    }

    private let state = Mutex(State())

    /// Replaces the published state wholesale — the control service's handshake
    /// completed, or its channel settled.
    func publish(_ state: State) {
        self.state.withLock { $0 = state }
    }

    /// Withdraws admission — the owner replaced or tore down the control
    /// service this gate was reflecting.
    func clear() {
        publish(State())
    }

    /// Whether a feature vsock channel may be admitted right now: a control
    /// channel whose `Hello` handshake completed must exist, and its `Hello`
    /// must have advertised whatever capability `requirement` names.
    ///
    /// Evaluated at accept time so it tracks reconnects.
    func admission(for requirement: FeatureChannelRequirement) -> VsockAdmission {
        let snapshot = state.withLock { $0 }
        guard snapshot.handshakeComplete else {
            return .notReady(reason: "no control channel has completed its handshake")
        }
        guard let capability = requirement.capability else { return .admit }
        guard snapshot.capabilities.contains(capability) else {
            return .denied(
                reason: "the connected guest agent does not advertise \(capability)")
        }
        return .admit
    }
}
