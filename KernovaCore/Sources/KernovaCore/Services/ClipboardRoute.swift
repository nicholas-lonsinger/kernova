import KernovaAgentCore

/// Which peer carries a VM's clipboard.
package enum ClipboardRoute: Equatable, Sendable {
    /// The guest agent's CLIPBOARD console peer, through the agent hub.
    case hub(PeerHandle)
    /// The guest's SPICE agent, text only.
    case spice
    /// Nothing carries it.
    case none

    /// The route for a session whose devices give it a SPICE clipboard port or not, and whose agent hub names
    /// `consolePeer` as CLIPBOARD's console peer: that peer, else SPICE, else nothing.
    static func choose(hasSpicePort: Bool, consolePeer: PeerHandle?) -> ClipboardRoute {
        if let consolePeer { return .hub(consolePeer) }
        return hasSpicePort ? .spice : .none
    }
}
