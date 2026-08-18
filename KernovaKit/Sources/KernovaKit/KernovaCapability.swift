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

    /// The clipboard transfer protocol, version 3: metadata on the control
    /// channel (offer → request), and each transfer's bytes on a vsock data
    /// connection of their own. Every representation that lands on disk — a
    /// file, a folder, an oversize inline payload — crosses as an LZ4
    /// AppleArchive (`ClipboardTransferReply.is_archive`), and only a small
    /// inline payload crosses raw.
    ///
    /// Required on both sides for clipboard sharing to be enabled, and for the
    /// clipboard data port to admit a connection. A peer without it has no data
    /// port to dial.
    public static let clipboardTransferV3 = "clipboard.transfer.v3"

    /// Files dragged onto the VM display, offered on their own vsock channel
    /// and streamed in the `clipboardTransferV3` payload encoding into the
    /// guest's Downloads folder.
    ///
    /// Independent of clipboard sharing: the drop channel carries its own offer
    /// and never touches a pasteboard. A peer without it has no drop listener or
    /// drop client at all, so the display refuses the gesture rather than
    /// starting a transfer nothing will answer.
    public static let dropFilesV3 = "drop.files.v3"

    /// The capabilities advertised by both the host control service and the
    /// guest control agent today.
    public static let controlChannelDefaults = [
        controlV1, controlHeartbeatV1, clipboardTransferV3, dropFilesV3,
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
