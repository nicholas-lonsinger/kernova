import Foundation

/// Capability tags advertised on the control-channel `Hello`.
///
/// Capabilities are how the two sides negotiate optional features. The control
/// plane tags are always advertised; a peer enables an optional feature only when
/// the other side advertises its tag, so an older agent leaves the feature off.
public enum KernovaCapability {
    /// Control-channel protocol, version 1.
    public static let controlV1 = "control.v1"

    /// Bidirectional heartbeat, version 1.
    public static let controlHeartbeatV1 = "control.heartbeat.v1"

    /// The chunk-streamed clipboard protocol (offer → request → begin/chunk/end
    /// with windowed flow control).
    ///
    /// Required on both sides for clipboard sharing to be enabled.
    public static let clipboardStreamV1 = "clipboard.stream.v1"

    /// Receiving a folder as an archive streamed straight into the destination
    /// tree, announced with `ClipboardStreamBegin.total_bytes = 0` because the
    /// compressed size is not known when the transfer starts.
    ///
    /// A peer without it bounds arriving bytes by that declared total and aborts
    /// the transfer on the first chunk, so a folder is simply not offered to one
    /// — every other representation is unaffected.
    public static let clipboardStreamDirectoryV1 = "clipboard.stream.directory.v1"

    /// Honoring `PolicyUpdate.clipboard_max_paste_bytes` — the user-selected
    /// ceiling on a paste's file-representation total.
    ///
    /// Both ends enforce the ceiling independently, so the host uses the user's
    /// value only for a guest advertising this; otherwise both sides fall back
    /// to `ClipboardPasteLimit.defaultBytes` and stay in agreement.
    public static let clipboardPasteLimitV1 = "clipboard.paste.limit.v1"

    /// The capabilities advertised by both the host control service and the
    /// guest control agent today.
    public static let controlChannelDefaults = [
        controlV1, controlHeartbeatV1, clipboardStreamV1, clipboardStreamDirectoryV1,
        clipboardPasteLimitV1,
    ]

    /// Every capability tag this build recognizes — the allowlist for
    /// `logDescription(of:)`.
    public static let recognized: Set<String> = Set(controlChannelDefaults)

    /// A log-safe rendering of a peer-supplied capability list.
    ///
    /// `Hello.capabilities` strings arrive from the peer unauthenticated: never
    /// interpolate them into a log verbatim, or a malicious peer writes arbitrary
    /// content into the persisted log. Recognized tags render verbatim, everything
    /// else collapses to a count.
    public static func logDescription(of capabilities: [String]) -> String {
        var seen: Set<String> = []
        var known: [String] = []
        for capability in capabilities
        where recognized.contains(capability) && seen.insert(capability).inserted {
            known.append(capability)
        }
        let otherCount = capabilities.count(where: { !recognized.contains($0) })
        guard otherCount > 0 else { return known.joined(separator: ",") }
        let suffix = "+\(otherCount) unrecognized"
        return known.isEmpty ? suffix : known.joined(separator: ",") + " " + suffix
    }
}
