import Foundation

/// Capability tags advertised on the control-channel `Hello`.
///
/// Capabilities are how the two sides negotiate optional features. The control
/// plane tags are always advertised; `clipboardStreamV1` gates the chunk-streamed
/// clipboard protocol: a peer enables clipboard sharing only when the other side
/// advertises it. An agent that predates streaming simply doesn't advertise it,
/// so clipboard stays off and the host surfaces its existing "update the guest
/// agent" affordance (the agent version is bumped in lockstep with this tag).
public enum KernovaCapability {
    /// Control-channel protocol, version 1.
    public static let controlV1 = "control.v1"

    /// Bidirectional heartbeat, version 1.
    public static let controlHeartbeatV1 = "control.heartbeat.v1"

    /// The chunk-streamed clipboard protocol (offer → request → begin/chunk/end
    /// with windowed flow control).
    ///
    /// Required on both sides for clipboard sharing
    /// to be enabled; there is no legacy fallback.
    public static let clipboardStreamV1 = "clipboard.stream.v1"

    /// The capabilities advertised by both the host control service and the
    /// guest control agent today.
    public static let controlChannelDefaults = [controlV1, controlHeartbeatV1, clipboardStreamV1]
}
