import Foundation

// MARK: - Control-frame builders

extension Frame {
    /// The `Hello` that opens a control channel, built the same way by both
    /// peers.
    ///
    /// - Parameters:
    ///   - agentVersion: The sender's own version, for `agent_info`.
    ///   - bundledAgentVersion: The guest-agent version the sender bundles —
    ///     the host's field alone. Empty means unknown, which the guest reads
    ///     as no update available.
    /// - Returns: The `Hello` frame to send.
    public static func controlHello(
        agentVersion: String, bundledAgentVersion: String = ""
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.hello = Kernova_V1_Hello.with {
            $0.serviceVersion = 1
            $0.capabilities = KernovaCapability.controlChannelDefaults
            $0.bundledAgentVersion = bundledAgentVersion
            $0.agentInfo = Kernova_V1_AgentInfo.with {
                $0.os = "macOS"
                $0.osVersion = KernovaOSVersion.current
                $0.agentVersion = agentVersion
            }
        }
        return frame
    }

    /// A `Heartbeat` carrying `nonce`, which the peer counts but never answers.
    public static func controlHeartbeat(nonce: UInt64) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.heartbeat = Kernova_V1_Heartbeat.with {
            $0.nonce = nonce
        }
        return frame
    }

    /// The host's toggle snapshot, sent at every guest `Hello` and on every live
    /// edit. Host→guest only.
    ///
    /// `clipboardSharingEnabled` is the effective value, already gated on the
    /// guest's advertised streaming capability.
    public static func controlPolicyUpdate(
        logForwardingEnabled: Bool,
        clipboardSharingEnabled: Bool,
        clipboardMaxPasteBytes: UInt64,
        dropFilesEnabled: Bool
    ) -> Frame {
        var frame = Frame()
        frame.protocolVersion = 1
        frame.policyUpdate = Kernova_V1_PolicyUpdate.with {
            $0.logForwardingEnabled = logForwardingEnabled
            $0.clipboardSharingEnabled = clipboardSharingEnabled
            $0.clipboardMaxPasteBytes = clipboardMaxPasteBytes
            $0.dropFilesEnabled = dropFilesEnabled
        }
        return frame
    }
}

// MARK: - Inbound classification

/// One inbound control-channel frame, reduced to what either peer acts on.
///
/// The version guard and the payload split live here so the two peers cannot
/// disagree about which frames the control channel carries.
public enum ControlChannelInbound: Equatable, Sendable {
    /// The frame declares a protocol version this build does not speak; its
    /// payload is not read.
    case unsupportedVersion(UInt32)

    /// The peer's handshake.
    case hello(Kernova_V1_Hello)

    /// A liveness beat, whose arrival is the whole content.
    case heartbeat

    /// The peer reporting a failure on this channel.
    case error(Kernova_V1_Error)

    /// The host's policy snapshot. Host→guest only, so the host classifying one
    /// has a peer talking out of turn.
    case policyUpdate(Kernova_V1_PolicyUpdate)

    /// A payload belonging to another channel, or no payload at all.
    case wrongPort

    /// Whether receiving this is evidence the peer is alive.
    ///
    /// Everything the peer can put on this channel is, down to a payload on the
    /// wrong port — only a frame this build cannot even parse says nothing.
    public var isLivenessSignal: Bool {
        if case .unsupportedVersion = self { return false }
        return true
    }

    /// Classifies one frame received on the control channel.
    public static func classify(_ frame: Frame) -> ControlChannelInbound {
        guard frame.protocolVersion == 1 else {
            return .unsupportedVersion(frame.protocolVersion)
        }
        switch frame.payload {
        case .hello(let hello): return .hello(hello)
        case .heartbeat: return .heartbeat
        case .error(let error): return .error(error)
        case .policyUpdate(let policy): return .policyUpdate(policy)
        case .clipboardOffer, .clipboardRequest, .clipboardRelease,
            .clipboardTransferRequest, .clipboardTransferReply, .logRecord,
            .dropOffer, .dropComplete, .dropRelease, .none:
            return .wrongPort
        }
    }
}
